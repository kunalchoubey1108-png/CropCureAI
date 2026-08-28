import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:cropcure_ai/core/services/ai_reliability_engine.dart';
import 'package:cropcure_ai/core/services/remedy_service.dart';
import 'package:cropcure_ai/features/diagnosis/screens/diagnosis_result_screen.dart';
import 'package:cropcure_ai/features/diagnosis/widgets/severity_calculator.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const engine = AIReliabilityEngine();

  late String leafImagePath;

  setUpAll(() async {
    // Real (synthetic) leaf photo on disk for Image.file / analysis.
    final image = img.Image(width: 64, height: 64);
    img.fill(image, color: img.ColorRgb8(60, 140, 60));
    final file = File('${Directory.systemTemp.path}/result_leaf.png');
    await file.writeAsBytes(img.encodePng(image));
    leafImagePath = file.path;
  });

  group('RemedyService', () {
    test('loads remedies.json and localizes both languages', () async {
      await RemedyService.instance.load();

      final blight = RemedyService.instance.forKey('TOMATO_EARLY_BLIGHT');
      expect(blight, isNotNull);
      expect(blight!.type, 'disease');
      expect(blight.displayName('en'), contains('Early Blight'));
      expect(blight.displayName('hi'), contains('टमाटर'));
      expect(blight.list('organic_treatment', 'en'), isNotEmpty);
      expect(blight.list('chemical_treatment', 'hi'), isNotEmpty);

      final healthy = RemedyService.instance.forKey('TOMATO_HEALTHY');
      expect(healthy!.list('advice', 'hi'), isNotEmpty);

      expect(RemedyService.instance.forKey('UNKNOWN_OOD'), isNotNull);
      expect(RemedyService.instance.forKey('NOPE'), isNull);
    });

    test('speechText narrates treatments in the chosen language', () async {
      await RemedyService.instance.load();
      final blight = RemedyService.instance.forKey('TOMATO_EARLY_BLIGHT')!;

      final en = blight.speechText('en');
      expect(en, contains('Organic treatment:'));
      expect(en, contains('Chemical treatment:'));

      final hi = blight.speechText('hi');
      expect(hi, contains('जैविक उपचार:'));
      expect(hi, contains('नीम'));
    });
  });

  group('DiagnosisResultScreen states', () {
    Future<void> pumpScreen(
      WidgetTester tester,
      DiagnosisPipelineOutput output,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: DiagnosisResultScreen(
            imagePath: leafImagePath,
            precomputed: output,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
    }

    testWidgets('OOD -> red rejection card', (tester) async {
      final result = engine.evaluate(scores: {
        'Background_Non_Leaf': 0.9,
        'Tomato___healthy': 0.1,
      });
      await pumpScreen(tester, DiagnosisPipelineOutput(result: result));
      expect(find.text('No Valid Leaf Detected'), findsOneWidget);
      expect(find.text('Scan Again'), findsOneWidget);
    });

    testWidgets('low confidence -> escalation card with queue button',
        (tester) async {
      final result = engine.evaluate(scores: {
        'Tomato___Early_blight': 0.55,
        'Tomato___healthy': 0.45,
      });
      await pumpScreen(tester, DiagnosisPipelineOutput(result: result));
      expect(find.text('Inconclusive Scan'), findsOneWidget);
      expect(find.text('Save to Expert Queue'), findsOneWidget);
    });

    testWidgets('high confidence -> remedy view with severity and heatmap',
        (tester) async {
      // Tall phone viewport so content below the heatmap gets built.
      tester.view.physicalSize = const Size(800, 2200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await RemedyService.instance.load();
      final result = engine.evaluate(scores: {
        'Tomato___Early_blight': 0.88,
        'Tomato___healthy': 0.12,
      });
      // Severity from a leaf that is ~20% lesion.
      final leaf = img.Image(width: 100, height: 100);
      for (var y = 0; y < 100; y++) {
        for (var x = 0; x < 100; x++) {
          leaf.setPixelRgb(x, y, x < 20 ? 139 : 60, x < 20 ? 90 : 140,
              x < 20 ? 30 : 60);
        }
      }
      final severity = SeverityCalculator.analyze(leaf);

      await pumpScreen(
        tester,
        DiagnosisPipelineOutput(
          result: result,
          severity: severity,
          remedy: RemedyService.instance.forKey(result.remedyKey),
        ),
      );

      // Hindi is the default language.
      expect(find.textContaining('अगेती झुलसा'), findsOneWidget);
      expect(find.text('Show AI Focus (Grad-CAM)'), findsOneWidget);
      expect(find.text('Why This Diagnosis?'), findsOneWidget);
      expect(find.textContaining('मध्यम'), findsOneWidget); // Moderate chip
      expect(find.byIcon(Icons.volume_up), findsOneWidget); // speaker FAB
      await tester.scrollUntilVisible(
        find.textContaining('जैविक उपचार'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.textContaining('जैविक उपचार'), findsOneWidget);

      // Language toggle switches remedy text to English.
      await tester.tap(find.text('EN'));
      await tester.pump();
      expect(find.textContaining('Organic Treatment'), findsOneWidget);
    });
  });
}
