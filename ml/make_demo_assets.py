"""Build the three presenter-panel demo images from held-out data.

The presets used to hand hardcoded probabilities to AIReliabilityEngine, so
they proved nothing about the model. These assets let each preset run the
real pipeline instead, and this script verifies each one actually lands in
the reliability state the preset claims before writing it.

Images are drawn from ml/data_test -- PlantVillage's own test split, never
trained on.

  A  non-leaf object   -> Background wins        -> OUT_OF_BOUNDS_REJECT
  B  blurred leaf      -> sharpness < 45         -> demoted, LOW_CONFIDENCE
  C  clean blight leaf -> >= 0.70 + good quality -> HIGH_CONFIDENCE

Usage: ml/.venv/Scripts/python.exe ml/make_demo_assets.py
"""

from __future__ import annotations

from pathlib import Path

import numpy as np
import tensorflow as tf
from PIL import Image, ImageFilter

from prepare_data import TEST_DIR
from train_export import CLASS_NAMES, MODEL_OUT

OUT_DIR = Path(__file__).resolve().parent.parent / "assets" / "demo"

# Mirrors AIReliabilityEngine / ImageChecker constants in Dart.
HIGH_CONFIDENCE = 0.70
OOD_FLOOR = 0.40
MIN_SHARPNESS = 45.0
BLUR_RADIUS = 3.0


def sharpness(im: Image.Image) -> float:
    w = 224
    h = max(1, round(im.height * w / im.width))
    g = np.asarray(
        im.convert("RGB").resize((w, h), Image.BILINEAR).convert("L"), np.float64
    )
    lap = (4 * g[1:-1, 1:-1] - g[1:-1, :-2] - g[1:-1, 2:]
           - g[:-2, 1:-1] - g[2:, 1:-1])
    return float(lap.var())


BLIGHT = CLASS_NAMES.index("Tomato___Early_blight")
BACKGROUND = CLASS_NAMES.index("Background_Non_Leaf")


def held_out_paths() -> list[str]:
    return sorted(str(p) for p in TEST_DIR.glob("*/*.jpg"))


def main() -> None:
    interp = tf.lite.Interpreter(model_path=str(MODEL_OUT))
    interp.allocate_tensors()
    inp, out = interp.get_input_details()[0], interp.get_output_details()[0]

    def predict(im: Image.Image) -> np.ndarray:
        im = im.convert("RGB")
        s = min(im.size)
        im = im.crop(((im.width - s) // 2, (im.height - s) // 2,
                      (im.width - s) // 2 + s, (im.height - s) // 2 + s))
        x = np.asarray(im.resize((224, 224), Image.BILINEAR), np.float32)[None] / 255
        interp.set_tensor(inp["index"], x)
        interp.invoke()
        return interp.get_tensor(out["index"])[0]

    val = held_out_paths()
    by_class = {
        c: [p for p in val if Path(p).parent.name == c] for c in CLASS_NAMES
    }
    OUT_DIR.mkdir(parents=True, exist_ok=True)

    # --- C: clean blight leaf, must be confident AND sharp ---------------
    chosen_c = None
    for p in by_class["Tomato___Early_blight"]:
        with Image.open(p) as im:
            probs, sh = predict(im.copy()), sharpness(im.copy())
        if int(np.argmax(probs)) == BLIGHT and probs[BLIGHT] >= 0.90 and sh >= MIN_SHARPNESS:
            chosen_c = (p, probs, sh)
            break
    assert chosen_c, "no held-out blight leaf met the HIGH_CONFIDENCE bar"

    # --- B: same class, blurred until the quality gate must fire ---------
    chosen_b = None
    for p in by_class["Tomato___Early_blight"]:
        if p == chosen_c[0]:
            continue
        with Image.open(p) as im:
            blurred = im.convert("RGB").filter(
                ImageFilter.GaussianBlur(BLUR_RADIUS)
            )
        sh = sharpness(blurred)
        if sh < MIN_SHARPNESS * 0.5:  # comfortably under, not borderline
            chosen_b = (p, predict(blurred), sh, blurred)
            break
    assert chosen_b, "could not produce a reliably blurry leaf"

    # --- A: non-leaf object, must be rejected outright -------------------
    chosen_a = None
    for p in by_class["Background_Non_Leaf"]:
        with Image.open(p) as im:
            probs = predict(im.copy())
        if int(np.argmax(probs)) == BACKGROUND:
            chosen_a = (p, probs)
            break
    assert chosen_a, "no held-out background image was rejected"

    Image.open(chosen_a[0]).convert("RGB").save(
        OUT_DIR / "preset_a_object.jpg", quality=92)
    chosen_b[3].save(OUT_DIR / "preset_b_blurry_leaf.jpg", quality=92)
    Image.open(chosen_c[0]).convert("RGB").save(
        OUT_DIR / "preset_c_blight_leaf.jpg", quality=92)

    print(f"\nHeld-out pool: {len(val)} images\n")
    pa, pc = chosen_a[1], chosen_c[1]
    pb = chosen_b[1]
    print(f"A preset_a_object.jpg      background={pa[BACKGROUND]:.3f} "
          f"-> top={CLASS_NAMES[int(np.argmax(pa))]} -> OUT_OF_BOUNDS_REJECT")
    print(f"B preset_b_blurry_leaf.jpg blight={pb[BLIGHT]:.3f} "
          f"sharpness={chosen_b[2]:.1f} (< {MIN_SHARPNESS}) -> demoted to "
          f"LOW_CONFIDENCE_ESCALATE")
    print(f"C preset_c_blight_leaf.jpg blight={pc[BLIGHT]:.3f} "
          f"sharpness={chosen_c[2]:.1f} -> HIGH_CONFIDENCE")


if __name__ == "__main__":
    main()
