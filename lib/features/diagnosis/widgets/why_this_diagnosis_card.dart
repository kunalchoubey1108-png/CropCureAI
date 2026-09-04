import 'package:flutter/material.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/models/diagnosis_result.dart';
import '../../../core/utils/image_checker.dart';
import 'severity_calculator.dart';

/// Expandable explainability accordion: breaks the AI's evidence into
/// three visual bullet cards — image quality, lesion pattern match, and
/// the calculated reliability level.
class WhyThisDiagnosisCard extends StatelessWidget {
  const WhyThisDiagnosisCard({
    super.key,
    required this.result,
    required this.severity,
    this.frameQuality,
  });

  final DiagnosisResult result;
  final SeverityResult severity;
  final FrameQualityResult? frameQuality;

  /// Pathogen-specific rationale, keyed by raw model label.
  static const Map<String, String> _pathogenRationale = {
    'Tomato___Early_blight':
        'Dark brown spots with concentric rings (a "target board" pattern) '
        'and yellow halos matched the signature of Alternaria solani on '
        'older leaves.',
    'Tomato___healthy':
        'Uniform green tissue with no chlorotic patches, necrotic spots, or '
        'ring patterns — none of the lesion textures linked to tomato '
        'diseases.',
    'Background_Non_Leaf':
        'The image did not match the shape, color, or vein texture of a '
        'tomato leaf, so it was classified as background instead of being '
        'forced into a disease.',
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

  (Color, String, IconData) get _reliabilityBadge =>
      switch (result.reliabilityState) {
        ReliabilityState.highConfidence => (
          AppColors.severityHealthy,
          'HIGH CONFIDENCE',
          Icons.verified,
        ),
        ReliabilityState.lowConfidenceEscalate => (
          AppColors.severityModerate,
          'NEEDS EXPERT REVIEW',
          Icons.help,
        ),
        ReliabilityState.outOfBoundsReject => (
          AppColors.severitySevere,
          'REJECTED (NOT A LEAF)',
          Icons.block,
        ),
      };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final qualityOk = frameQuality?.isUsable ?? true;
    final (relColor, relLabel, relIcon) = _reliabilityBadge;

    return Card(
      clipBehavior: Clip.antiAlias,
      child: Theme(
        // Remove ExpansionTile's default dividers.
        data: theme.copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          leading: const Icon(Icons.psychology, size: 28),
          iconColor: theme.colorScheme.primary,
          collapsedIconColor: theme.colorScheme.primary,
          title: Text('Why This Diagnosis?', style: theme.textTheme.titleSmall),
          subtitle: Text(
            'See the AI\'s evidence',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.outline,
            ),
          ),
          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          children: [
            _EvidenceTile(
              step: 1,
              icon: qualityOk ? Icons.photo_camera : Icons.blur_on,
              color: qualityOk
                  ? AppColors.severityHealthy
                  : AppColors.severityModerate,
              title: 'Image Quality Check',
              detail: qualityOk
                  ? 'Photo passed the blur & lighting check '
                        '(clarity ${(_clarityScore * 100).round()}%).'
                  : 'Photo was flagged: '
                        '${frameQuality!.issues.first.toLowerCase()}',
              meter: _clarityScore,
            ),
            _EvidenceTile(
              step: 2,
              icon: Icons.pattern,
              color: AppColors.severityModerate,
              title: 'Lesion Pattern Match',
              detail:
                  '${severity.percentLabel} of the leaf shows yellow-brown '
                  'lesion tissue. '
                  '${_pathogenRationale[result.className] ?? 'The model matched this image most closely to "${result.className}".'}',
              meter: (severity.infectionPercent / 100).clamp(0.0, 1.0),
            ),
            _EvidenceTile(
              step: 3,
              icon: relIcon,
              color: relColor,
              title: 'Calculated Reliability Level',
              detail:
                  'Model confidence '
                  '${(result.confidenceScore * 100).toStringAsFixed(0)}%.'
                  '${_wasDemoted ? ' Confidence was downgraded because photo quality was low — routed for expert review.' : ''}',
              meter: result.confidenceScore,
              badge: relLabel,
            ),
            if (result.usedMockModel)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Row(
                  children: [
                    Icon(
                      Icons.science,
                      size: 15,
                      color: theme.colorScheme.outline,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        'Demo mode: prototype output while the trained '
                        'model is being finalized.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.outline,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// One numbered evidence bullet: icon chip, title, meter, and detail text.
class _EvidenceTile extends StatelessWidget {
  const _EvidenceTile({
    required this.step,
    required this.icon,
    required this.color,
    required this.title,
    required this.detail,
    required this.meter,
    this.badge,
  });

  final int step;
  final IconData icon;
  final Color color;
  final String title;
  final String detail;

  /// 0..1 value for the mini meter under the title.
  final double meter;

  /// Optional bold status badge shown on the right.
  final String? badge;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.statusTint(color),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(shape: BoxShape.circle, color: color),
            child: Icon(icon, color: Colors.white, size: 22),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '$step. $title',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    if (badge != null)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: color,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          badge!,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 9.5,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.3,
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 6),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: meter.clamp(0.0, 1.0),
                    minHeight: 6,
                    color: color,
                    backgroundColor: color.withValues(alpha: 0.15),
                  ),
                ),
                const SizedBox(height: 6),
                Text(detail, style: theme.textTheme.bodySmall),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
