import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/models/diagnosis_result.dart';

/// Offline queue of scans awaiting expert (KVK officer) review.
///
/// Inconclusive scans are queued from the diagnosis screen's
/// "Save to Expert Queue" button, and severe high-confidence scans are
/// queued automatically. Entries wait in local storage until the device
/// is back online and [syncAll] pushes them out.
class ExpertEscalationService {
  ExpertEscalationService._();

  static final ExpertEscalationService instance = ExpertEscalationService._();

  /// SharedPreferences key: JSON-encoded [DiagnosisResult] per entry.
  static const String prefsKey = 'expert_queue_v1';

  /// Observable queue size for badges and the offline status bar.
  final ValueNotifier<int> queueCount = ValueNotifier(0);

  Future<List<DiagnosisResult>> pending() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(prefsKey) ?? const [];
    final results = <DiagnosisResult>[];
    for (final entry in raw) {
      try {
        results.add(
          DiagnosisResult.fromJson(jsonDecode(entry) as Map<String, dynamic>),
        );
      } catch (e) {
        debugPrint('ExpertEscalationService: dropped corrupt entry ($e)');
      }
    }
    queueCount.value = results.length;
    return results;
  }

  /// Adds a scan to the queue; duplicates (same timestamp + image) are
  /// ignored so re-tapping the save button is safe.
  Future<void> enqueue(DiagnosisResult result) async {
    final existing = await pending();
    final duplicate = existing.any(
      (r) =>
          r.timestamp == result.timestamp && r.imagePath == result.imagePath,
    );
    if (duplicate) return;

    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(prefsKey) ?? [];
    raw.add(jsonEncode(result.toJson()));
    await prefs.setStringList(prefsKey, raw);
    queueCount.value = raw.length;
  }

  Future<void> remove(DiagnosisResult result) async {
    final existing = await pending();
    existing.removeWhere(
      (r) =>
          r.timestamp == result.timestamp && r.imagePath == result.imagePath,
    );
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      prefsKey,
      existing.map((r) => jsonEncode(r.toJson())).toList(),
    );
    queueCount.value = existing.length;
  }

  /// Cheap reachability probe (DNS lookup with a short timeout). No
  /// packets beyond DNS — the core app stays fully offline.
  Future<bool> hasConnectivity() async {
    try {
      final result = await InternetAddress.lookup('one.one.one.one')
          .timeout(const Duration(seconds: 2));
      return result.isNotEmpty && result.first.rawAddress.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  /// Uploads and drains the queue, returning how many scans were sent.
  ///
  /// Prototype: the upload to the KVK portal is simulated with a short
  /// delay per scan; the queue is only cleared after "upload" completes.
  Future<int> syncAll() async {
    final entries = await pending();
    if (entries.isEmpty) return 0;
    for (final _ in entries) {
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(prefsKey, []);
    queueCount.value = 0;
    return entries.length;
  }
}
