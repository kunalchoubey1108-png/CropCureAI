"""Evaluate the shipped assets/models/model.tflite on the true holdout.

Runs the exact artifact the Flutter app loads (not the Keras model) over
ml/data_test -- PlantVillage's own 20% test parquet plus a disjoint slice of
non-leaf photos, none of it ever trained on -- and prints a per-class
confusion matrix plus the confidence distribution.

Done-when bar from docs/spec-11-class-classifier.md: no class below 70%
recall. The script exits non-zero if that fails.

The confidence histogram matters as much as accuracy: AIReliabilityEngine
routes on thresholds (>=0.70 trusted, <0.40 rejected as out-of-distribution),
so it needs to know where this model's scores actually land.

Run:  ml/.venv/Scripts/python.exe ml/evaluate.py
"""

from __future__ import annotations

from pathlib import Path

import numpy as np
import tensorflow as tf

from prepare_data import TEST_DIR
from train_export import CLASS_NAMES, IMG_SIZE, MODEL_OUT

# Mirrors AIReliabilityEngine's constants in Dart.
HIGH_CONFIDENCE_THRESHOLD = 0.70
OOD_SCORE_FLOOR = 0.40
MIN_RECALL = 0.70


def main() -> None:
    if not TEST_DIR.exists():
        raise SystemExit("ml/data_test missing -- run prepare_data.py first")
    val = tf.keras.utils.image_dataset_from_directory(
        directory=TEST_DIR,
        labels="inferred",
        label_mode="int",
        class_names=CLASS_NAMES,
        image_size=(IMG_SIZE, IMG_SIZE),
        batch_size=1,
        shuffle=False,
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

    # Columns are class indices; 11 full names do not fit across a terminal.
    width = max(len(c) for c in CLASS_NAMES)
    print(f"{'actual \\ predicted':<{width + 6}}" + "".join(
        f"{j:>6}" for j in range(n)
    ))
    recalls = []
    for i, name in enumerate(CLASS_NAMES):
        row = "".join(f"{confusion[i, j]:>6}" for j in range(n))
        recall = confusion[i, i] / max(confusion[i].sum(), 1)
        recalls.append(recall)
        print(f"{i:>2} {name:<{width + 3}}{row}   recall {recall:.2%}")

    scores = np.array(top_scores)
    print("\n=== Top-class confidence vs. AIReliabilityEngine thresholds ===")
    print(f"median {np.median(scores):.3f} | mean {scores.mean():.3f} "
          f"| min {scores.min():.3f}")
    trusted = (scores >= HIGH_CONFIDENCE_THRESHOLD).mean()
    rejected = (scores < OOD_SCORE_FLOOR).mean()
    print(f">= 0.70 (trusted outright)        : {trusted:.2%}")
    print(f"0.40-0.70 (escalated to expert)   : {1 - trusted - rejected:.2%}")
    print(f"<  0.40 (rejected as not-a-leaf)  : {rejected:.2%}")

    worst = min(range(n), key=lambda i: recalls[i])
    verdict = "PASS" if recalls[worst] >= MIN_RECALL else "FAIL"
    print(f"\n{verdict}: lowest recall {recalls[worst]:.2%} "
          f"({CLASS_NAMES[worst]}), bar {MIN_RECALL:.0%}")
    if verdict == "FAIL":
        raise SystemExit(1)


if __name__ == "__main__":
    main()
