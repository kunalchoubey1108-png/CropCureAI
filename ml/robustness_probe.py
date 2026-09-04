"""Measure how the shipped model behaves on realistic capture conditions.

evaluate.py scores held-out PlantVillage images, which are single leaves on
uniform lab backgrounds. A phone in a field produces something else. This
probe takes held-out HEALTHY leaves and applies degradations a real capture
introduces, then reports how often the verdict flips to Early_blight.

If clean-healthy scores well but degraded-healthy collapses into blight, the
problem is training-data coverage, not the inference wiring.

Usage: ml/.venv/Scripts/python.exe ml/robustness_probe.py
"""

from __future__ import annotations

import random
from pathlib import Path

import numpy as np
import tensorflow as tf
from PIL import Image, ImageEnhance, ImageFilter

ML_DIR = Path(__file__).resolve().parent
DATA = ML_DIR / "data"
MODEL = ML_DIR.parent / "assets" / "models" / "model.tflite"
LABELS = [
    l.strip()
    for l in (ML_DIR.parent / "assets" / "models" / "labels.txt")
    .read_text(encoding="utf-8")
    .splitlines()
    if l.strip()
]
N = 40
SEED = 7


def to_tensor(im: Image.Image) -> np.ndarray:
    im = im.convert("RGB")
    side = min(im.size)
    im = im.crop((
        (im.width - side) // 2,
        (im.height - side) // 2,
        (im.width - side) // 2 + side,
        (im.height - side) // 2 + side,
    ))
    return np.asarray(im.resize((224, 224), Image.BILINEAR), np.float32)[None] / 255.0


# --- degradations a real phone capture introduces -----------------------
def clean(im, rng):
    return im


def blurry(im, rng):
    return im.filter(ImageFilter.GaussianBlur(rng.uniform(1.2, 2.5)))


def dim(im, rng):
    return ImageEnhance.Brightness(im).enhance(rng.uniform(0.45, 0.7))


def rotated(im, rng):
    return im.rotate(rng.uniform(-25, 25), resample=Image.BILINEAR, expand=False)


def on_clutter(im, rng):
    """Leaf pasted on a real-world background — the field condition the
    lab-shot training set never contains."""
    bgs = sorted((DATA / "Background_Non_Leaf").glob("*.jpg"))
    bg = Image.open(bgs[rng.randrange(len(bgs))]).convert("RGB").resize((256, 256))
    leaf = im.convert("RGB").resize((150, 150))
    bg.paste(leaf, (53, 53))
    return bg


def zoomed_out(im, rng):
    """Leaf occupying a small part of the frame, as when held at arm's length."""
    canvas = Image.new("RGB", (256, 256), (120, 110, 95))
    small = im.convert("RGB").resize((96, 96))
    canvas.paste(small, (80, 80))
    return canvas


def main() -> None:
    interp = tf.lite.Interpreter(model_path=str(MODEL))
    interp.allocate_tensors()
    inp = interp.get_input_details()[0]
    out = interp.get_output_details()[0]

    def predict(im):
        interp.set_tensor(inp["index"], to_tensor(im))
        interp.invoke()
        return interp.get_tensor(out["index"])[0]

    healthy = sorted((DATA / "Tomato___healthy").glob("*.jpg"))
    rng = random.Random(SEED)
    sample = rng.sample(healthy, min(N, len(healthy)))

    print(f"{len(sample)} held-out HEALTHY leaves, per condition:\n")
    print(f"{'condition':14s}{'->blight':>10s}{'->healthy':>11s}"
          f"{'->background':>14s}{'mean blight p':>15s}")

    for fn in (clean, blurry, dim, rotated, zoomed_out, on_clutter):
        counts = [0, 0, 0]
        blight_p = []
        for path in sample:
            with Image.open(path) as im:
                probs = predict(fn(im.copy(), rng))
            counts[int(np.argmax(probs))] += 1
            blight_p.append(float(probs[0]))
        print(f"{fn.__name__:14s}{counts[0]:>10d}{counts[1]:>11d}"
              f"{counts[2]:>14d}{np.mean(blight_p):>15.3f}")


if __name__ == "__main__":
    main()
