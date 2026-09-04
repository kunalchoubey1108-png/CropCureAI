"""Evaluate the shipped assets/models/model.tflite on the held-out split.

Runs the exact artifact the Flutter app loads (not the Keras model) through
the same validation split train_export.py held back, and prints a per-class
confusion matrix plus the confidence distribution.

The confidence histogram matters as much as accuracy: AIReliabilityEngine
routes on thresholds (>=0.70 trusted, <0.40 rejected as out-of-distribution),
so it needs to know where this model's scores actually land.

Run:  ml/.venv/Scripts/python.exe ml/evaluate.py
"""

from __future__ import annotations

from pathlib import Path

import numpy as np
import tensorflow as tf

from train_export import (
    CLASS_NAMES,
    DATA_DIR,
    IMG_SIZE,
    MODEL_OUT,
    SEED,
    VAL_SPLIT,
)

# Mirrors AIReliabilityEngine's constants in Dart.
HIGH_CONFIDENCE_THRESHOLD = 0.70
OOD_SCORE_FLOOR = 0.40


def main() -> None:
    val = tf.keras.utils.image_dataset_from_directory(
        directory=DATA_DIR,
        labels="inferred",
        label_mode="int",
        class_names=CLASS_NAMES,
        image_size=(IMG_SIZE, IMG_SIZE),
        batch_size=1,
        seed=SEED,
        validation_split=VAL_SPLIT,
        subset="validation",
        # Leave shuffling on: Keras shuffles the file list with `seed`
        # *before* carving off the split, so this is what reproduces the
        # exact held-out set train_export.py used. Passing shuffle=False
        # instead slices the last 20% in directory order -- i.e. one class.
    )

    interpreter = tf.lite.Interpreter(model_path=str(MODEL_OUT))
    interpreter.allocate_tensors()
    inp = interpreter.get_input_details()[0]
    out = interpreter.get_output_details()[0]

    n = len(CLASS_NAMES)
    confusion = np.zeros((n, n), dtype=int)
    top_scores: list[float] = []

    for images, labels in val:
        # The app feeds [0, 1]; the dataset yields [0, 255].
        x = (images.numpy() / 255.0).astype(np.float32)
        interpreter.set_tensor(inp["index"], x)
        interpreter.invoke()
        probs = interpreter.get_tensor(out["index"])[0]
        confusion[int(labels.numpy()[0]), int(np.argmax(probs))] += 1
        top_scores.append(float(np.max(probs)))

    total = confusion.sum()
    correct = np.trace(confusion)
    print(f"\nHeld-out images: {total}")
    print(f"Overall accuracy: {correct / total:.2%}\n")

    width = max(len(c) for c in CLASS_NAMES)
    print(f"{'actual \\ predicted':<{width + 2}}" + "".join(
        f"{c[:14]:>16}" for c in CLASS_NAMES
    ))
    for i, name in enumerate(CLASS_NAMES):
        row = "".join(f"{confusion[i, j]:>16}" for j in range(n))
        recall = confusion[i, i] / max(confusion[i].sum(), 1)
        print(f"{name:<{width + 2}}{row}   recall {recall:.2%}")

    scores = np.array(top_scores)
    print("\n=== Top-class confidence vs. AIReliabilityEngine thresholds ===")
    print(f"median {np.median(scores):.3f} | mean {scores.mean():.3f} "
          f"| min {scores.min():.3f}")
    trusted = (scores >= HIGH_CONFIDENCE_THRESHOLD).mean()
    rejected = (scores < OOD_SCORE_FLOOR).mean()
    print(f">= 0.70 (trusted outright)        : {trusted:.2%}")
    print(f"0.40-0.70 (escalated to expert)   : {1 - trusted - rejected:.2%}")
    print(f"<  0.40 (rejected as not-a-leaf)  : {rejected:.2%}")


if __name__ == "__main__":
    main()
