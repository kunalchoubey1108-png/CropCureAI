import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:cropcure_ai/core/models/diagnosis_result.dart';
import 'package:cropcure_ai/core/services/ai_reliability_engine.dart';
import 'package:cropcure_ai/core/utils/image_checker.dart';
import 'package:cropcure_ai/widgets/demo_panel_widget.dart';

/// The presets no longer hand precomputed verdicts to the results screen —
/// they hand it an image and let the real pipeline decide. So these tests
/// check the two things that are still ours to guarantee:
///
///   1. every bundled asset exists and lands on disk, and
///   2. each asset has the image-quality property its preset depends on
///      (B must fail the blur gate, A and C must pass it).
///
/// The model half is verified in `ml/make_demo_assets.py`, which refuses to
/// write an asset that does not produce the claimed class. It cannot be
/// asserted here because flutter_test has no TFLite native library.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'every preset asset is bundled and materializes to a real file',
    () async {
      expect(DemoPanelWidget.presets, hasLength(3));
      for (final preset in DemoPanelWidget.presets) {
        final path = await DemoPanelWidget.materialize(preset.asset);
        final file = File(path);
        expect(file.existsSync(), isTrue, reason: '${preset.asset} missing');
        expect(await file.length(), greaterThan(1000));
      }
    },
  );

  test('Preset B is blurry enough that the quality gate must fire', () async {
    final path = await DemoPanelWidget.materialize(
      'assets/demo/preset_b_blurry_leaf.jpg',
    );
    final quality = await File(path).validateForInference();

    expect(quality.isUsable, isFalse);
    expect(quality.sharpness, lessThan(ImageChecker.minSharpness));

    // That alone is what demotes a confident prediction to "inconclusive",
    // which is the entire point of the preset.
    const engine = AIReliabilityEngine();
    final demoted = engine.evaluate(
      scores: const {
        'Tomato___Early_blight': 0.99,
        'Tomato___healthy': 0.005,
        'Background_Non_Leaf': 0.005,
      },
      frameQuality: quality,
    );
    expect(demoted.reliabilityState, ReliabilityState.lowConfidenceEscalate);
    expect(demoted.recommendedAction, RecommendedAction.escalateToExpert);
  });

  test('Presets A and C pass the quality gate', () async {
    for (final asset in const [
      'assets/demo/preset_a_object.jpg',
      'assets/demo/preset_c_blight_leaf.jpg',
    ]) {
      final path = await DemoPanelWidget.materialize(asset);
      final quality = await File(path).validateForInference();
      expect(
        quality.isUsable,
        isTrue,
        reason: '$asset was flagged: ${quality.issues}',
      );
    }
  });
}
