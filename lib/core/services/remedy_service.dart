import 'dart:convert';

import 'package:flutter/services.dart';

/// Loads and serves the localized remedy knowledge base bundled at
/// `assets/data/remedies.json`. Fully offline.
class RemedyService {
  RemedyService._();

  static final RemedyService instance = RemedyService._();

  static const String remediesAsset = 'assets/data/remedies.json';

  Map<String, dynamic>? _classes;

  Future<void> load() async {
    if (_classes != null) return;
    final raw = await rootBundle.loadString(remediesAsset);
    final decoded = jsonDecode(raw) as Map<String, dynamic>;
    _classes = decoded['classes'] as Map<String, dynamic>;
  }

  /// [remedyKey] is a `DiagnosisResult.remedyKey` (e.g. TOMATO_EARLY_BLIGHT).
  Remedy? forKey(String remedyKey) {
    final data = _classes?[remedyKey];
    if (data == null) return null;
    return Remedy(remedyKey, data as Map<String, dynamic>);
  }
}

/// One remedy entry with language-aware accessors ('en' / 'hi').
class Remedy {
  const Remedy(this.key, this.data);

  final String key;
  final Map<String, dynamic> data;

  String get type => data['type'] as String? ?? 'unknown';

  /// Localized string field, falling back to English.
  String text(String field, String lang) {
    final entry = data[field];
    if (entry is! Map) return '';
    return (entry[lang] ?? entry['en'] ?? '') as String;
  }

  /// Localized list field, falling back to English.
  List<String> list(String field, String lang) {
    final entry = data[field];
    if (entry is! Map) return const [];
    final value = entry[lang] ?? entry['en'];
    if (value is! List) return const [];
    return value.cast<String>();
  }

  String displayName(String lang) => text('display_name', lang);

  /// Shown in place of chemical steps nobody has checked yet.
  static const Map<String, String> unreviewedChemicalNotice = {
    'en':
        'Chemical spray advice for this problem has not yet been checked by '
        'an agricultural expert. Before buying or spraying any chemical, ask '
        'your local Krishi Vigyan Kendra (KVK) or call the Kisan Call Centre '
        'at 1800-180-1551.',
    'hi':
        'इस समस्या के लिए रासायनिक छिड़काव की सलाह अभी किसी कृषि विशेषज्ञ '
        'द्वारा जांची नहीं गई है। कोई भी रसायन ख़रीदने या छिड़कने से पहले अपने '
        'नज़दीकी कृषि विज्ञान केंद्र (KVK) से पूछें या किसान कॉल सेंटर '
        '1800-180-1551 पर कॉल करें।',
  };

  /// Fail-safe: only an explicit `"chemical_reviewed": true` counts. A wrong
  /// pesticide dose read out in Hindi is real-world harm, so a missing flag
  /// must hide the advice, not show it.
  bool get chemicalReviewed => data['chemical_reviewed'] == true;

  /// Chemical steps if reviewed, otherwise a single KVK pointer.
  List<String> chemicalSteps(String lang) {
    final steps = list('chemical_treatment', lang);
    if (steps.isEmpty || chemicalReviewed) return steps;
    return [unreviewedChemicalNotice[lang] ?? unreviewedChemicalNotice['en']!];
  }

  /// Flat narration of the remedy for the voice assistant.
  String speechText(String lang) {
    final hi = lang == 'hi';
    final parts = <String>[displayName(lang)];

    if (type == 'disease') {
      final organic = list('organic_treatment', lang);
      if (organic.isNotEmpty) {
        parts
          ..add(hi ? 'जैविक उपचार:' : 'Organic treatment:')
          ..addAll(organic);
      }
      final chemical = chemicalSteps(lang);
      if (chemical.isNotEmpty) {
        parts
          ..add(hi ? 'रासायनिक उपचार:' : 'Chemical treatment:')
          ..addAll(chemical);
      }
    } else {
      parts.addAll(list('advice', lang));
    }

    final escalation = text('escalation_advice', lang);
    if (escalation.isNotEmpty) parts.add(escalation);
    return parts.join(' ');
  }
}
