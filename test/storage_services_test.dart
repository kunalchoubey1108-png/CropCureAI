import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:cropcure_ai/core/models/diagnosis_result.dart';
import 'package:cropcure_ai/core/services/ai_reliability_engine.dart';
import 'package:cropcure_ai/features/diagnosis/widgets/severity_calculator.dart';
import 'package:cropcure_ai/features/escalation/escalation_service.dart';
import 'package:cropcure_ai/features/escalation/expert_queue_screen.dart';
import 'package:cropcure_ai/features/passport/passport_screen.dart';
import 'package:cropcure_ai/features/passport/passport_service.dart';

const engine = AIReliabilityEngine();

DiagnosisResult _blightResult({double confidence = 0.85}) =>
    engine.evaluate(scores: {
      'Tomato___Early_blight': confidence,
      'Tomato___healthy': (1 - confidence) / 2,
      'Background_Non_Leaf': (1 - confidence) / 2,
    });

SeverityResult _severity(double percent) => SeverityResult(
      infectionPercent: percent,
      category: SeverityCalculator.categorize(percent),
      leafCoverage: 0.8,
      lesionGrid: const [],
      isReliable: true,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('CropHealthPassportService', () {
    final service = CropHealthPassportService.instance;

    test('trend status: first Stable, drop Improving, rise Worsening',
        () async {
      final e1 = await service.recordScan(
        result: _blightResult(),
        severity: _severity(28),
      );
      expect(e1.status, ScanTrendStatus.stable);
      expect(e1.cropType, 'Tomato');
      expect(e1.diseaseName, 'Tomato Early blight');
      expect(e1.severityPercentage, 28);

      final e2 = await service.recordScan(
        result: _blightResult(),
        severity: _severity(12),
      );
      expect(e2.status, ScanTrendStatus.improving);

      final e3 = await service.recordScan(
        result: _blightResult(),
        severity: _severity(35),
      );
      expect(e3.status, ScanTrendStatus.worsening);

      // Small change stays Stable (±3% band).
      final e4 = await service.recordScan(
        result: _blightResult(),
        severity: _severity(36),
      );
      expect(e4.status, ScanTrendStatus.stable);
    });

    test('entries persist newest-first and delete works', () async {
      await service.recordScan(
          result: _blightResult(), severity: _severity(28));
      await service.recordScan(
          result: _blightResult(), severity: _severity(12));

      final entries = await service.entries();
      expect(entries.length, 2);
      expect(
        entries.first.timestamp.isAfter(entries.last.timestamp) ||
            entries.first.timestamp == entries.last.timestamp,
        isTrue,
      );

      await service.delete(entries.first.id);
      expect((await service.entries()).length, 1);
    });
  });

  group('ExpertEscalationService', () {
    final service = ExpertEscalationService.instance;

    test('enqueue, dedupe, remove, and sync drain the queue', () async {
      final a = _blightResult(confidence: 0.55);
      final b = _blightResult(confidence: 0.60);

      await service.enqueue(a);
      await service.enqueue(a); // duplicate ignored
      await service.enqueue(b);
      expect((await service.pending()).length, 2);
      expect(service.queueCount.value, 2);

      await service.remove(a);
      expect((await service.pending()).length, 1);

      final synced = await service.syncAll();
      expect(synced, 1);
      expect((await service.pending()), isEmpty);
      expect(service.queueCount.value, 0);
    });
  });

  group('Screens', () {
    testWidgets('ExpertQueueScreen shows offline bar with queue count',
        (tester) async {
      final service = ExpertEscalationService.instance;
      await service.enqueue(_blightResult(confidence: 0.55));
      await service.enqueue(_blightResult(confidence: 0.62));

      await tester.pumpWidget(
        MaterialApp(
          home: ExpertQueueScreen(connectivityProbe: () async => false),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(
        find.text(
          'Core App 100% Offline | 2 Scans Queued for Expert Review when '
          'Online',
        ),
        findsOneWidget,
      );
      expect(find.text('Waiting for network to sync...'), findsOneWidget);
      expect(find.textContaining('Inconclusive'), findsNWidgets(2));
    });

    testWidgets('ExpertQueueScreen online -> sync enabled', (tester) async {
      await ExpertEscalationService.instance
          .enqueue(_blightResult(confidence: 0.55));

      await tester.pumpWidget(
        MaterialApp(
          home: ExpertQueueScreen(connectivityProbe: () async => true),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(find.textContaining('Ready to Sync to KVK'), findsOneWidget);
      expect(find.text('Sync 1 Scan Now'), findsOneWidget);
    });

    testWidgets('PassportScreen shows timeline and recovery trend',
        (tester) async {
      tester.view.physicalSize = const Size(800, 1800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final service = CropHealthPassportService.instance;
      await service.recordScan(
          result: _blightResult(), severity: _severity(28));
      await service.recordScan(
          result: _blightResult(), severity: _severity(12));

      await tester.pumpWidget(
        const MaterialApp(home: CropHealthPassportScreen()),
      );
      await tester.pump();
      await tester.pump();

      expect(find.text('Tomato Recovery Trend'), findsOneWidget);
      expect(find.textContaining('28% severity'), findsOneWidget);
      expect(find.textContaining('12% severity'), findsOneWidget);
      expect(find.text('Scan Timeline'), findsOneWidget);
      expect(find.text('Tomato Early blight'), findsNWidgets(2));
      expect(find.text('Improving'), findsOneWidget);
      expect(find.text('Stable'), findsOneWidget);
    });
  });
}
