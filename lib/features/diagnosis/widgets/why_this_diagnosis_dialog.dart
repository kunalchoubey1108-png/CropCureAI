import 'package:flutter/material.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/models/diagnosis_result.dart';
import '../../../core/utils/image_checker.dart';
import 'severity_calculator.dart';

/// Explainability dialog: breaks a diagnosis down into what the AI saw,
/// how confident it is versus how clear the photo was, and why this
/// specific pathogen matched.
class WhyThisDiagnosisDialog extends StatelessWidget {
  const WhyThisDiagnosisDialog({
    super.key,
    required this.result,
    required this.severity,
    this.frameQuality,
  });

  final DiagnosisResult result;
  final SeverityResult severity;
  final FrameQualityResult? frameQuality;

  static Future<void> show(
    BuildContext context, {
    required DiagnosisResult result,
    required SeverityResult severity,
    FrameQualityResult? frameQuality,
  }) {
    return showDialog<void>(
      context: context,
      builder: (_) => WhyThisDiagnosisDialog(
        result: result,
        severity: severity,
        frameQuality: frameQuality,
      ),
    );
  }

  /// Pathogen-specific rationale, keyed by raw model label.
  static const Map<String, String> _pathogenRationale = {
    'Tomato___Early_blight':
        'Dark brown spots with concentric rings (a "target board" pattern) '
        'surrounded by yellow halos are the classic signature of the fungus '
        'Alternaria solani. The model matched the lesion shape, the ring '
        'texture, and the yellow-to-brown transition zones typical of early '
        'blight on older, lower leaves.',
    'Tomato___healthy':
        'The leaf surface shows uniform green tissue with no chlorotic '
        '(yellowing) patches, necrotic spots, or ring patterns. The model '
        'found none of the lesion textures it associates with tomato '
        'diseases.',
    'Background_Non_Leaf':
        'The image did not match the shape, color distribution, or vein '
        'texture the model expects from a tomato leaf, so it was classified '
        'as background rather than being forced into a disease class.',
  };

  double get _clarityScore {
    final q = frameQuality;
    if (q == null) return 0.75; // Not measured — assume decent.
    final sharpness = (q.sharpness / 300).clamp(0.0, 1.0);
    final brightness = 1 - ((q.brightness - 137).abs() / 120).clamp(0.0, 1.0);
    return sharpness * 0.6 + brightness * 0.4;
  }

  bool get _wasDemoted =>
      result.reliabilityState == ReliabilityState.lowConfidenceEscalate &&
      result.confidenceScore >= 0.70;

  Color get _severityColor => switch (severity.category) {
        SeverityCategory.mild => AppColors.severityHealthy,
        SeverityCategory.moderate => AppColors.severityModerate,
        SeverityCategory.severe => AppColors.severitySevere,
      };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      scrollable: true,
      icon: const Icon(Icons.psychology, size: 32),
      title: const Text('Why This Diagnosis?'),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          _Section(
            icon: Icons.grid_on,
            title: 'What the AI saw',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: _severityColor.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        '${severity.category.labelEn} · '
                        '${severity.category.labelHi}',
                        style: TextStyle(
                          color: _severityColor,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '${severity.percentLabel} lesion coverage',
                      style: theme.textTheme.bodyMedium,
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  severity.isReliable
                      ? 'Yellow-brown (chlorotic/necrotic) tissue covers '
                          '${severity.percentLabel} of the visible leaf area. '
                          'The heatmap highlights where that lesion density '
                          'is concentrated.'
                      : 'Only a small part of the frame looks like leaf '
                          'tissue, so the lesion measurement is a rough '
                          'estimate.',
                  style: theme.textTheme.bodyMedium,
                ),
              ],
            ),
          ),
          _Section(
            icon: Icons.speed,
            title: 'AI Confidence vs Image Clarity',
            child: Column(
              children: [
                _MeterRow(
                  label: 'AI confidence',
                  value: result.confidenceScore,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(height: 8),
                _MeterRow(
                  label: 'Image clarity',
                  value: _clarityScore,
                  color: AppColors.severityModerate,
                ),
                if (_wasDemoted) ...[
                  const SizedBox(height: 8),
                  Text(
                    'Note: the model was confident, but photo quality was '
                    'low, so this result was downgraded and routed for '
                    'expert review.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                ],
              ],
            ),
          ),
          _Section(
            icon: Icons.biotech,
            title: 'Why this pathogen',
            child: Text(
              _pathogenRationale[result.className] ??
                  'The model matched this image most closely to '
                      '"${result.className}" based on its learned visual '
                      'patterns.',
              style: theme.textTheme.bodyMedium,
            ),
          ),
          if (result.usedMockModel) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(
                  Icons.science,
                  size: 16,
                  color: theme.colorScheme.outline,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'Demo mode: prototype output while the trained model is '
                    'being finalized.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.outline,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Got it'),
        ),
      ],
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({
    required this.icon,
    required this.title,
    required this.child,
  });

  final IconData icon;
  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 18, color: theme.colorScheme.primary),
              const SizedBox(width: 8),
              Text(
                title,
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          child,
        ],
      ),
    );
  }
}

class _MeterRow extends StatelessWidget {
  const _MeterRow({
    required this.label,
    required this.value,
    required this.color,
  });

  final String label;
  final double value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        SizedBox(
          width: 110,
          child: Text(label, style: theme.textTheme.bodySmall),
        ),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              value: value.clamp(0.0, 1.0),
              minHeight: 8,
              color: color,
              backgroundColor: color.withValues(alpha: 0.15),
            ),
          ),
        ),
        const SizedBox(width: 8),
        SizedBox(
          width: 38,
          child: Text(
            '${(value * 100).round()}%',
            textAlign: TextAlign.end,
            style: theme.textTheme.bodySmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }
}
