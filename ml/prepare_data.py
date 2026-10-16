"""Build the 11-class training set for CropCureAI's on-device classifier.

Classes match assets/models/labels.txt exactly, in order: the ten PlantVillage
tomato classes followed by a non-leaf background class.

Three things here are load-bearing and easy to get wrong:

1. **The label ids.** An earlier version of this file mapped id 28 to
   `Tomato___Early_blight`. It is not; 28 is `Tomato___Bacterial_spot` and
   Early blight is 29, so the shipped model named the wrong disease. The ids
   below are the standard PlantVillage alphabetical ordering, confirmed
   against the cached shards: every class count is exactly 80.0% of the
   published count (1702/2127, 800/1000, 1528/1909, 4286/5357, 299/373,
   1273/1591 ...), which both pins the ordering and identifies these shards
   as the dataset's 80% train split. `verify_label_ids()` re-checks this at
   runtime so the mistake cannot come back silently.

2. **The real holdout.** `data/test-00000-of-00001.parquet` is the other 20%.
   Splitting the train shards again would grade the model on data drawn from
   the same pool it learned from; evaluate.py uses ml/data_test instead.

3. **Composite augmentation.** PlantVillage is shot on uniform gray, so a
   model trained on it learns "uniform background => leaf" and rejects real
   photographs — measured at 29/40 before this change. We segment the leaf off
   its lab background and paste it onto real photos so the model has to
   recognise the leaf, not the backdrop.

Output layout:
    ml/data/<class>/*.jpg            training (originals + composites)
    ml/data_test/<class>/*.jpg       true held-out originals, never trained on
    ml/eval_backgrounds/*.jpg        backgrounds reserved for robustness_probe

Run:  ml/.venv/Scripts/python.exe ml/prepare_data.py
"""

from __future__ import annotations

import io
import random
import shutil
import tarfile
import urllib.request
from pathlib import Path

import numpy as np
import pyarrow.parquet as pq
from huggingface_hub import hf_hub_download
from PIL import Image, ImageDraw, ImageFilter

ML_DIR = Path(__file__).resolve().parent
DATA_DIR = ML_DIR / "data"
TEST_DIR = ML_DIR / "data_test"
EVAL_BG_DIR = ML_DIR / "eval_backgrounds"
CACHE_DIR = ML_DIR / ".cache"

PLANTVILLAGE_REPO = "BrandonFors/Plant-Diseases-PlantVillage-Dataset"
TRAIN_FILES = [
    "data/train-00000-of-00002.parquet",
    "data/train-00001-of-00002.parquet",
]
TEST_FILES = ["data/test-00000-of-00001.parquet"]

# PlantVillage ClassLabel ids -> our class directory names. Id 33 is
# "Tomato___Spider_mites Two-spotted_spider_mite" upstream; the space is
# dropped so the name survives being a directory and a labels.txt line.
LEAF_CLASSES = {
    28: "Tomato___Bacterial_spot",
    29: "Tomato___Early_blight",
    30: "Tomato___Late_blight",
    31: "Tomato___Leaf_Mold",
    32: "Tomato___Septoria_leaf_spot",
    33: "Tomato___Spider_mites",
    34: "Tomato___Target_Spot",
    35: "Tomato___Yellow_Leaf_Curl_Virus",
    36: "Tomato___Mosaic_virus",
    37: "Tomato___healthy",
}

# Published PlantVillage totals per class, used to re-derive the id ordering
# at runtime. The cached train shards should hold 80% of each.
PUBLISHED_COUNTS = {
    28: 2127, 29: 1000, 30: 1909, 31: 952, 32: 1771,
    33: 1676, 34: 1404, 35: 5357, 36: 373, 37: 1591,
}

IMAGENETTE_URL = "https://s3.amazonaws.com/fast-ai-imageclas/imagenette2-160.tgz"
BACKGROUND_CLASS = "Background_Non_Leaf"

# Three disjoint slices of Imagenette. Overlap between the augmentation pool
# and the eval pool would let the robustness probe grade the model on
# backgrounds it trained against, which is how you get a number that means
# nothing.
BACKGROUND_COUNT = 1300  # the "this is not a leaf" class
AUG_BG_COUNT = 1200      # pasted behind leaves in training
EVAL_BG_COUNT = 300      # reserved for robustness_probe.py
TEST_BG_COUNT = 200      # non-leaf holdout, so evaluate.py can score rejection

