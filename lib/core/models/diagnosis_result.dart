/// How much the app trusts a single inference, per the reliability rules
/// in `AIReliabilityEngine`.
enum ReliabilityState {
  /// Top score >= 0.70 and the top class is a real leaf class.
  highConfidence,

  /// Model saw a leaf but is unsure — route to the expert escalation flow.
  lowConfidenceEscalate,

  /// Not a leaf (background class won, or nothing scored >= 0.40).
  outOfBoundsReject,
}

/// What the UI should do with a [DiagnosisResult].
enum RecommendedAction {
  /// Show the remedy card for [DiagnosisResult.remedyKey].
  showRemedy,

  /// Open the expert escalation flow with the image attached.
  escalateToExpert,

  /// Show the "Invalid Leaf Image" error and return to the scanner.
  retakePhoto,
}

/// Structured outcome of one diagnosis, produced by `AIReliabilityEngine`
/// and consumed by the diagnosis UI and the Crop Passport history.
class DiagnosisResult {
  const DiagnosisResult({
    required this.className,
    required this.confidenceScore,
    required this.reliabilityState,
    required this.isOOD,
    required this.recommendedAction,
    required this.allScores,
    required this.timestamp,
    this.imagePath,
    this.usedMockModel = false,
  });

  /// Raw model label of the winning class (e.g. `Tomato___Early_blight`).
  final String className;

  /// Probability of [className], 0.0–1.0.
  final double confidenceScore;

  final ReliabilityState reliabilityState;

  /// True when the frame was judged out-of-distribution (not a leaf).
  final bool isOOD;

  final RecommendedAction recommendedAction;

  /// Full probability map, model label -> score.
  final Map<String, double> allScores;

  final DateTime timestamp;

  /// Source image, kept so the passport and escalation flows can show it.
  final String? imagePath;

  /// True when the placeholder mock inference produced this result
  /// (real `model.tflite` missing) — lets the UI show a demo-mode badge.
  final bool usedMockModel;

  /// Maps raw model labels to the keys used in `assets/data/remedies.json`.
  static const Map<String, String> classToRemedyKey = {
    'Tomato___Early_blight': 'TOMATO_EARLY_BLIGHT',
    'Tomato___healthy': 'TOMATO_HEALTHY',
    'Background_Non_Leaf': 'UNKNOWN_OOD',
  };

  /// Key into `remedies.json`; unknown labels fall back to the OOD advisory.
  String get remedyKey => classToRemedyKey[className] ?? 'UNKNOWN_OOD';

  Map<String, dynamic> toJson() => {
        'className': className,
        'confidenceScore': confidenceScore,
        'reliabilityState': reliabilityState.name,
        'isOOD': isOOD,
        'recommendedAction': recommendedAction.name,
        'allScores': allScores,
        'timestamp': timestamp.toIso8601String(),
        'imagePath': imagePath,
        'usedMockModel': usedMockModel,
      };

  factory DiagnosisResult.fromJson(Map<String, dynamic> json) {
    return DiagnosisResult(
      className: json['className'] as String,
      confidenceScore: (json['confidenceScore'] as num).toDouble(),
      reliabilityState:
          ReliabilityState.values.byName(json['reliabilityState'] as String),
      isOOD: json['isOOD'] as bool,
      recommendedAction:
          RecommendedAction.values.byName(json['recommendedAction'] as String),
      allScores: (json['allScores'] as Map<String, dynamic>)
          .map((k, v) => MapEntry(k, (v as num).toDouble())),
      timestamp: DateTime.parse(json['timestamp'] as String),
      imagePath: json['imagePath'] as String?,
      usedMockModel: json['usedMockModel'] as bool? ?? false,
    );
  }

  @override
  String toString() =>
      'DiagnosisResult($className @ ${(confidenceScore * 100).toStringAsFixed(1)}%, '
      '${reliabilityState.name}, action: ${recommendedAction.name}'
      '${usedMockModel ? ', MOCK' : ''})';
}
