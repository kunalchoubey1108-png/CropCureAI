"""Build the 3-class training set for CropCureAI's on-device classifier.

Classes match assets/models/labels.txt exactly, in order:
    0  Tomato___Early_blight
    1  Tomato___healthy
    2  Background_Non_Leaf

Leaf classes come from the PlantVillage mirror on the Hugging Face Hub.
The background class comes from Imagenette (everyday objects/animals) --
the app needs to reject anything that is not a leaf, so it needs real
non-leaf photographs, not noise.

Output layout (consumed by train_export.py):
    ml/data/Tomato___Early_blight/*.jpg
    ml/data/Tomato___healthy/*.jpg
    ml/data/Background_Non_Leaf/*.jpg

Run:  ml/.venv/Scripts/python.exe ml/prepare_data.py
"""

from __future__ import annotations

import io
import random
import shutil
import tarfile
import urllib.request
from pathlib import Path

import pyarrow.parquet as pq
from huggingface_hub import hf_hub_download
from PIL import Image

ML_DIR = Path(__file__).resolve().parent
DATA_DIR = ML_DIR / "data"
CACHE_DIR = ML_DIR / ".cache"

PLANTVILLAGE_REPO = "BrandonFors/Plant-Diseases-PlantVillage-Dataset"
PLANTVILLAGE_FILES = [
    "data/train-00000-of-00002.parquet",
    "data/train-00001-of-00002.parquet",
]
# Label ids inside that dataset's ClassLabel feature.
LEAF_CLASSES = {28: "Tomato___Early_blight", 37: "Tomato___healthy"}

IMAGENETTE_URL = "https://s3.amazonaws.com/fast-ai-imageclas/imagenette2-160.tgz"
BACKGROUND_CLASS = "Background_Non_Leaf"
BACKGROUND_COUNT = 1300

# Images are stored at 256px; the model trains at 224. Saving a little
# larger leaves room for random-crop augmentation during training.
SAVE_SIZE = 256
SEED = 1337


def _save(image: Image.Image, dest: Path) -> None:
    """Center-crop to a square, then resize.

    This mirrors `img.copyResizeCropSquare` in TFLiteService._preprocess.
    Keras' image_dataset_from_directory squashes to 224x224 without keeping
    aspect ratio, so squaring here is what keeps training geometry and
    on-device inference geometry identical.
    """
    image = image.convert("RGB")
    side = min(image.size)
    left = (image.width - side) // 2
    top = (image.height - side) // 2
    image = image.crop((left, top, left + side, top + side))
    image = image.resize((SAVE_SIZE, SAVE_SIZE), Image.LANCZOS)
    image.save(dest, "JPEG", quality=92)


def fetch_leaf_classes() -> None:
    """Pull the two tomato classes out of the PlantVillage parquet shards."""
    counts = {name: 0 for name in LEAF_CLASSES.values()}
    for name in LEAF_CLASSES.values():
        (DATA_DIR / name).mkdir(parents=True, exist_ok=True)

    for remote in PLANTVILLAGE_FILES:
        print(f"[leaf] downloading {remote} ...")
        local = hf_hub_download(
            repo_id=PLANTVILLAGE_REPO,
            filename=remote,
            repo_type="dataset",
            cache_dir=CACHE_DIR,
        )
        table = pq.read_table(local, columns=["image", "label"])
        labels = table.column("label").to_pylist()
        images = table.column("image").to_pylist()
        for label, cell in zip(labels, images):
            name = LEAF_CLASSES.get(label)
            if name is None:
                continue
            with Image.open(io.BytesIO(cell["bytes"])) as im:
                _save(im, DATA_DIR / name / f"{counts[name]:05d}.jpg")
            counts[name] += 1
        print(f"[leaf] running totals: {counts}")

    for name, n in counts.items():
        if n == 0:
            raise SystemExit(f"No images extracted for {name} -- label id changed?")


def fetch_background_class() -> None:
    """Sample Imagenette photos as the 'this is not a leaf' class."""
    out = DATA_DIR / BACKGROUND_CLASS
    out.mkdir(parents=True, exist_ok=True)

    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    archive = CACHE_DIR / "imagenette2-160.tgz"
    if not archive.exists():
        print(f"[background] downloading {IMAGENETTE_URL} ...")
        urllib.request.urlretrieve(IMAGENETTE_URL, archive)

    with tarfile.open(archive) as tar:
        members = [m for m in tar.getmembers() if m.name.lower().endswith(".jpeg")]
        random.Random(SEED).shuffle(members)
        for i, member in enumerate(members[:BACKGROUND_COUNT]):
            handle = tar.extractfile(member)
            if handle is None:
                continue
            with Image.open(io.BytesIO(handle.read())) as im:
                _save(im, out / f"{i:05d}.jpg")
    print(f"[background] wrote {len(list(out.glob('*.jpg')))} images")


def main() -> None:
    if DATA_DIR.exists():
        shutil.rmtree(DATA_DIR)
    DATA_DIR.mkdir(parents=True)

    fetch_leaf_classes()
    fetch_background_class()

    print("\nDataset ready:")
    for d in sorted(DATA_DIR.iterdir()):
        print(f"  {d.name:28s} {len(list(d.glob('*.jpg'))):5d} images")


if __name__ == "__main__":
    main()