# Yellow Leaf Curl has 4286 cached images and Mosaic virus has 299. Left
# alone the model would learn the prior, not the disease.
PER_CLASS_CAP = 800
COMPOSITES_PER_CLASS = 800

# Images are stored at 256px; the model trains at 224. Saving a little
# larger leaves room for random-crop augmentation during training.
SAVE_SIZE = 256
SEED = 1337


def _square(image: Image.Image) -> Image.Image:
    """Center-crop to a square.

    This mirrors `img.copyResizeCropSquare` in TFLiteService._preprocess.
    Keras' image_dataset_from_directory squashes to 224x224 without keeping
    aspect ratio, so squaring here is what keeps training geometry and
    on-device inference geometry identical.
    """
    image = image.convert("RGB")
    side = min(image.size)
    left = (image.width - side) // 2
    top = (image.height - side) // 2
    return image.crop((left, top, left + side, top + side))


def _save(image: Image.Image, dest: Path) -> None:
    image = _square(image).resize((SAVE_SIZE, SAVE_SIZE), Image.LANCZOS)
    image.save(dest, "JPEG", quality=92)


# --- segmentation -------------------------------------------------------
# Exported for robustness_probe.py so the eval composites are built the same
# way as the training ones.

def leaf_cutout(image: Image.Image) -> Image.Image | None:
    """Return the leaf as RGBA with the lab background knocked out.

    PlantVillage frames are a single leaf on a gray backdrop, but the backdrop
    is vignetted and the leaf casts a shadow, so raw RGB distance from the
    border colour keeps chunks of gray and refuses most pale healthy leaves
    (measured: 85% refused). Brightness is what varies across the backdrop;
    its *tint* does not. So we compare chroma -- RGB minus the pixel's own
    mean -- against the border's chroma, which ignores vignette and shadow
    and still catches pale green. Measured on 100 images per class: 0-4%
    refused, mask never touches the frame edge.

    Morphology drops speckle and bridges lesions, a flood fill closes any
    hole a dark lesion left, and a soft alpha edge stops the paste leaving a
    cut-out seam the model could learn instead of the leaf.

    Returns None when the mask covers implausibly little or nearly all of the
    frame, which means the assumption broke and the image should be used
    as-is rather than composited.
    """
    rgb = _square(image).resize((SAVE_SIZE, SAVE_SIZE), Image.LANCZOS)
    arr = np.asarray(rgb, np.float32)
    chroma = arr - arr.mean(axis=2, keepdims=True)

    b = 8
    border = np.concatenate([
        chroma[:b].reshape(-1, 3), chroma[-b:].reshape(-1, 3),
        chroma[:, :b].reshape(-1, 3), chroma[:, -b:].reshape(-1, 3),
    ])
    bg = np.median(border, axis=0)
    dist = np.linalg.norm(chroma - bg, axis=2)
    cutoff = np.clip(np.percentile(np.linalg.norm(border - bg, axis=1), 90) + 4, 8, 60)
    leaf = (dist > cutoff) & (arr.max(axis=2) > 40)

    m = Image.fromarray(leaf.astype(np.uint8) * 255)
    m = m.filter(ImageFilter.MinFilter(5)).filter(ImageFilter.MaxFilter(5))  # drop speckle
    m = m.filter(ImageFilter.MaxFilter(7)).filter(ImageFilter.MinFilter(7))  # bridge lesions
    padded = Image.new("L", (SAVE_SIZE + 2, SAVE_SIZE + 2), 0)
    padded.paste(m, (1, 1))
    ImageDraw.floodfill(padded, (0, 0), 128)  # mark the outside...
    filled = np.asarray(padded)[1:-1, 1:-1] != 128  # ...everything else is leaf

    coverage = filled.mean()
    if not 0.08 < coverage < 0.90:
        return None

    m = Image.fromarray(filled.astype(np.uint8) * 255).filter(
        ImageFilter.GaussianBlur(1.2)  # feather
    )
    out = rgb.convert("RGBA")
    out.putalpha(m)
    return out.crop(out.getchannel("A").getbbox() or (0, 0, SAVE_SIZE, SAVE_SIZE))


