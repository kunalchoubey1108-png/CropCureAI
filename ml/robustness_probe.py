"""Measure how the shipped model behaves on realistic capture conditions.

evaluate.py scores held-out PlantVillage images, which are single leaves on
uniform lab backgrounds. A phone in a field produces something else. This
probe takes held-out leaves from every tomato class (ml/data_test, never
trained on), applies degradations a real capture introduces, and reports how
often the model still names the right disease.

The `on_clutter` condition is the one the spec grades: the leaf is segmented
off its lab backdrop with the same code that built the training composites,
then pasted onto a photo from ml/eval_backgrounds -- a slice of Imagenette
disjoint from both the background class and the augmentation pool, so the
model is never graded on a backdrop it trained against.

Done-when bar from docs/spec-11-class-classifier.md: >= 80% correct disease
on_clutter. The script exits non-zero if that fails.

Usage: ml/.venv/Scripts/python.exe ml/robustness_probe.py
"""

from __future__ import annotations

import random

import numpy as np
import tensorflow as tf
from PIL import Image, ImageEnhance, ImageFilter

from prepare_data import (
    BACKGROUND_CLASS,
    EVAL_BG_DIR,
    LEAF_CLASSES,
    TEST_DIR,
    composite,
    leaf_cutout,
)
from train_export import CLASS_NAMES, MODEL_OUT

PER_CLASS = 20
SEED = 7
CLUTTER_BAR = 0.80


def to_tensor(im: Image.Image) -> np.ndarray:
    """Center-crop square -> 224 -> [0, 1], as TFLiteService does."""
    im = im.convert("RGB")
    side = min(im.size)
    left, top = (im.width - side) // 2, (im.height - side) // 2
    im = im.crop((left, top, left + side, top + side))
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


def zoomed_out(im, rng):
    """Leaf occupying a small part of the frame, as when held at arm's length."""
    canvas = Image.new("RGB", (256, 256), (120, 110, 95))
    canvas.paste(im.convert("RGB").resize((96, 96)), (80, 80))
    return canvas


_EVAL_BGS = sorted(EVAL_BG_DIR.glob("*.jpg"))


def on_clutter(im, rng):
    """Segmented leaf on an unseen real-world photo -- the field condition."""
    cut = leaf_cutout(im)
    if cut is None:
        return None
    with Image.open(_EVAL_BGS[rng.randrange(len(_EVAL_BGS))]) as bg:
        return composite(cut, bg.copy(), rng)


def main() -> None:
    if not TEST_DIR.exists() or not _EVAL_BGS:
        raise SystemExit("ml/data_test or ml/eval_backgrounds missing -- run prepare_data.py first")

    interp = tf.lite.Interpreter(model_path=str(MODEL_OUT))
    interp.allocate_tensors()
    inp = interp.get_input_details()[0]
    out = interp.get_output_details()[0]

    def predict(im):
        interp.set_tensor(inp["index"], to_tensor(im))
        interp.invoke()
        return int(np.argmax(interp.get_tensor(out["index"])[0]))

    rng = random.Random(SEED)
    sample = [
        (CLASS_NAMES.index(name), path)
        for name in LEAF_CLASSES.values()
        for path in rng.sample(sorted((TEST_DIR / name).glob("*.jpg")), PER_CLASS)
    ]
    bg_index = CLASS_NAMES.index(BACKGROUND_CLASS)

    print(f"{len(sample)} held-out leaves ({PER_CLASS} per class), per condition:\n")
    print(f"{'condition':12s}{'correct':>10s}{'->other leaf':>14s}"
          f"{'->background':>14s}{'skipped':>9s}")

    clutter_rate = 0.0
    clutter_by_class: dict[int, list[int]] = {}
    for fn in (clean, blurry, dim, rotated, zoomed_out, on_clutter):
        correct = wrong_leaf = background = skipped = 0
        for truth, path in sample:
            with Image.open(path) as im:
                degraded = fn(im.copy(), rng)
            if degraded is None:  # segmentation refused this frame
                skipped += 1
                continue
            pred = predict(degraded)
            if pred == truth:
                correct += 1
            elif pred == bg_index:
                background += 1
            else:
                wrong_leaf += 1
            if fn is on_clutter:
                clutter_by_class.setdefault(truth, [0, 0])
                clutter_by_class[truth][0] += pred == truth
                clutter_by_class[truth][1] += 1
        scored = max(correct + wrong_leaf + background, 1)
        print(f"{fn.__name__:12s}{correct / scored:>10.1%}{wrong_leaf / scored:>14.1%}"
              f"{background / scored:>14.1%}{skipped:>9d}")
        if fn is on_clutter:
            clutter_rate = correct / scored

    print("\non_clutter by class:")
    for truth, (ok, n) in sorted(clutter_by_class.items()):
        print(f"  {CLASS_NAMES[truth]:34s} {ok:>3d}/{n:<3d} {ok / n:.0%}")

    verdict = "PASS" if clutter_rate >= CLUTTER_BAR else "FAIL"
    print(f"\n{verdict}: on_clutter correct disease {clutter_rate:.1%}, bar {CLUTTER_BAR:.0%}")
    if verdict == "FAIL":
        raise SystemExit(1)


if __name__ == "__main__":
    main()
