import '../models/diagnosis_result.dart';
import '../utils/image_checker.dart';
import 'tflite_service.dart';

/// Turns raw model probabilities into a trustworthy, actionable verdict.
///
/// The engine is the app's safety layer: instead of blindly showing the
/// top class, it decides whether the prediction is safe to act on
/// (HIGH_CONFIDENCE), should be routed to a human expert
/// (LOW_CONFIDENCE_ESCALATE), or must be rejected as not-a-leaf
/// (OUT_OF_BOUNDS_REJECT).
class AIReliabilityEngine {
  const AIReliabilityEngine();

  /// Top score at or above this (on a leaf class) is trusted outright.
  static const double highConfidenceThreshold = 0.70;

  /// Below this, nothing is trusted at all — treated as out-of-distribution.
  static const double oodScoreFloor = 0.40;

  /// The explicit "not a leaf" class emitted by the model.
  static const String backgroundLabel = 'Background_Non_Leaf';

  /// Evaluates raw [scores] (label -> probability) plus optional image
  /// metadata into a structured [DiagnosisResult].
  ///
  /// [frameQuality] is the pre-inference check from `ImageChecker`; a
  /// flagged frame (dark/blurry) demotes HIGH_CONFIDENCE to
  /// LOW_CONFIDENCE_ESCALATE — we never hand out a confident diagnosis
  /// from an image we already know is compromised.
  DiagnosisResult evaluate({
    required Map<String, double> scores,
    FrameQualityResult? frameQuality,
    String? imagePath,
    bool usedMockModel = false,
  }) {
    assert(scores.isNotEmpty, 'scores must contain at least one class');

    final top = scores.entries.reduce((a, b) => a.value >= b.value ? a : b);
    final isOOD = top.key == backgroundLabel || top.value < oodScoreFloor;

    ReliabilityState state;
    if (isOOD) {
      state = ReliabilityState.outOfBoundsReject;
    } else if (top.value >= highConfidenceThreshold) {
      state = ReliabilityState.highConfidence;
    } else {
      state = ReliabilityState.lowConfidenceEscalate;
    }

    if (state == ReliabilityState.highConfidence &&
        frameQuality != null &&
        !frameQuality.isUsable) {
      state = ReliabilityState.lowConfidenceEscalate;
    }

    return DiagnosisResult(
      className: top.key,
      confidenceScore: top.value,
      reliabilityState: state,
      isOOD: isOOD,
      recommendedAction: switch (state) {
        ReliabilityState.highConfidence => RecommendedAction.showRemedy,
        ReliabilityState.lowConfidenceEscalate =>
          RecommendedAction.escalateToExpert,
        ReliabilityState.outOfBoundsReject => RecommendedAction.retakePhoto,
      },
      allScores: Map.unmodifiable(scores),
      timestamp: DateTime.now(),
      imagePath: imagePath,
      usedMockModel: usedMockModel,
    );
  }

  /// End-to-end convenience: quality-check + classify + evaluate one file.
  /// This is what the diagnosis screen will call from the scanner's
  /// `onImageReady` hand-off.
  Future<DiagnosisResult> diagnoseFile(
    String imagePath, {
    required TFLiteService tflite,
    FrameQualityResult? frameQuality,
  }) async {
    final inference = await tflite.classifyImage(imagePath);
    return evaluate(
      scores: inference.scores,
      frameQuality: frameQuality,
      imagePath: imagePath,
      usedMockModel: inference.isMock,
    );
  }
}
