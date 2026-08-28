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
- 🧠 **On-device TFLite inference** — 224×224 RGB pipeline; falls back to a deterministic mock model while `model.tflite` is a placeholder, so the app never crashes
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
├── models/                      # model.tflite (placeholder) + labels.txt
└── data/remedies.json           # Bilingual remedy knowledge base
```

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

Run the test suite (36 tests: reliability thresholds, severity math, storage, screens, demo presets):

```bash
flutter test
```

## 🎤 Demo instructions

**Before going on stage: turn on Airplane Mode.** The whole point — everything below works identically without internet.

Tap the ✨ icon in any tab's top bar to open the **Presenter Panel**. It loads three deterministic sample scenarios (synthesized locally, so the outcome is guaranteed regardless of venue lighting):

1. **Preset A — Garbage / Water Bottle Scan**
   → Red card: *"No Valid Leaf Detected."* The model refuses out-of-distribution input instead of inventing a disease.

2. **Preset B — Blurry / Unknown Disease**
   → Yellow card: *"Inconclusive Scan."* Tap **Save to Expert Queue**, then open the **Expert Queue** tab: the airplane-mode bar reads *"Core App 100% Offline | 1 Scan Queued for Expert Review when Online."*

3. **Preset C — Tomato Early Blight** (the money shot)
   → Full diagnosis at 91% confidence with **Moderate ≈ 18% severity**.
   - Tap **Show AI Focus (Grad-CAM)** — the heatmap lights up exactly over the drawn lesions (it's computed from them, live)
   - Tap **Why This Diagnosis?** — lesion density, confidence vs. clarity meters, pathogen rationale
   - Tap the **🔊 FAB** — Hindi voice reads the organic & chemical treatment steps aloud, offline
   - Toggle **हिंदी / EN** in the app bar to switch the whole remedy view + narration language

Live scan flow: **Smart Scanner** tab → point at any leaf (or long-press the top bar for the gallery fallback under bad stage lighting) → diagnosis screen. High-confidence scans are auto-saved to the **Health Passport** tab; scan the same crop over multiple days and the recovery chart appears.

## Tech notes

- **Model**: `assets/models/model.tflite` is an empty placeholder — `TFLiteService` detects the invalid model and switches to a seeded mock (same image → same result). Drop in a real 3-class model (`Tomato___Early_blight`, `Tomato___healthy`, `Background_Non_Leaf`, 224×224 float input) and the pipeline uses it automatically.
- **Offline guarantee**: Google Fonts runtime fetching is disabled; TTS uses on-device engines; the only network touch is the Expert Queue's opt-in 2-second DNS probe that *displays* connectivity state.
- **Version pins**: `tflite_flutter ^0.12.1` and `flutter_tts ^4.2.5` are required minimums on Dart 3.5+/modern Gradle (older versions fail to compile). `android/build.gradle.kts` pins tflite_flutter's Kotlin JVM target to 11 to match its Java side.

## Tech stack

Flutter · Material 3 · `camera` · `image_picker` · `tflite_flutter` · `flutter_tts` · `image` · `shared_preferences` · `path_provider` · `google_fonts`

---


