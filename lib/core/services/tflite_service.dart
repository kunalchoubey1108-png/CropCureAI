import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';

/// Raw output of one classification pass.
class InferenceResult {
  const InferenceResult({required this.scores, required this.isMock});

  /// Model label -> probability (softmaxed, sums to ~1.0).
  final Map<String, double> scores;

  /// True when the mock fallback produced these scores because the real
  /// model could not be loaded.
  final bool isMock;
}

/// Loads the bundled TFLite model and runs on-device classification.
///
/// Hackathon safeguard: `assets/models/model.tflite` is currently an empty
/// placeholder, so [load] catches every failure and flips the service into
/// mock mode — [classifyImage] then returns deterministic, plausible
/// probabilities so the full UI flow works before the real model lands.
class TFLiteService {
  /// App-wide shared instance so the interpreter is loaded once.
  static final TFLiteService instance = TFLiteService();

  static const String modelAsset = 'assets/models/model.tflite';
  static const String labelsAsset = 'assets/models/labels.txt';

  /// Model input is a [1, 224, 224, 3] float32 tensor.
  static const int inputSize = 224;

  /// Pixel normalization: value -> (value - mean) / std. The current
  /// (0, 255) pair maps pixels to [0, 1]; switch to (127.5, 127.5) for
  /// [-1, 1] if the exported model was trained that way.
  static const double inputMean = 0;
  static const double inputStd = 255;

  /// Used until labels.txt is readable; order must match the model head
  /// (`CLASS_NAMES` in ml/train_export.py).
  static const List<String> defaultLabels = [
    'Tomato___Bacterial_spot',
    'Tomato___Early_blight',
    'Tomato___Late_blight',
    'Tomato___Leaf_Mold',
    'Tomato___Septoria_leaf_spot',
    'Tomato___Spider_mites',
    'Tomato___Target_Spot',
    'Tomato___Yellow_Leaf_Curl_Virus',
    'Tomato___Mosaic_virus',
    'Tomato___healthy',
    'Background_Non_Leaf',
  ];

  Interpreter? _interpreter;
  List<String> _labels = defaultLabels;
  Future<void>? _loading;

  /// True when inference is running on canned mock logic, not the model.
  /// Only meaningful once [load] has completed.
  bool get isMockMode => _interpreter == null;

  /// Idempotent; safe to call eagerly at app start and again before use.
  ///
  /// Concurrent callers share one in-flight future. Returning early on a
  /// "load already started" flag instead would let the second caller run
  /// while the interpreter is still null, so a scan taken moments after
  /// launch would silently fall back to mock scores with a perfectly good
  /// model on disk.
  Future<void> load() => _loading ??= _load();

  Future<void> _load() async {
    try {
      final raw = await rootBundle.loadString(labelsAsset);
      final parsed = raw
          .split('\n')
          .map((l) => l.trim())
          .where((l) => l.isNotEmpty)
          .toList();
      if (parsed.isNotEmpty) _labels = parsed;
    } catch (e) {
      debugPrint('TFLiteService: labels.txt unreadable, using defaults ($e)');
    }

    try {
      _interpreter = await Interpreter.fromAsset(modelAsset);
      debugPrint(
        'TFLiteService: model loaded '
        '(input: ${_interpreter!.getInputTensor(0).shape})',
      );
    } catch (e) {
      // Placeholder/invalid model — run in mock mode so the UI never crashes.
      _interpreter = null;
      debugPrint('TFLiteService: model unavailable, MOCK MODE active ($e)');
    }
  }

  /// Classifies the image at [path] and returns per-class probabilities.
  Future<InferenceResult> classifyImage(String path) async {
    await load();
    if (isMockMode) {
      return InferenceResult(scores: await _mockScores(path), isMock: true);
    }

    final bytes = await File(path).readAsBytes();
    final input = await compute(_preprocess, bytes);

    final output = List<double>.filled(
      _labels.length,
      0,
    ).reshape([1, _labels.length]);
    _interpreter!.run(input.reshape([1, inputSize, inputSize, 3]), output);

    final raw = (output[0] as List).cast<double>();
    final probs = _ensureSoftmax(raw);
    final scores = {
      for (var i = 0; i < _labels.length; i++) _labels[i]: probs[i],
    };
    // Keep this: "everything is blight" turned out to be a stale build
    // running in mock mode, and one log line settles that question.
    debugPrint('TFLiteService: scores=$scores');
    return InferenceResult(scores: scores, isMock: false);
  }

