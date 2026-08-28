import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/models/diagnosis_result.dart';
import '../diagnosis/widgets/severity_calculator.dart';

/// Trend of a scan relative to the previous scan of the same crop.
enum ScanTrendStatus {
  improving,
  stable,
  worsening;

  String get label => switch (this) {
        ScanTrendStatus.improving => 'Improving',
        ScanTrendStatus.stable => 'Stable',
        ScanTrendStatus.worsening => 'Worsening',
      };

  String get labelHi => switch (this) {
        ScanTrendStatus.improving => 'सुधार',
        ScanTrendStatus.stable => 'स्थिर',
        ScanTrendStatus.worsening => 'बिगड़ रहा',
      };
}

/// One historical scan in the Crop Health Passport.
class PassportEntry {
  const PassportEntry({
    required this.id,
    required this.timestamp,
    required this.cropType,
    required this.diseaseName,
    required this.severityPercentage,
    required this.imagePath,
    required this.status,
  });

  final String id;
  final DateTime timestamp;

  /// e.g. "Tomato" (prefix of the model class name).
  final String cropType;

  /// Human-readable class, e.g. "Tomato Early blight".
  final String diseaseName;

  /// Lesion coverage 0–100 at scan time.
  final double severityPercentage;

  final String imagePath;
  final ScanTrendStatus status;

  Map<String, dynamic> toJson() => {
        'id': id,
        'timestamp': timestamp.toIso8601String(),
        'cropType': cropType,
        'diseaseName': diseaseName,
        'severityPercentage': severityPercentage,
        'imagePath': imagePath,
        'status': status.name,
      };

  factory PassportEntry.fromJson(Map<String, dynamic> json) => PassportEntry(
        id: json['id'] as String,
        timestamp: DateTime.parse(json['timestamp'] as String),
        cropType: json['cropType'] as String,
        diseaseName: json['diseaseName'] as String,
        severityPercentage: (json['severityPercentage'] as num).toDouble(),
        imagePath: json['imagePath'] as String? ?? '',
        status: ScanTrendStatus.values.byName(json['status'] as String),
      );
}

/// Local scan history — the farmer's offline "health record" per crop,
/// used to show recovery trends across repeat scans of the same field.
class CropHealthPassportService {
  CropHealthPassportService._();

  static final CropHealthPassportService instance =
      CropHealthPassportService._();

  static const String prefsKey = 'crop_passport_v1';

  /// Severity changes within ±this many percentage points count as Stable.
  static const double stableBandPercent = 3.0;

  /// Newest first.
  Future<List<PassportEntry>> entries() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(prefsKey) ?? const [];
    final parsed = <PassportEntry>[];
    for (final entry in raw) {
      try {
        parsed.add(
          PassportEntry.fromJson(jsonDecode(entry) as Map<String, dynamic>),
        );
      } catch (e) {
        debugPrint('CropHealthPassportService: dropped corrupt entry ($e)');
      }
    }
    parsed.sort((a, b) => b.timestamp.compareTo(a.timestamp));
    return parsed;
  }

  /// Records a completed diagnosis. The trend status compares this scan's
  /// severity against the most recent previous scan of the same crop.
  Future<PassportEntry> recordScan({
    required DiagnosisResult result,
    SeverityResult? severity,
  }) async {
    final history = await entries();
    final cropType = result.className.split('___').first;
    final severityPct = severity?.infectionPercent ?? 0;

    final previous = history.where((e) => e.cropType == cropType).firstOrNull;
    final ScanTrendStatus status;
    if (previous == null) {
      status = ScanTrendStatus.stable;
    } else {
      final diff = severityPct - previous.severityPercentage;
      status = diff <= -stableBandPercent
          ? ScanTrendStatus.improving
          : diff >= stableBandPercent
              ? ScanTrendStatus.worsening
              : ScanTrendStatus.stable;
    }

    final id =
        '${result.timestamp.millisecondsSinceEpoch}-${Random().nextInt(0xFFFF)}';
    final entry = PassportEntry(
      id: id,
      timestamp: result.timestamp,
      cropType: cropType,
      diseaseName: result.className.replaceAll('___', ' ').replaceAll('_', ' '),
      severityPercentage: severityPct,
      imagePath: await _persistImage(result.imagePath, id),
      status: status,
    );

    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(prefsKey) ?? [];
    raw.add(jsonEncode(entry.toJson()));
    await prefs.setStringList(prefsKey, raw);
    return entry;
  }

  Future<void> delete(String id) async {
    final remaining =
        (await entries()).where((e) => e.id != id).toList();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      prefsKey,
      remaining.map((e) => jsonEncode(e.toJson())).toList(),
    );
  }

  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(prefsKey, []);
  }

  /// Copies the scan image out of the camera's temp cache into app
  /// documents so timeline thumbnails survive cache cleanup. Falls back
  /// to the original path when copying is not possible.
  static Future<String> _persistImage(String? sourcePath, String id) async {
    if (sourcePath == null || sourcePath.isEmpty) return '';
    try {
      final docs = await getApplicationDocumentsDirectory();
      final dir = Directory('${docs.path}/passport_images');
      await dir.create(recursive: true);
      final ext = sourcePath.contains('.')
          ? sourcePath.substring(sourcePath.lastIndexOf('.'))
          : '.jpg';
      final copy = await File(sourcePath).copy('${dir.path}/$id$ext');
      return copy.path;
    } catch (e) {
      debugPrint('CropHealthPassportService: image copy failed ($e)');
      return sourcePath;
    }
  }
}
