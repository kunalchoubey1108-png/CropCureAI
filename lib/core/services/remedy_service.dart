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

  String get severity => data['severity'] as String? ?? 'unknown';

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
      final chemical = list('chemical_treatment', lang);
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
