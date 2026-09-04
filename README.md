# 🌿 CropCureAI

**Offline-first crop disease diagnosis for smallholder farmers — built for hackathon demo.**

CropCureAI is a Flutter prototype that diagnoses crop leaf diseases entirely on-device: point the camera at a leaf, get a diagnosis with severity, localized remedies in Hindi + English, and voice guidance — all with **zero network calls**. When the AI isn't sure, it says so, and queues the scan for a human agriculture expert instead of guessing.

## Why it's different

Most plant-disease demos show a classifier. CropCureAI ships a **reliability layer** on top of one:

| Model output | What the app does |
|---|---|
| Confident + real leaf (score ≥ 0.70) | Full diagnosis: severity %, heatmap, remedies, voice readout |
| Unsure (score < 0.70) | Honest "Inconclusive Scan" — one tap queues it for expert review |
| Not a leaf / score < 0.40 | "No Valid Leaf Detected" — rejected instead of misdiagnosed |
| Confident **but the photo was dark/blurry** | Confidence is demoted — the app never gives a confident answer from an image it knows is compromised |

Other guardrails: a pre-inference **blur/brightness validator** (Laplacian variance + luminance, runs in ~tens of ms off the UI thread), and a pixel-level **severity calculator** that measures actual lesion coverage — the "Grad-CAM" heatmap is driven by that real lesion-density grid, not decoration.

## Features

- 📷 **Smart Scanner** — live camera with leaf bounding-box overlay, capture hints, and a gallery fallback for bad lighting (long-press the top bar, or the gallery button)
- 🧠 **On-device TFLite inference** — real MobileNetV2 classifier (8.5 MB, float32, 224×224 RGB) trained on PlantVillage tomato classes + a non-leaf background class; if the model file is ever missing or corrupt the app falls back to a deterministic mock instead of crashing
- 🔥 **Explainability** — Grad-CAM style AI-focus heatmap + "Why This Diagnosis?" breakdown (lesion density, confidence vs. image clarity, pathogen rationale)
- 📊 **Severity analysis** — Mild (<10%) / Moderate (10–30%) / Severe (>30%) from HSV-band lesion pixel classification
- 🗣️ **Offline voice assistant** — Hindi/English TTS via the device's native speech engine; remedy readouts with play/pause controls
- 🌱 **Localized remedies** — organic + chemical treatment steps, prevention, and KVK/Kisan Call Centre escalation advice, fully bilingual (`assets/data/remedies.json`)
- 📖 **Crop Health Passport** — local scan history with Improving/Stable/Worsening trends and a recovery chart (Day 1: 28% → Day 5: 12%)
- 📡 **Expert Escalation Queue** — inconclusive and severe scans wait offline and sync to KVK officers when connectivity returns ("Core App 100% Offline | 2 Scans Queued...")

## Project structure

```
lib/
├── main.dart                    # Theme, offline config, app entry
├── app_shell.dart               # 3-tab shell: Scanner / Passport / Queue
├── core/
│   ├── constants/               # Colors (Forest Green #1B5E20, severity palette)
│   ├── models/                  # DiagnosisResult, reliability states
│   ├── services/                # TFLiteService, AIReliabilityEngine,
│   │                            # RemedyService, VoiceAssistantService
│   └── utils/                   # ImageChecker (blur/brightness validator)
├── features/
│   ├── camera/                  # SmartScannerScreen + overlay
│   ├── diagnosis/               # Results screen, severity, heatmap, dialog
│   ├── passport/                # Scan history + recovery chart
│   └── escalation/              # Expert queue + offline status bar
└── widgets/                     # Demo presenter panel
assets/
├── models/                      # model.tflite (MobileNetV2) + labels.txt
└── data/remedies.json           # Bilingual remedy knowledge base
ml/                              # Model training (Python, not shipped in the app)
├── prepare_data.py              # Builds the 3-class dataset
├── train_export.py              # Trains MobileNetV2 -> exports model.tflite
└── evaluate.py                  # Scores the shipped .tflite + confusion matrix
```

## Training the model

The classifier is reproducible from scratch. Requires Python 3.11+ (developed on 3.13).

```bash
python -m venv ml/.venv
ml/.venv/Scripts/python.exe -m pip install tensorflow pillow pyarrow huggingface_hub

ml/.venv/Scripts/python.exe ml/prepare_data.py    # ~950 MB download, one-time
ml/.venv/Scripts/python.exe ml/train_export.py    # ~15 min on CPU
ml/.venv/Scripts/python.exe ml/evaluate.py        # confusion matrix + confidence spread
```

**Data.** 1,702 `Tomato___Early_blight` and 1,273 `Tomato___healthy` images from the
PlantVillage mirror on Hugging Face, plus 1,300 Imagenette photos as
`Background_Non_Leaf` — the app has to *reject* non-leaves, so it needs real
non-leaf photographs to learn from, not noise. Images are center-cropped square
before resizing, matching `copyResizeCropSquare` in `TFLiteService._preprocess`,
so training and on-device geometry are identical.

**Training.** MobileNetV2 (ImageNet weights), 6 epochs with the backbone frozen,
then 4 more fine-tuning the last 30 layers at `lr=1e-5` with BatchNorm kept frozen.
Augmentation (flip / rotate / zoom / contrast) lives in the input pipeline rather
than the model, so the exported graph is inference-only.

**Results** on the 855-image held-out split, measured on the exported `.tflite`:

| Actual \ Predicted | Early_blight | healthy | Background | Recall |
|---|---|---|---|---|
| `Tomato___Early_blight` | 343 | 0 | 0 | 100% |
| `Tomato___healthy` | 0 | 256 | 0 | 100% |
| `Background_Non_Leaf` | 0 | 0 | 256 | 100% |

