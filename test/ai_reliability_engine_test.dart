import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:cropcure_ai/core/models/diagnosis_result.dart';
import 'package:cropcure_ai/core/services/ai_reliability_engine.dart';
import 'package:cropcure_ai/core/services/tflite_service.dart';
import 'package:cropcure_ai/core/utils/image_checker.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const engine = AIReliabilityEngine();

  group('AIReliabilityEngine.evaluate', () {
    test('high score on a leaf class -> HIGH_CONFIDENCE / showRemedy', () {
      final result = engine.evaluate(scores: {
        'Tomato___Early_blight': 0.82,
        'Tomato___healthy': 0.10,
        'Background_Non_Leaf': 0.08,
      });
      expect(result.reliabilityState, ReliabilityState.highConfidence);
      expect(result.recommendedAction, RecommendedAction.showRemedy);
      expect(result.isOOD, isFalse);
      expect(result.remedyKey, 'TOMATO_EARLY_BLIGHT');
    });

    test('exactly 0.70 counts as high confidence (>= threshold)', () {
      final result = engine.evaluate(scores: {
        'Tomato___healthy': 0.70,
        'Tomato___Early_blight': 0.20,
        'Background_Non_Leaf': 0.10,
      });
      expect(result.reliabilityState, ReliabilityState.highConfidence);
    });

    test('mid score -> LOW_CONFIDENCE_ESCALATE / escalateToExpert', () {
      final result = engine.evaluate(scores: {
        'Tomato___Early_blight': 0.55,
        'Tomato___healthy': 0.30,
        'Background_Non_Leaf': 0.15,
      });
      expect(result.reliabilityState, ReliabilityState.lowConfidenceEscalate);
      expect(result.recommendedAction, RecommendedAction.escalateToExpert);
      expect(result.isOOD, isFalse);
    });

    test('background class winning -> OUT_OF_BOUNDS_REJECT even when high',
        () {
      final result = engine.evaluate(scores: {
        'Background_Non_Leaf': 0.90,
        'Tomato___healthy': 0.06,
        'Tomato___Early_blight': 0.04,
      });
      expect(result.reliabilityState, ReliabilityState.outOfBoundsReject);
      expect(result.recommendedAction, RecommendedAction.retakePhoto);
      expect(result.isOOD, isTrue);
      expect(result.remedyKey, 'UNKNOWN_OOD');
    });

    test('top score below 0.40 -> OUT_OF_BOUNDS_REJECT', () {
      final result = engine.evaluate(scores: {
        'Tomato___Early_blight': 0.38,
        'Tomato___healthy': 0.32,
        'Background_Non_Leaf': 0.30,
      });
      expect(result.reliabilityState, ReliabilityState.outOfBoundsReject);
      expect(result.isOOD, isTrue);
    });

    test('bad frame quality demotes HIGH_CONFIDENCE to escalation', () {
      const badFrame = FrameQualityResult(
        brightness: 20,
        sharpness: 10,
        issues: ['Too dark'],
      );
      final result = engine.evaluate(
        scores: {'Tomato___Early_blight': 0.95, 'Tomato___healthy': 0.05},
        frameQuality: badFrame,
      );
      expect(result.reliabilityState, ReliabilityState.lowConfidenceEscalate);
      expect(result.recommendedAction, RecommendedAction.escalateToExpert);
    });

    test('survives JSON round-trip for passport storage', () {
      final original = engine.evaluate(
        scores: {'Tomato___healthy': 0.88, 'Background_Non_Leaf': 0.12},
        imagePath: '/tmp/leaf.jpg',
        usedMockModel: true,
      );
      final restored = DiagnosisResult.fromJson(original.toJson());
      expect(restored.className, original.className);
      expect(restored.reliabilityState, original.reliabilityState);
      expect(restored.allScores, original.allScores);
      expect(restored.usedMockModel, isTrue);
    });
  });

  group('TFLiteService mock fallback', () {
    test('falls back to mock mode and returns a valid distribution',
        () async {
      final service = TFLiteService();
      await service.load(); // Placeholder model -> mock mode.
      expect(service.isMockMode, isTrue);

      final file = File('${Directory.systemTemp.path}/fake_leaf.jpg');
      await file.writeAsBytes(List.generate(64, (i) => i));

      final result = await service.classifyImage(file.path);
      expect(result.isMock, isTrue);
      expect(result.scores.length, 3);
      final sum = result.scores.values.fold(0.0, (a, b) => a + b);
      expect(sum, closeTo(1.0, 0.001));

      // Deterministic: same file gives the same scores.
      final again = await service.classifyImage(file.path);
      expect(again.scores, result.scores);
    });

    test('mock output flows through the engine end-to-end', () async {
      final service = TFLiteService();
      final file = File('${Directory.systemTemp.path}/fake_leaf2.jpg');
      await file.writeAsBytes(List.generate(128, (i) => 255 - i % 256));

      final result =
          await engine.diagnoseFile(file.path, tflite: service);
      expect(result.usedMockModel, isTrue);
      expect(result.confidenceScore, greaterThan(0));
      expect(ReliabilityState.values, contains(result.reliabilityState));
    });
  });
}
