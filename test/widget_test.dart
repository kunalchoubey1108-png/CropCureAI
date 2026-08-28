import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:cropcure_ai/main.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('shell renders all three tabs and navigates between them',
      (tester) async {
    await tester.pumpWidget(const CropCureApp());
    await tester.pump();

    // Bottom navigation destinations.
    expect(find.text('Smart Scanner'), findsWidgets);
    expect(find.text('Health Passport'), findsOneWidget);
    expect(find.text('Expert Queue'), findsOneWidget);

    // Scanner tab: no camera in the test environment, so after the
    // discovery timeout the gallery fallback must appear, not a crash.
    await tester.pump(const Duration(seconds: 6));
    expect(find.text('Pick from gallery'), findsOneWidget);

    // Passport tab.
    await tester.tap(find.text('Health Passport'));
    await tester.pump();
    await tester.pump();
    expect(find.text('Crop Health Passport'), findsOneWidget);
    expect(find.text('No scans yet'), findsOneWidget);

    // Expert queue tab.
    await tester.tap(find.text('Expert Queue'));
    await tester.pump();
    await tester.pump();
    expect(find.text('Expert Review Queue'), findsOneWidget);
    expect(find.textContaining('Core App 100% Offline'), findsOneWidget);

    // Let the queue screen's 2s connectivity-probe timeout elapse so no
    // timer is pending at teardown.
    await tester.pump(const Duration(seconds: 3));
  });
}
