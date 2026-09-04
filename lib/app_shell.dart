import 'package:flutter/material.dart';

import 'features/camera/smart_scanner_screen.dart';
import 'features/diagnosis/screens/diagnosis_result_screen.dart';
import 'features/escalation/expert_queue_screen.dart';
import 'features/passport/passport_screen.dart';
import 'widgets/common.dart';
import 'widgets/demo_panel_widget.dart';

/// Root shell: Smart Scanner, Health Passport, and Expert Queue tabs,
/// with the presenter demo panel reachable from every tab's app bar.
class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _index = 0;

  // Bumped on each visit so Passport/Queue re-read local storage and show
  // scans recorded since the last visit (they live in an IndexedStack).
  int _passportEpoch = 0;
  int _queueEpoch = 0;

  void _openDiagnosis(BuildContext context, String imagePath) {
    Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<void>(
        builder: (_) => DiagnosisResultScreen(imagePath: imagePath),
      ),
    );
  }

  Widget _demoButton({Color? color}) {
    return IconButton(
      tooltip: 'Demo presets',
      onPressed: () => DemoPanelWidget.show(context),
      icon: Icon(Icons.auto_awesome, color: color),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          // Sits above every tab: if inference is fake, say so before the
          // user takes a scan, not after they act on the result.
          const MockModelBanner(),
          Expanded(
            child: IndexedStack(
              index: _index,
              children: [
                SmartScannerScreen(
                  onImageReady: _openDiagnosis,
                  topBarTrailing: _demoButton(color: Colors.white),
                ),
                KeyedSubtree(
                  key: ValueKey('passport-$_passportEpoch'),
                  child: CropHealthPassportScreen(
                    extraActions: [_demoButton()],
                  ),
                ),
                KeyedSubtree(
                  key: ValueKey('queue-$_queueEpoch'),
                  child: ExpertQueueScreen(extraActions: [_demoButton()]),
                ),
              ],
            ),
          ),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) {
          setState(() {
            if (i == 1) _passportEpoch++;
            if (i == 2) _queueEpoch++;
            _index = i;
          });
        },
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.center_focus_strong),
            label: 'Smart Scanner',
          ),
          NavigationDestination(
            icon: Icon(Icons.menu_book),
            label: 'Health Passport',
          ),
          NavigationDestination(
            icon: Icon(Icons.support_agent),
            label: 'Expert Queue',
          ),
        ],
      ),
    );
  }
}
