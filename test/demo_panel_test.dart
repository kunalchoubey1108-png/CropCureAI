import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:cropcure_ai/core/models/diagnosis_result.dart';
import 'package:cropcure_ai/features/diagnosis/widgets/severity_calculator.dart';
import 'package:cropcure_ai/widgets/demo_panel_widget.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Preset A (water bottle) triggers OOD rejection', () async {
    final (path, output) = await DemoPanelWidget.buildGarbagePreset();
    expect(File(path).existsSync(), isTrue);
    expect(output.result.reliabilityState, ReliabilityState.outOfBoundsReject);
    expect(output.result.recommendedAction, RecommendedAction.retakePhoto);
    expect(output.result.isOOD, isTrue);
  });

  test('Preset B (blurry) triggers expert escalation', () async {
    final (path, output) = await DemoPanelWidget.buildBlurryPreset();
    expect(File(path).existsSync(), isTrue);
    expect(
      output.result.reliabilityState,
      ReliabilityState.lowConfidenceEscalate,
    );
    expect(
      output.result.recommendedAction,
      RecommendedAction.escalateToExpert,
    );
    expect(output.frameQuality!.isUsable, isFalse);
  });

  test('Preset C (early blight) is a perfect moderate diagnosis', () async {
    final (path, output) = await DemoPanelWidget.buildBlightPreset();
    expect(File(path).existsSync(), isTrue);
    expect(output.result.reliabilityState, ReliabilityState.highConfidence);
    expect(output.result.recommendedAction, RecommendedAction.showRemedy);
    expect(output.result.className, 'Tomato___Early_blight');

    // The drawn lesions must genuinely measure as Moderate (~18%).
    final severity = output.severity!;
    expect(severity.category, SeverityCategory.moderate);
    expect(severity.infectionPercent, closeTo(18, 5));
    expect(severity.isReliable, isTrue);

    // Remedies loaded for the results screen and Hindi TTS.
    expect(output.remedy, isNotNull);
    expect(output.remedy!.speechText('hi'), contains('जैविक उपचार'));
  });
}