def composite(cutout: Image.Image, background: Image.Image,
              rng: random.Random) -> Image.Image:
    """Paste a segmented leaf onto a real photo at random scale/pose."""
    canvas = _square(background).resize((SAVE_SIZE, SAVE_SIZE), Image.LANCZOS)
    leaf = cutout.rotate(
        rng.uniform(-180, 180), resample=Image.BICUBIC, expand=True
    )
    # Scale the longer side, keep aspect -- squashing to a square would
    # distort exactly the leaf shape the model is meant to learn.
    scale = SAVE_SIZE * rng.uniform(0.45, 0.95) / max(leaf.size)
    leaf = leaf.resize(
        (max(1, int(leaf.width * scale)), max(1, int(leaf.height * scale))),
        Image.LANCZOS,
    )
    x = rng.randint(0, SAVE_SIZE - leaf.width)
    y = rng.randint(0, SAVE_SIZE - leaf.height)
    canvas.paste(leaf, (x, y), leaf)
    return canvas


# --- dataset build ------------------------------------------------------

def _download(files: list[str]) -> list[Path]:
    out = []
    for remote in files:
        print(f"[data] fetching {remote} ...")
        out.append(Path(hf_hub_download(
            repo_id=PLANTVILLAGE_REPO, filename=remote,
            repo_type="dataset", cache_dir=CACHE_DIR,
        )))
    return out


def verify_label_ids(shards: list[Path]) -> None:
    """Fail loudly if the upstream id ordering ever changes under us.

    This is the check that would have caught the Bacterial-spot/Early-blight
    mixup on day one, so it runs before a single image is written.
    """
    counts: dict[int, int] = {}
    for shard in shards:
        for label in pq.read_table(shard, columns=["label"]).column("label").to_pylist():
            counts[label] = counts.get(label, 0) + 1

    for label_id, name in LEAF_CLASSES.items():
        got = counts.get(label_id, 0)
        expected = PUBLISHED_COUNTS[label_id] * 0.8
        if abs(got - expected) > max(5, expected * 0.02):
            raise SystemExit(
                f"Label id {label_id} ({name}) holds {got} images, expected "
                f"~{expected:.0f} (80% of {PUBLISHED_COUNTS[label_id]}). The "
                f"upstream class ordering has changed -- re-derive LEAF_CLASSES "
                f"before training, or the model will learn the wrong names."
            )
    print(f"[data] label ids verified against published counts ({len(LEAF_CLASSES)} classes)")


def extract_leaves(shards: list[Path], out_root: Path, cap: int | None) -> dict[str, int]:
    """Write up to `cap` images per tomato class into out_root/<class>/."""
    counts = {name: 0 for name in LEAF_CLASSES.values()}
    for name in LEAF_CLASSES.values():
        (out_root / name).mkdir(parents=True, exist_ok=True)

    for shard in shards:
        table = pq.read_table(shard, columns=["image", "label"])
        labels = table.column("label").to_pylist()
        images = table.column("image").to_pylist()
        for label, cell in zip(labels, images):
            name = LEAF_CLASSES.get(label)
            if name is None:
                continue
            if cap is not None and counts[name] >= cap:
                continue
            with Image.open(io.BytesIO(cell["bytes"])) as im:
                _save(im, out_root / name / f"{counts[name]:05d}.jpg")
            counts[name] += 1

    missing = [n for n, c in counts.items() if c == 0]
    if missing:
        raise SystemExit(f"No images extracted for {missing} -- label ids changed?")
    return counts


