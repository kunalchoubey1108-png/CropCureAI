"""Pick ImageChecker.minSharpness from data instead of guessing.

Replicates ImageChecker._analyzeBytes exactly: resize to width 224 keeping
aspect, grayscale, then variance of the 4-neighbour Laplacian over interior
pixels.

Prints the sharpness distribution for clean leaves versus the blurred leaves
that robustness_probe.py showed flipping to a disease, so the threshold
can be set to reject exactly the blur that causes misdiagnosis.

Usage: ml/.venv/Scripts/python.exe ml/sharpness_probe.py
"""

from __future__ import annotations

import random
from pathlib import Path

import numpy as np
import tensorflow as tf
from PIL import Image, ImageFilter

from train_export import CLASS_NAMES

HEALTHY = CLASS_NAMES.index("Tomato___healthy")
BACKGROUND = CLASS_NAMES.index("Background_Non_Leaf")

ML_DIR = Path(__file__).resolve().parent
DATA = ML_DIR / "data"
MODEL = ML_DIR.parent / "assets" / "models" / "model.tflite"
N = 60
SEED = 7


def sharpness(im: Image.Image) -> float:
    """Mirror of ImageChecker: width-224 resize, grayscale, Laplacian variance."""
    w = 224
    h = max(1, round(im.height * w / im.width))
    g = np.asarray(im.convert("RGB").resize((w, h), Image.BILINEAR).convert("L"),
                   dtype=np.float64)
    lap = (4 * g[1:-1, 1:-1] - g[1:-1, :-2] - g[1:-1, 2:]
           - g[:-2, 1:-1] - g[2:, 1:-1])
    return float(lap.var())


def to_tensor(im: Image.Image) -> np.ndarray:
    im = im.convert("RGB")
    s = min(im.size)
    im = im.crop(((im.width - s) // 2, (im.height - s) // 2,
                  (im.width - s) // 2 + s, (im.height - s) // 2 + s))
    return np.asarray(im.resize((224, 224), Image.BILINEAR), np.float32)[None] / 255.0


def stats(name: str, vals: list[float], flips: int | None = None) -> None:
    a = np.array(vals)
    extra = "" if flips is None else f"  blight-flips={flips}/{len(vals)}"
    print(f"{name:26s} min={a.min():8.1f} p05={np.percentile(a,5):8.1f} "
          f"median={np.median(a):8.1f} max={a.max():8.1f}{extra}")


def main() -> None:
    interp = tf.lite.Interpreter(model_path=str(MODEL))
    interp.allocate_tensors()
    inp, out = interp.get_input_details()[0], interp.get_output_details()[0]

    def disease_prob(im) -> float:
        """Total probability on disease classes, i.e. not healthy/background."""
        interp.set_tensor(inp["index"], to_tensor(im))
        interp.invoke()
        probs = interp.get_tensor(out["index"])[0]
        return float(1 - probs[HEALTHY] - probs[BACKGROUND])

    rng = random.Random(SEED)
    healthy = rng.sample(sorted((DATA / "Tomato___healthy").glob("*.jpg")), N)
    blight = rng.sample(sorted((DATA / "Tomato___Early_blight").glob("*.jpg")), N)

    clean_sharp, blur_sharp, blur_flip_sharp, flips = [], [], [], 0
    for p in healthy:
        with Image.open(p) as im:
            clean_sharp.append(sharpness(im.copy()))
            b = im.copy().filter(ImageFilter.GaussianBlur(rng.uniform(1.2, 2.5)))
            s = sharpness(b)
            blur_sharp.append(s)
            if disease_prob(b) > 0.5:
                flips += 1
                blur_flip_sharp.append(s)

    real_blight_sharp = []
    for p in blight:
        with Image.open(p) as im:
            real_blight_sharp.append(sharpness(im.copy()))

    print(f"\nLaplacian-variance sharpness, n={N} per group\n")
    stats("clean healthy", clean_sharp)
    stats("clean EARLY BLIGHT", real_blight_sharp)
    stats("blurred healthy", blur_sharp, flips)
    if blur_flip_sharp:
        stats("  ...of those, misread", blur_flip_sharp)

    print("\ncurrent minSharpness = 45")
    for t in (45, 80, 120, 150, 200, 250, 300):
        rejected_good = (np.array(real_blight_sharp) < t).mean()
        caught_bad = ((np.array(blur_flip_sharp) < t).mean()
                      if blur_flip_sharp else 0.0)
        print(f"  threshold {t:4d} -> catches {caught_bad:6.1%} of misreads, "
              f"wrongly rejects {rejected_good:6.1%} of real blight photos")


if __name__ == "__main__":
    main()
