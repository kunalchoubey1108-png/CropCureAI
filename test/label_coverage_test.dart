import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cropcure_ai/core/models/diagnosis_result.dart';
import 'package:cropcure_ai/core/services/remedy_service.dart';
import 'package:cropcure_ai/core/services/tflite_service.dart';

/// Every label the model can emit must reach a real remedy. Before this
/// test, an unmapped label silently fell back to the "not a leaf" advisory —
/// a farmer with a diseased plant would have been told to retake the photo.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<String> bundledLabels;

  setUpAll(() async {
    await RemedyService.instance.load();
    bundledLabels = (await rootBundle.loadString(TFLiteService.labelsAsset))
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
  });

  test('labels.txt matches TFLiteService.defaultLabels in order', () {
    expect(bundledLabels, TFLiteService.defaultLabels);
  });

  test('every model label maps to a remedy key that resolves', () {
    for (final label in bundledLabels) {
      final key = DiagnosisResult.classToRemedyKey[label];
      expect(key, isNotNull, reason: '$label has no remedy key');
      expect(
        RemedyService.instance.forKey(key!),
        isNotNull,
        reason: '$label -> $key is missing from remedies.json',
      );
    }
  });

  test('only the background label maps to the OOD advisory', () {
    final ood = DiagnosisResult.classToRemedyKey.entries
        .where((e) => e.value == 'UNKNOWN_OOD')
        .map((e) => e.key);
    expect(ood, ['Background_Non_Leaf']);
  });

  test('every disease is bilingual and states its chemical review status', () {
    for (final key in DiagnosisResult.classToRemedyKey.values) {
      final remedy = RemedyService.instance.forKey(key)!;
      for (final lang in ['en', 'hi']) {
        expect(remedy.displayName(lang), isNotEmpty, reason: '$key/$lang');
      }
      if (remedy.type != 'disease') continue;
      for (final lang in ['en', 'hi']) {
        expect(remedy.text('symptoms', lang), isNotEmpty, reason: '$key/$lang');
        expect(
          remedy.list('organic_treatment', lang),
          isNotEmpty,
          reason: '$key/$lang',
        );
      }
      expect(
        remedy.data['chemical_reviewed'],
        isA<bool>(),
        reason: '$key must say explicitly whether its chemical advice was '
            'reviewed',
      );
    }
  });

  test('unreviewed chemical advice is replaced by the KVK pointer', () {
    final remedy = RemedyService.instance.forKey('TOMATO_LATE_BLIGHT')!;
    expect(remedy.chemicalReviewed, isFalse);
    expect(remedy.chemicalSteps('hi'), [
      Remedy.unreviewedChemicalNotice['hi'],
    ]);

    final speech = remedy.speechText('en');
    expect(speech, contains('1800-180-1551'));
    expect(speech, isNot(contains('Metalaxyl')));
  });

  test('a missing review flag hides chemical advice', () {
    const remedy = Remedy('X', {
      'type': 'disease',
      'chemical_treatment': {
        'en': ['Spray something'],
      },
    });
    expect(remedy.chemicalReviewed, isFalse);
    expect(remedy.chemicalSteps('en'), isNot(contains('Spray something')));
  });
}