**Read that number honestly.** 100% reflects how easy this benchmark is, not
field-readiness: PlantVillage images are single leaves shot on uniform lab
backgrounds, and Imagenette is trivially separable from them. Published work
repeatedly shows PlantVillage-trained models collapsing on real field photos
(cluttered backgrounds, mixed lighting, multiple leaves). Expect materially lower
accuracy on a real phone in a real field — which is exactly why the reliability
layer, not the classifier, is this project's actual contribution.

One consequence worth knowing before a demo: every held-out prediction scored
≥ 0.70 (min 0.732), so on *this* distribution the escalate and reject paths
never fire. They fire on genuinely out-of-distribution input — which is what the
presenter panel's Presets A and B exist to show.

## Getting started

Requires Flutter 3.35+ (developed on 3.47).

```bash
flutter pub get
flutter run
```

Build an APK:

```bash
flutter build apk --debug
```

**Android toolchain gotchas** (both hit on a fresh Windows setup):

- **NDK 28.2.13676358 is required** — it comes from `flutter.ndkVersion`, not from
  this repo. Gradle tries to auto-install it and fails with
  `Android sdkmanager did not install NDK 28.2.13676358`. Install it manually:
  ```bash
  "$ANDROID_HOME/cmdline-tools/latest/bin/android.exe" sdk install "ndk;28.2.13676358"
  ```
- **`flutter doctor` reports "Android license status unknown" and cannot be
  fixed.** Command-line tools 23.0 replaced the classic `sdkmanager` with a new
  Android CLI that dropped the `--licenses` flag, so `flutter doctor
  --android-licenses` just prints *"The --licenses option is no longer needed"*
  and Flutter can't parse a result. This is cosmetic — builds and installs work
  fine with the warning present.

Run the test suite (36 tests: reliability thresholds, severity math, storage, screens, demo presets):

```bash
flutter test
```

## 🎤 Demo instructions

**Before going on stage: turn on Airplane Mode.** The whole point — everything below works identically without internet.

Tap the ✨ icon in any tab's top bar to open the **Presenter Panel**. It loads
three sample scans. Each one is a **held-out image the model was never trained
on**, and each runs the **real pipeline** — quality check, on-device inference,
severity analysis. Nothing is precomputed and no probabilities are hardcoded,
so a judge who asks "is that actually your model?" gets a yes.
(`ml/make_demo_assets.py` picks these images and refuses to write one that
doesn't land in the state claimed below.)

1. **Preset A — Non-Leaf Object**
   → Red card: *"No Valid Leaf Detected."* The model scores it `Background_Non_Leaf` at 0.99999 and the app refuses out-of-distribution input instead of inventing a disease.

2. **Preset B — Blurry Leaf** (the one that shows the safety layer working)
   → Yellow card: *"Inconclusive Scan."* The model is **99.99% confident it's Early Blight** — and the app throws that away, because the blur check failed. This is the whole thesis in one screen: a confident answer from a compromised photo is not trustworthy. Tap **Save to Expert Queue**, then open the **Expert Queue** tab to see it waiting offline.

3. **Preset C — Tomato Early Blight**
   → Full diagnosis at ~100% confidence, severity measured live from the actual lesion pixels.
   - Tap **Show AI Focus (Grad-CAM)** — the heatmap sits on the real lesions (it's computed from them)
   - Tap **Why This Diagnosis?** — lesion density, confidence vs. clarity meters, pathogen rationale
   - Tap the **🔊 FAB** — Hindi voice reads the organic & chemical treatment steps aloud, offline
   - Toggle **हिंदी / EN** in the app bar to switch the whole remedy view + narration language

If `model.tflite` ever fails to load, a red **DEMO MODEL** banner appears above
every tab. If you don't see that banner, inference is real.

Live scan flow: **Smart Scanner** tab → point at any leaf (or long-press the top bar for the gallery fallback under bad stage lighting) → diagnosis screen. High-confidence scans are auto-saved to the **Health Passport** tab; scan the same crop over multiple days and the recovery chart appears.

## Tech notes

- **Model**: `assets/models/model.tflite` is a real MobileNetV2 transfer-learned classifier over 3 classes (`Tomato___Early_blight`, `Tomato___healthy`, `Background_Non_Leaf`). Float32, input `[1, 224, 224, 3]` in `[0, 1]`, output `[1, 3]` softmax. If the file is ever unreadable, `TFLiteService` falls back to a seeded mock (same image → same result) so the UI still runs.
- **Retraining**: everything under `ml/` reproduces the model — see [Training the model](#training-the-model). The `[0,1]` → `[-1,1]` rescale MobileNetV2 needs is baked in as the model's first layer, so `TFLiteService`'s `inputMean=0 / inputStd=255` normalization stays correct and the Dart side needs no changes.
- **Offline guarantee**: Google Fonts runtime fetching is disabled; TTS uses on-device engines; the only network touch is the Expert Queue's opt-in 2-second DNS probe that *displays* connectivity state.
- **Version pins**: `tflite_flutter ^0.12.1` and `flutter_tts ^4.2.5` are required minimums on Dart 3.5+/modern Gradle (older versions fail to compile). `android/build.gradle.kts` pins tflite_flutter's Kotlin JVM target to 11 to match its Java side.

## Tech stack

Flutter · Material 3 · `camera` · `image_picker` · `tflite_flutter` · `flutter_tts` · `image` · `shared_preferences` · `path_provider` · `google_fonts`

---