def imagenette_pools() -> tuple[list[bytes], list[bytes], list[bytes], list[bytes]]:
    """Four disjoint slices: non-leaf class, augmentation, probe eval, holdout."""
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    archive = CACHE_DIR / "imagenette2-160.tgz"
    if not archive.exists():
        print(f"[background] downloading {IMAGENETTE_URL} ...")
        urllib.request.urlretrieve(IMAGENETTE_URL, archive)

    total = BACKGROUND_COUNT + AUG_BG_COUNT + EVAL_BG_COUNT + TEST_BG_COUNT
    blobs: list[bytes] = []
    with tarfile.open(archive) as tar:
        members = [m for m in tar.getmembers() if m.name.lower().endswith(".jpeg")]
        random.Random(SEED).shuffle(members)
        for member in members:
            handle = tar.extractfile(member)
            if handle is None:
                continue
            blobs.append(handle.read())
            if len(blobs) >= total:
                break

    if len(blobs) < total:
        raise SystemExit(f"Imagenette yielded {len(blobs)} images, need {total}")

    a = BACKGROUND_COUNT
    b = a + AUG_BG_COUNT
    c = b + EVAL_BG_COUNT
    return blobs[:a], blobs[a:b], blobs[b:c], blobs[c:total]


def write_background_class(blobs: list[bytes], root: Path) -> None:
    out = root / BACKGROUND_CLASS
    out.mkdir(parents=True, exist_ok=True)
    for i, blob in enumerate(blobs):
        with Image.open(io.BytesIO(blob)) as im:
            _save(im, out / f"{i:05d}.jpg")
    print(f"[background] wrote {len(blobs)} non-leaf images to {out.parent.name}/")


def write_eval_backgrounds(blobs: list[bytes]) -> None:
    if EVAL_BG_DIR.exists():
        shutil.rmtree(EVAL_BG_DIR)
    EVAL_BG_DIR.mkdir(parents=True)
    for i, blob in enumerate(blobs):
        with Image.open(io.BytesIO(blob)) as im:
            _save(im, EVAL_BG_DIR / f"{i:05d}.jpg")
    print(f"[background] reserved {len(blobs)} eval-only backgrounds")


def add_composites(aug_blobs: list[bytes]) -> None:
    """Paste segmented training leaves onto real photos, in place."""
    rng = random.Random(SEED)
    backgrounds = [Image.open(io.BytesIO(b)).copy() for b in aug_blobs]

    for name in LEAF_CLASSES.values():
        folder = DATA_DIR / name
        sources = sorted(folder.glob("*.jpg"))
        made = skipped = 0
        i = 0
        # Cycle the originals until the quota is met; segmentation refuses
        # some frames, so this cannot be a straight slice.
        while made < COMPOSITES_PER_CLASS and i < len(sources) * 3:
            with Image.open(sources[i % len(sources)]) as im:
                cut = leaf_cutout(im.copy())
            i += 1
            if cut is None:
                skipped += 1
                continue
            bg = backgrounds[rng.randrange(len(backgrounds))]
            composite(cut, bg, rng).save(
                folder / f"comp_{made:05d}.jpg", "JPEG", quality=92
            )
            made += 1
        print(f"[composite] {name:34s} +{made:4d} (segmentation refused {skipped})")


def main() -> None:
    for d in (DATA_DIR, TEST_DIR):
        if d.exists():
            shutil.rmtree(d)
        d.mkdir(parents=True)

    train_shards = _download(TRAIN_FILES)
    verify_label_ids(train_shards)

    print("\n[train] extracting leaf classes ...")
    train_counts = extract_leaves(train_shards, DATA_DIR, PER_CLASS_CAP)
    print(f"[train] {train_counts}")

    print("\n[test] extracting the true holdout ...")
    test_shards = _download(TEST_FILES)
    test_counts = extract_leaves(test_shards, TEST_DIR, None)
    print(f"[test] {test_counts}")

    print("\n[background] slicing Imagenette ...")
    bg_class, bg_aug, bg_eval, bg_test = imagenette_pools()
    write_background_class(bg_class, DATA_DIR)
    write_background_class(bg_test, TEST_DIR)
    write_eval_backgrounds(bg_eval)

    print("\n[composite] building cluttered-background examples ...")
    add_composites(bg_aug)

    print("\nDataset ready:")
    for d in sorted(DATA_DIR.iterdir()):
        print(f"  {d.name:34s} {len(list(d.glob('*.jpg'))):5d} train")
    for d in sorted(TEST_DIR.iterdir()):
        print(f"  {d.name:34s} {len(list(d.glob('*.jpg'))):5d} holdout")


if __name__ == "__main__":
    main()