  void dispose() {
    _interpreter?.close();
    _interpreter = null;
    _loading = null;
  }

  /// Decode -> center-crop square -> 224x224 -> normalized float32 RGB.
  static Float32List _preprocess(Uint8List bytes) {
    final decoded = img.decodeImage(bytes);
    if (decoded == null) {
      throw const FormatException('Could not decode image for inference');
    }
    final resized = img.copyResizeCropSquare(decoded, size: inputSize);

    final tensor = Float32List(inputSize * inputSize * 3);
    var i = 0;
    for (var y = 0; y < inputSize; y++) {
      for (var x = 0; x < inputSize; x++) {
        final p = resized.getPixel(x, y);
        tensor[i++] = (p.r - inputMean) / inputStd;
        tensor[i++] = (p.g - inputMean) / inputStd;
        tensor[i++] = (p.b - inputMean) / inputStd;
      }
    }
    return tensor;
  }

  /// Applies softmax when the head emitted logits instead of probabilities.
  static List<double> _ensureSoftmax(List<double> raw) {
    final sum = raw.fold(0.0, (a, b) => a + b);
    final looksLikeProbs =
        raw.every((v) => v >= 0 && v <= 1) && (sum - 1).abs() < 0.02;
    if (looksLikeProbs) return raw;

    final maxV = raw.reduce(max);
    final exps = raw.map((v) => exp(v - maxV)).toList();
    final expSum = exps.fold(0.0, (a, b) => a + b);
    return exps.map((v) => v / expSum).toList();
  }

  /// Deterministic per-file mock: the same image always yields the same
  /// result (stable demos), and the scenario mix exercises every
  /// reliability state — confident disease/healthy, low-confidence
  /// escalation, and background rejection.
  Future<Map<String, double>> _mockScores(String path) async {
    var seed = path.hashCode;
    try {
      seed ^= await File(path).length();
    } catch (_) {
      // File unreadable — fall back to the path-only seed.
    }
    final rng = Random(seed);

    // Look classes up by name, never by index: the head's order changes
    // whenever classes are added, and index 2 stopped meaning "background"
    // the day the model went from 3 classes to 11.
    final labels = _labels;
    final background = labels.lastWhere(
      (l) => l == 'Background_Non_Leaf',
      orElse: () => labels.last,
    );
    final healthy = labels.firstWhere(
      (l) => l == 'Tomato___healthy',
      orElse: () => labels.first,
    );
    final diseases = [
      for (final l in labels)
        if (l != background && l != healthy) l,
    ];
    final disease = diseases.isEmpty
        ? healthy
        : diseases[rng.nextInt(diseases.length)];

    final String top;
    final double topScore;
    final roll = rng.nextDouble();
    if (roll < 0.40) {
      top = disease;
      topScore = 0.72 + rng.nextDouble() * 0.23; // high-confidence disease
    } else if (roll < 0.70) {
      top = healthy;
      topScore = 0.72 + rng.nextDouble() * 0.23; // high-confidence healthy
    } else if (roll < 0.85) {
      top = disease;
      topScore = 0.45 + rng.nextDouble() * 0.20; // low-confidence -> escalate
    } else {
      top = background;
      topScore = 0.55 + rng.nextDouble() * 0.35; // OOD -> reject
    }

    // Split the remaining probability mass over the other classes.
    final others = labels.where((l) => l != top).toList();
    final weights = [for (final _ in others) rng.nextDouble() + 0.05];
    final weightSum = weights.fold(0.0, (a, b) => a + b);
    final remainder = 1.0 - topScore;

    return {
      top: topScore,
      for (var i = 0; i < others.length; i++)
        others[i]: remainder * weights[i] / weightSum,
    };
  }
}
