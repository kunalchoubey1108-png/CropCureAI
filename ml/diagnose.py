"""Reproduce the Flutter app's inference path in Python to localize a bug.

TFLiteService._preprocess does: decode -> center-crop square -> resize to
224 -> divide by 255. This script does exactly that, then runs the shipped
model.tflite, so a disagreement with evaluate.py points at preprocessing
rather than at the weights.

Usage:
  ml/.venv/Scripts/python.exe ml/diagnose.py <image_or_dir> [...]
"""

from __future__ import annotations

import sys
from pathlib import Path

import numpy as np
import tensorflow as tf
from PIL import Image

ML_DIR = Path(__file__).resolve().parent
MODEL = ML_DIR.parent / "assets" / "models" / "model.tflite"
LABELS = [
    l.strip()
    for l in (ML_DIR.parent / "assets" / "models" / "labels.txt")
    .read_text(encoding="utf-8")
    .splitlines()
    if l.strip()
]


def app_preprocess(path: Path, resample) -> np.ndarray:
    """Mirror of TFLiteService._preprocess in Dart."""
    with Image.open(path) as im:
        im = im.convert("RGB")
        side = min(im.size)
        left = (im.width - side) // 2
        top = (im.height - side) // 2
        im = im.crop((left, top, left + side, top + side))
        im = im.resize((224, 224), resample)
        arr = np.asarray(im, dtype=np.float32) / 255.0
    return arr[None, ...]


def main() -> None:
    interp = tf.lite.Interpreter(model_path=str(MODEL))
    interp.allocate_tensors()
    inp = interp.get_input_details()[0]
    out = interp.get_output_details()[0]

    targets: list[Path] = []
    for a in sys.argv[1:]:
        p = Path(a)
        if p.is_dir():
            targets += sorted(p.glob("*.jpg"))[:4] + sorted(p.glob("*.png"))[:4]
        else:
            targets.append(p)

    # The Dart `image` package defaults copyResize to nearest-neighbour;
    # Keras trained on bilinear. Run both to see if that alone flips it.
    for name, resample in (("bilinear", Image.BILINEAR), ("nearest", Image.NEAREST)):
        print(f"\n=== resample: {name} ===")
        for t in targets:
            x = app_preprocess(t, resample)
            interp.set_tensor(inp["index"], x)
            interp.invoke()
            probs = interp.get_tensor(out["index"])[0]
            top = int(np.argmax(probs))
            scores = "  ".join(
                f"{lbl.split('___')[-1][:12]}={p:.3f}"
                for lbl, p in zip(LABELS, probs)
            )
            print(f"{t.name[:28]:30s} -> {LABELS[top][:26]:28s} {scores}")


if __name__ == "__main__":
    main()
