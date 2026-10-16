# Spec: fix mislabeled blight class, expand to 11 classes, survive cluttered backgrounds

Status: approved 2026-09-06. Not filed as a GitHub issue — this repo is
`kunalchoubey1108-png/CropCureAI` and we currently have pull-only access.

## Problem

Three defects in the on-device classifier, all fixed by one retrain.

### 1. The blight class is mislabeled

`ml/prepare_data.py` mapped PlantVillage label id `28` to
`Tomato___Early_blight`. Id 28 is `Tomato___Bacterial_spot`; Early blight is
id `29`.

Evidence: every class count in the cached parquet is exactly 80.0% of the
published PlantVillage count — 1702/2127, 800/1000, 1528/1909, 4286/5357,
299/373, 1273/1591, ten classes for ten. That pins the ids to the standard
alphabetical ordering, and identifies the cached shards as the 80% train
split. Rendered samples agree: id 29 shows early blight's concentric dark
lesions, id 28 does not.

The shipped app named the wrong disease and served the wrong treatment for it.
The README's 100% confusion matrix was arithmetically real but measured a
mislabeled class.

### 2. Only 3 classes

Any of the other 8 tomato diseases was forced into `Early_blight` /
`Tomato___healthy` / `Background_Non_Leaf`. A farmer with Late blight was told
something else, confidently.

### 3. Leaves on real backgrounds are rejected

`ml/robustness_probe.py` measured 29/40 (72.5%) of held-out healthy leaves
classified `Background_Non_Leaf` once composited onto a real background.
Training data is lab-shot on uniform gray, so the model learned
"uniform background ⇒ leaf". This broke the app in exactly its intended
setting.

## Desired behavior

11 classes — 9 tomato diseases + healthy + non-leaf — correctly labeled, with
**≥80% correct-disease accuracy on composited real backgrounds** (from 27.5%
surviving as any leaf class).

## Decisions

| Question | Answer |
|---|---|
| Deadline | None fixed |
| Disease scope | All 9 + healthy + non-leaf (11 classes) |
| Remedy content | Full organic + chemical drafted here, teammate reviews chemical later |
| Pass bar | ≥80% correct disease on composites |
| Ordering | One combined retrain |
| Validation data | Download the real 20% holdout (`data/test-00000-of-00001.parquet`) |
| Segmentation | Auto-segment cached images; no extra download |
| Class imbalance | Cap each class at ~800 originals |
| Out of scope | `AIReliabilityEngine`'s 0.70 / 0.40 thresholds |

## Scope

In:

- `ml/prepare_data.py` — correct id map, all 10 tomato ids, download the real
  holdout, cap per class, auto-segment, composite augmentation
- `ml/train_export.py` — 11-way head
- `ml/robustness_probe.py` — masked compositing, held-out background pool so
  the 80% number is not self-graded
- `assets/models/labels.txt` — 11 lines
- `lib/core/services/tflite_service.dart` `defaultLabels` — 11 entries
- `lib/core/models/diagnosis_result.dart` `classToRemedyKey` — 11 entries,
  plus a test asserting every label has a remedy key and every key resolves
  (today an unmapped label silently degrades to `UNKNOWN_OOD`)
- `assets/data/remedies.json` — 8 new entries, bilingual EN/HI
- `README.md` — corrected results, honest composite-vs-field caveat

Out:

- `AIReliabilityEngine`'s 0.70 / 0.40 thresholds. Follow-up: 11-way softmax
  spreads probability thinner than 3-way, so these likely need retuning —
  separate issue, separate measurement.

## Safety gate on remedy content

Chemical treatment advice cannot be verified here against Indian agricultural
regulation — pesticide names, concentrations, and pre-harvest intervals. A
wrong dosage rendered in Hindi is real-world harm to a farmer.

So the work splits. Symptoms, prevention, and organic/cultural steps ship
unblocked. Every `chemical_treatment` block for the 8 new diseases ships with
`"chemical_reviewed": false`, and the app renders the KVK / Kisan Call Centre
1800-180-1551 pointer in place of unreviewed chemical advice. A teammate flips
the flag per disease after checking an ICAR/TNAU reference.

The app is useful and safe if that review never happens; it gets better when
it does.

## Done when

1. `ml/evaluate.py` on the true held-out test parquet — no class below 70% recall
2. `ml/robustness_probe.py` composite condition — ≥80% correct disease, on
   held-out backgrounds
3. Early blight predictions are actually early blight (spot-check id-29 images)
4. `flutter test` green, including the new label↔remedy coverage test
5. `flutter analyze` clean

## Known limitation

The 80% is measured on **synthetic composites**, not field photos.
`spmohanty/PlantVillage-Dataset` is the same lab-shot data already cached here
— it is not a field set. Mohanty et al. (2016) report accuracy falling to
31.4% on images captured under different conditions. Real field accuracy
remains unmeasured, which is exactly why the reliability layer is the product.
