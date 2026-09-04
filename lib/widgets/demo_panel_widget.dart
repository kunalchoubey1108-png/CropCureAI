import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../core/constants/app_colors.dart';
import '../features/diagnosis/screens/diagnosis_result_screen.dart';

/// Hidden presenter panel: loads three sample scans so the stage demo can
/// showcase every reliability state on cue, regardless of venue lighting.
///
/// These presets run the **real pipeline** — quality check, on-device
/// model, severity analysis. Nothing is precomputed and no probabilities
/// are hardcoded, so what a judge sees is genuinely the model's output.
///
/// The images are held-out PlantVillage / Imagenette frames the model was
/// never trained on. `ml/make_demo_assets.py` selects them and asserts each
/// one lands in the state claimed below before writing it into assets/.
class DemoPanelWidget extends StatelessWidget {
  const DemoPanelWidget({super.key});

  static Future<void> show(BuildContext context) {
    return showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (_) => const DemoPanelWidget(),
    );
  }

  static const List<DemoPreset> presets = [
    DemoPreset(
      letter: 'A',
      asset: 'assets/demo/preset_a_object.jpg',
      icon: Icons.delete_outline,
      color: AppColors.severityUnknown,
      title: 'Non-Leaf Object',
      subtitle: 'Model scores it Background — "No Valid Leaf Detected"',
    ),
    DemoPreset(
      letter: 'B',
      asset: 'assets/demo/preset_b_blurry_leaf.jpg',
      icon: Icons.blur_on,
      color: AppColors.severityModerate,
      title: 'Blurry Leaf',
      subtitle:
          'Model is confident, but the blur check demotes it — '
          'inconclusive, routed to an expert',
    ),
    DemoPreset(
      letter: 'C',
      asset: 'assets/demo/preset_c_blight_leaf.jpg',
      icon: Icons.coronavirus,
      color: AppColors.severitySevere,
      title: 'Tomato Early Blight',
      subtitle: 'Full diagnosis · severity · heatmap · tap 🔊 for Hindi voice',
    ),
  ];

  /// Copies a bundled demo image to a real file, since the whole pipeline
  /// (decode, quality check, inference) works from a path on disk.
  static Future<String> materialize(String asset) async {
    final bytes = await rootBundle.load(asset);
    Directory dir;
    try {
      dir = await getTemporaryDirectory();
    } catch (_) {
      dir = Directory.systemTemp; // Tests / platforms without the plugin.
    }
    final file = File('${dir.path}/${asset.split('/').last}');
    await file.writeAsBytes(bytes.buffer.asUint8List(), flush: true);
    return file.path;
  }

  Future<void> _launch(BuildContext context, DemoPreset preset) async {
    final navigator = Navigator.of(context, rootNavigator: true);
    navigator.pop(); // Close the sheet.
    final path = await materialize(preset.asset);
    navigator.push(
      MaterialPageRoute<void>(
        builder: (_) => DiagnosisResultScreen(imagePath: path),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.auto_awesome, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Text(
                  'Demo Mode — Presenter Panel',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Held-out sample scans. Each one runs the real model — '
              'no network, nothing precomputed.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
            const SizedBox(height: 12),
            for (final preset in presets)
              _PresetTile(
                preset: preset,
                onTap: () => _launch(context, preset),
              ),
          ],
        ),
      ),
    );
  }
}

/// One presenter-panel entry: a bundled image plus how to label it.
class DemoPreset {
  const DemoPreset({
    required this.letter,
    required this.asset,
    required this.icon,
    required this.color,
    required this.title,
    required this.subtitle,
  });

  final String letter;
  final String asset;
  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;
}

class _PresetTile extends StatelessWidget {
  const _PresetTile({required this.preset, required this.onTap});

  final DemoPreset preset;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        onTap: onTap,
        leading: CircleAvatar(
          backgroundColor: preset.color.withValues(alpha: 0.15),
          child: Text(
            preset.letter,
            style: TextStyle(fontWeight: FontWeight.w800, color: preset.color),
          ),
        ),
        title: Text(
          preset.title,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: Text(preset.subtitle),
        trailing: Icon(preset.icon, color: preset.color),
      ),
    );
  }
}
