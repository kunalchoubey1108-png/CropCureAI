import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';

import '../core/constants/app_colors.dart';
import '../core/services/ai_reliability_engine.dart';
import '../core/services/remedy_service.dart';
import '../core/utils/image_checker.dart';
import '../features/diagnosis/screens/diagnosis_result_screen.dart';
import '../features/diagnosis/widgets/severity_calculator.dart';

/// Hidden presenter panel: loads deterministic sample scenarios so the
/// stage demo can showcase every reliability state on cue, regardless of
/// venue lighting or mock-inference randomness.
///
/// Each preset synthesizes its sample image locally and hands the results
/// screen a precomputed pipeline output — fully offline, fully repeatable.
class DemoPanelWidget extends StatelessWidget {
  const DemoPanelWidget({super.key});

  static const _engine = AIReliabilityEngine();

  static Future<void> show(BuildContext context) {
    return showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (_) => const DemoPanelWidget(),
    );
  }

  // ---------------------------------------------------------------- presets

  /// Preset A: garbage / water bottle — OOD rejection.
  static Future<(String, DiagnosisPipelineOutput)> buildGarbagePreset() async {
    final path = await _writeDemoImage('demo_a_bottle.jpg', _drawBottle());
    final result = _engine.evaluate(
      scores: {
        'Background_Non_Leaf': 0.86,
        'Tomato___Early_blight': 0.08,
        'Tomato___healthy': 0.06,
      },
      imagePath: path,
    );
    return (path, DiagnosisPipelineOutput(result: result));
  }

  /// Preset B: blurry / unknown disease — expert escalation.
  static Future<(String, DiagnosisPipelineOutput)> buildBlurryPreset() async {
    final path = await _writeDemoImage('demo_b_blurry.jpg', _drawBlurryLeaf());
    const quality = FrameQualityResult(
      brightness: 96,
      sharpness: 18,
      issues: ['Image looks blurry — hold the phone steady and refocus.'],
    );
    final result = _engine.evaluate(
      scores: {
        'Tomato___Early_blight': 0.52,
        'Tomato___healthy': 0.33,
        'Background_Non_Leaf': 0.15,
      },
      frameQuality: quality,
      imagePath: path,
    );
    return (
      path,
      DiagnosisPipelineOutput(result: result, frameQuality: quality),
    );
  }

  /// Preset C: tomato early blight — perfect diagnosis with ~18% severity,
  /// real heatmap (computed from the drawn lesions), and Hindi TTS ready.
  static Future<(String, DiagnosisPipelineOutput)> buildBlightPreset() async {
    final leaf = _drawBlightLeaf();
    final path = await _writeDemoImage('demo_c_blight.jpg', leaf);

    // Genuine severity analysis of the synthetic leaf, so the heatmap and
    // percentage line up with what is visible in the image.
    final severity = SeverityCalculator.analyze(leaf);
    const quality =
        FrameQualityResult(brightness: 128, sharpness: 320, issues: []);
    final result = _engine.evaluate(
      scores: {
        'Tomato___Early_blight': 0.91,
        'Tomato___healthy': 0.06,
        'Background_Non_Leaf': 0.03,
      },
      frameQuality: quality,
      imagePath: path,
    );

    Remedy? remedy;
    try {
      await RemedyService.instance.load();
      remedy = RemedyService.instance.forKey(result.remedyKey);
    } catch (_) {
      remedy = null;
    }

    return (
      path,
      DiagnosisPipelineOutput(
        result: result,
        severity: severity,
        frameQuality: quality,
        remedy: remedy,
      ),
    );
  }

  // --------------------------------------------------------- image drawing

  /// Blue water bottle on a gray table.
  static img.Image _drawBottle() {
    final canvas = img.Image(width: 256, height: 256);
    img.fill(canvas, color: img.ColorRgb8(150, 150, 155));
    // Body, cap, label.
    img.fillRect(canvas,
        x1: 96, y1: 70, x2: 160, y2: 214, color: img.ColorRgb8(25, 90, 190));
    img.fillRect(canvas,
        x1: 114, y1: 40, x2: 142, y2: 70, color: img.ColorRgb8(230, 230, 235));
    img.fillRect(canvas,
        x1: 104, y1: 120, x2: 152, y2: 172,
        color: img.ColorRgb8(240, 240, 240));
    return canvas;
  }

  /// Out-of-focus greenish frame.
  static img.Image _drawBlurryLeaf() {
    final canvas = img.Image(width: 256, height: 256);
    img.fill(canvas, color: img.ColorRgb8(52, 70, 45));
    img.fillCircle(canvas,
        x: 120, y: 130, radius: 85, color: img.ColorRgb8(80, 150, 75));
    img.fillCircle(canvas,
        x: 150, y: 100, radius: 30, color: img.ColorRgb8(115, 120, 55));
    return img.gaussianBlur(canvas, radius: 9);
  }

  /// Green leaf with brown ringed lesions covering roughly 18% of it.
  static img.Image _drawBlightLeaf() {
    final canvas = img.Image(width: 256, height: 256);
    img.fill(canvas, color: img.ColorRgb8(170, 170, 170));
    img.fillCircle(canvas,
        x: 128, y: 128, radius: 110, color: img.ColorRgb8(60, 145, 65));

    void lesion(int x, int y, int r) {
      img.fillCircle(canvas,
          x: x, y: y, radius: r, color: img.ColorRgb8(120, 75, 25));
      img.drawCircle(canvas,
          x: x, y: y, radius: r + 3, color: img.ColorRgb8(90, 55, 15));
      img.drawCircle(canvas,
          x: x, y: y, radius: r + 6, color: img.ColorRgb8(190, 170, 60));
    }

    lesion(100, 100, 27);
    lesion(162, 142, 27);
    lesion(118, 172, 25);
    return canvas;
  }

  static Future<String> _writeDemoImage(String name, img.Image image) async {
    Directory dir;
    try {
      dir = await getTemporaryDirectory();
    } catch (_) {
      dir = Directory.systemTemp; // Tests / platforms without the plugin.
    }
    final file = File('${dir.path}/$name');
    await file.writeAsBytes(img.encodeJpg(image, quality: 92));
    return file.path;
  }

  // ------------------------------------------------------------------- UI

  Future<void> _launch(
    BuildContext context,
    Future<(String, DiagnosisPipelineOutput)> Function() builder,
  ) async {
    final navigator = Navigator.of(context, rootNavigator: true);
    navigator.pop(); // Close the sheet.
    final (path, output) = await builder();
    navigator.push(
      MaterialPageRoute<void>(
        builder: (_) =>
            DiagnosisResultScreen(imagePath: path, precomputed: output),
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
              'Loads offline sample scenarios. No network involved.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
            const SizedBox(height: 12),
            _PresetTile(
              letter: 'A',
              color: AppColors.severityUnknown,
              icon: Icons.delete_outline,
              title: 'Garbage / Water Bottle Scan',
              subtitle: 'Triggers OOD rejection — "No Valid Leaf Detected"',
              onTap: () => _launch(context, buildGarbagePreset),
            ),
            _PresetTile(
              letter: 'B',
              color: AppColors.severityModerate,
              icon: Icons.blur_on,
              title: 'Blurry / Unknown Disease',
              subtitle: 'Triggers expert escalation — inconclusive scan',
              onTap: () => _launch(context, buildBlurryPreset),
            ),
            _PresetTile(
              letter: 'C',
              color: AppColors.severitySevere,
              icon: Icons.coronavirus,
              title: 'Tomato Early Blight',
              subtitle: 'Perfect diagnosis · ~18% severity · heatmap · '
                  'tap 🔊 for Hindi voice',
              onTap: () => _launch(context, buildBlightPreset),
            ),
          ],
        ),
      ),
    );
  }
}

class _PresetTile extends StatelessWidget {
  const _PresetTile({
    required this.letter,
    required this.color,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final String letter;
  final Color color;
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        onTap: onTap,
        leading: CircleAvatar(
          backgroundColor: color.withValues(alpha: 0.15),
          child: Text(
            letter,
            style: TextStyle(fontWeight: FontWeight.w800, color: color),
          ),
        ),
        title: Text(
          title,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: Text(subtitle),
        trailing: Icon(icon, color: color),
      ),
    );
  }
}
