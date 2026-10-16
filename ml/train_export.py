"""Train CropCureAI's 11-class leaf classifier and export assets/models/model.tflite.

Transfer-learns a MobileNetV2 backbone (ImageNet weights) on the dataset
built by prepare_data.py, then writes a float32 TFLite model that drops
straight into the Flutter app with no changes to TFLiteService.

Contract with lib/core/services/tflite_service.dart -- do not break these:
  * input  : float32 [1, 224, 224, 3], values in [0, 1]
             (the app normalizes with inputMean=0, inputStd=255)
  * output : float32 [1, 11], softmax probabilities
  * class order must match assets/models/labels.txt line-for-line

MobileNetV2 wants [-1, 1] inputs, so the [0,1] -> [-1,1] rescale is baked
in as the model's first layer. That keeps the Dart side untouched.

Run:  ml/.venv/Scripts/python.exe ml/train_export.py
"""

from __future__ import annotations

import shutil
from pathlib import Path

import numpy as np
import tensorflow as tf

from prepare_data import BACKGROUND_CLASS, LEAF_CLASSES

ML_DIR = Path(__file__).resolve().parent
DATA_DIR = ML_DIR / "data"
REPO_DIR = ML_DIR.parent
MODEL_OUT = REPO_DIR / "assets" / "models" / "model.tflite"
LABELS_OUT = REPO_DIR / "assets" / "models" / "labels.txt"

# Order is load-bearing: index i here must equal line i of labels.txt, and
# lib/core/services/tflite_service.dart defaultLabels. Derived from
# prepare_data so the directory names and the head can never disagree.
CLASS_NAMES = [*LEAF_CLASSES.values(), BACKGROUND_CLASS]

IMG_SIZE = 224
BATCH_SIZE = 32
VAL_SPLIT = 0.2
SEED = 1337
FROZEN_EPOCHS = 4
# 11 look-alike diseases plus leaves on real backgrounds need far more
# fine-tuning than the old 3-class set: at 4 epochs / 30 layers / 1e-5 the
# model ended underfit (train 74% < val 75%) and failed both spec bars.
FINETUNE_EPOCHS = 14
FINETUNE_LAYERS = 60  # last N backbone layers unfrozen in stage 2
FINETUNE_LR = 1e-4


def build_datasets() -> tuple[tf.data.Dataset, tf.data.Dataset]:
    common = dict(
        directory=DATA_DIR,
        labels="inferred",
        label_mode="int",
        class_names=CLASS_NAMES,
        image_size=(IMG_SIZE, IMG_SIZE),
        batch_size=BATCH_SIZE,
        seed=SEED,
        validation_split=VAL_SPLIT,
    )
    train = tf.keras.utils.image_dataset_from_directory(subset="training", **common)
    val = tf.keras.utils.image_dataset_from_directory(subset="validation", **common)

    # image_dataset_from_directory yields [0, 255]; the app feeds [0, 1].
    to_unit = tf.keras.layers.Rescaling(1.0 / 255)
    train = train.map(lambda x, y: (to_unit(x), y), tf.data.AUTOTUNE)
    val = val.map(lambda x, y: (to_unit(x), y), tf.data.AUTOTUNE)

    # Augmentation lives in the input pipeline, not the model, so the
    # exported TFLite graph contains inference ops only.
    augment = tf.keras.Sequential(
        [
            tf.keras.layers.RandomFlip("horizontal_and_vertical"),
            tf.keras.layers.RandomRotation(0.2),
            tf.keras.layers.RandomZoom(0.15),
            tf.keras.layers.RandomContrast(0.15),
        ],
        name="augment",
    )
    train = train.map(
        lambda x, y: (augment(x, training=True), y), tf.data.AUTOTUNE
    )

    return (
        train.shuffle(1000, seed=SEED).prefetch(tf.data.AUTOTUNE),
        val.cache().prefetch(tf.data.AUTOTUNE),
    )


def build_model() -> tuple[tf.keras.Model, tf.keras.Model]:
    backbone = tf.keras.applications.MobileNetV2(
        input_shape=(IMG_SIZE, IMG_SIZE, 3),
        include_top=False,
        weights="imagenet",
    )
    backbone.trainable = False

    inputs = tf.keras.Input(shape=(IMG_SIZE, IMG_SIZE, 3), name="image")
    # App sends [0, 1]; MobileNetV2 expects [-1, 1].
    x = tf.keras.layers.Rescaling(2.0, offset=-1.0, name="to_mobilenet_range")(inputs)
    x = backbone(x, training=False)
    x = tf.keras.layers.GlobalAveragePooling2D()(x)
    x = tf.keras.layers.Dropout(0.3)(x)
    outputs = tf.keras.layers.Dense(
        len(CLASS_NAMES), activation="softmax", name="probs"
    )(x)

    return tf.keras.Model(inputs, outputs, name="cropcure_mobilenetv2"), backbone


def train(model: tf.keras.Model, backbone: tf.keras.Model, train_ds, val_ds) -> None:
    model.compile(
        optimizer=tf.keras.optimizers.Adam(1e-3),
        loss="sparse_categorical_crossentropy",
        metrics=["accuracy"],
    )
    print("\n=== Stage 1: frozen backbone ===")
    model.fit(train_ds, validation_data=val_ds, epochs=FROZEN_EPOCHS)

    print("\n=== Stage 2: fine-tuning top of backbone ===")
    backbone.trainable = True
    for layer in backbone.layers[:-FINETUNE_LAYERS]:
        layer.trainable = False
    # BatchNorm stays frozen -- unfreezing it on a small set wrecks accuracy.
    for layer in backbone.layers:
        if isinstance(layer, tf.keras.layers.BatchNormalization):
            layer.trainable = False

    model.compile(
        optimizer=tf.keras.optimizers.Adam(FINETUNE_LR),
        loss="sparse_categorical_crossentropy",
        metrics=["accuracy"],
    )
    model.fit(
        train_ds,
        validation_data=val_ds,
        epochs=FINETUNE_EPOCHS,
        callbacks=[
            tf.keras.callbacks.ReduceLROnPlateau(
                monitor="val_loss", factor=0.3, patience=2, verbose=1
            ),
            tf.keras.callbacks.EarlyStopping(
                monitor="val_loss", patience=4, restore_best_weights=True
            ),
        ],
    )


def export_tflite(model: tf.keras.Model) -> None:
    """Export a float32 TFLite model with a fixed [1, 224, 224, 3] input."""
    # Keras 3 models do not always convert directly; the SavedModel route is
    # the supported path and also pins the batch dimension to 1, which is
    # what Interpreter.run() on the Dart side feeds.
    export_dir = ML_DIR / ".export"
    if export_dir.exists():
        shutil.rmtree(export_dir)
    archive = tf.keras.export.ExportArchive()
    archive.track(model)
    archive.add_endpoint(
        name="serve",
        fn=model.call,
        input_signature=[
            tf.TensorSpec(shape=(1, IMG_SIZE, IMG_SIZE, 3), dtype=tf.float32)
        ],
    )
    archive.write_out(str(export_dir))

    converter = tf.lite.TFLiteConverter.from_saved_model(str(export_dir))
    converter.optimizations = []  # float32: matches the Dart Float32List input
    tflite_bytes = converter.convert()

    MODEL_OUT.parent.mkdir(parents=True, exist_ok=True)
    MODEL_OUT.write_bytes(tflite_bytes)
    LABELS_OUT.write_text("\n".join(CLASS_NAMES) + "\n", encoding="utf-8")
    print(f"\nWrote {MODEL_OUT} ({len(tflite_bytes) / 1_048_576:.2f} MB)")


def verify(val_ds) -> None:
    """Re-load the exported file and assert the app's contract holds."""
    interpreter = tf.lite.Interpreter(model_path=str(MODEL_OUT))
    interpreter.allocate_tensors()
    inp = interpreter.get_input_details()[0]
    out = interpreter.get_output_details()[0]

    print("\n=== Exported model contract ===")
    print(f"input  shape={inp['shape'].tolist()} dtype={inp['dtype'].__name__}")
    print(f"output shape={out['shape'].tolist()} dtype={out['dtype'].__name__}")
    assert list(inp["shape"]) == [1, IMG_SIZE, IMG_SIZE, 3], "input shape mismatch"
    assert list(out["shape"]) == [1, len(CLASS_NAMES)], "output shape mismatch"
    assert inp["dtype"] == np.float32 and out["dtype"] == np.float32

    correct = total = 0
    for images, labels in val_ds.unbatch().batch(1).take(200):
        interpreter.set_tensor(inp["index"], images.numpy().astype(np.float32))
        interpreter.invoke()
        probs = interpreter.get_tensor(out["index"])[0]
        assert abs(probs.sum() - 1.0) < 1e-3, f"output not softmaxed: {probs.sum()}"
        correct += int(np.argmax(probs) == int(labels.numpy()[0]))
        total += 1
    print(f"TFLite accuracy on {total} held-out images: {correct / total:.1%}")


def main() -> None:
    if not DATA_DIR.exists():
        raise SystemExit("ml/data missing -- run prepare_data.py first")

    train_ds, val_ds = build_datasets()
    model, backbone = build_model()
    train(model, backbone, train_ds, val_ds)

    loss, acc = model.evaluate(val_ds, verbose=0)
    print(f"\nKeras validation accuracy: {acc:.1%} (loss {loss:.4f})")

    export_tflite(model)
    verify(val_ds)


if __name__ == "__main__":
    main()
