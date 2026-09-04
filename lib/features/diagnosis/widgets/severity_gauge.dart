import 'dart:math';

import 'package:flutter/material.dart';

import '../../../core/constants/app_colors.dart';
import 'severity_calculator.dart';

/// Semi-circular radial gauge showing infection severity, with a large
/// percentage readout, a color-coded status pill, and a healthy-vs-lesion
/// tissue breakdown bar. Animates its sweep on first build.
class SeverityGauge extends StatelessWidget {
  const SeverityGauge({super.key, required this.severity, this.lang = 'en'});

  final SeverityResult severity;

  /// 'en' or 'hi' — controls the status pill label.
  final String lang;

  Color get _color => severity.category.color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final percent = severity.infectionPercent.clamp(0.0, 100.0);
    final healthyPct = (100 - percent).clamp(0.0, 100.0);
    final label = severity.category.label(lang);

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
        child: Column(
          children: [
            Row(
              children: [
                Icon(Icons.donut_large, size: 20, color: _color),
                const SizedBox(width: 8),
                Text('Severity', style: theme.textTheme.titleSmall),
                const Spacer(),
                // Color-coded status pill.
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: _color,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    label,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
                      fontSize: 14,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            // Animated radial gauge.
            TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: percent / 100),
              duration: const Duration(milliseconds: 900),
              curve: Curves.easeOutCubic,
              builder: (context, t, _) => SizedBox(
                width: 190,
                height: 110,
                child: CustomPaint(
                  painter: _RadialGaugePainter(
                    value: t,
                    color: _color,
                    trackColor: _color.withValues(alpha: 0.12),
                  ),
                  child: Align(
                    alignment: const Alignment(0, 0.9),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        const Spacer(),
                        Text(
                          '${(t * 100).toStringAsFixed(1)}%',
                          style: theme.textTheme.headlineMedium?.copyWith(
                            color: _color,
                            fontWeight: FontWeight.w800,
                            height: 1,
                          ),
                        ),
                        Text(
                          lang == 'hi' ? 'पत्ती प्रभावित' : 'leaf affected',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.outline,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 14),
            // Healthy vs lesion tissue breakdown.
            _TissueBreakdownBar(
              healthyPct: healthyPct,
              lesionPct: percent,
              lesionColor: _color,
              lang: lang,
            ),
          ],
        ),
      ),
    );
  }
}

/// Segmented horizontal bar: healthy green tissue vs infected lesion
/// tissue, with icon legend — readable without any text literacy.
class _TissueBreakdownBar extends StatelessWidget {
  const _TissueBreakdownBar({
    required this.healthyPct,
    required this.lesionPct,
    required this.lesionColor,
    required this.lang,
  });

  final double healthyPct;
  final double lesionPct;
  final Color lesionColor;
  final String lang;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final healthyFlex = max(1, healthyPct.round());
    final lesionFlex = max(1, lesionPct.round());
    return Column(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: SizedBox(
            height: 16,
            child: Row(
              children: [
                Expanded(
                  flex: healthyFlex,
                  child: const ColoredBox(color: AppColors.severityHealthy),
                ),
                const SizedBox(width: 2),
                Expanded(
                  flex: lesionFlex,
                  child: ColoredBox(color: lesionColor),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            _legend(
              theme,
              Icons.eco,
              AppColors.severityHealthy,
              lang == 'hi'
                  ? 'स्वस्थ ${healthyPct.toStringAsFixed(0)}%'
                  : 'Healthy ${healthyPct.toStringAsFixed(0)}%',
            ),
            _legend(
              theme,
              Icons.coronavirus,
              lesionColor,
              lang == 'hi'
                  ? 'संक्रमित ${lesionPct.toStringAsFixed(0)}%'
                  : 'Infected ${lesionPct.toStringAsFixed(0)}%',
            ),
          ],
        ),
      ],
    );
  }

  Widget _legend(ThemeData theme, IconData icon, Color color, String text) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 5),
        Text(
          text,
          style: theme.textTheme.bodySmall?.copyWith(
            fontWeight: FontWeight.w700,
            color: color,
          ),
        ),
      ],
    );
  }
}

/// 180-degree arc gauge with rounded caps and a tick at the needle point.
class _RadialGaugePainter extends CustomPainter {
  const _RadialGaugePainter({
    required this.value,
    required this.color,
    required this.trackColor,
  });

  /// 0..1 fill fraction.
  final double value;
  final Color color;
  final Color trackColor;

  @override
  void paint(Canvas canvas, Size size) {
    const stroke = 16.0;
    final center = Offset(size.width / 2, size.height - 4);
    final radius = min(size.width / 2, size.height) - stroke / 2 - 2;
    final rect = Rect.fromCircle(center: center, radius: radius);

    final track = Paint()
      ..color = trackColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(rect, pi, pi, false, track);

    if (value > 0) {
      final sweep = pi * value.clamp(0.0, 1.0);
      final fill = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..strokeCap = StrokeCap.round
        ..shader = SweepGradient(
          startAngle: pi,
          endAngle: 2 * pi,
          colors: [color.withValues(alpha: 0.55), color],
        ).createShader(rect);
      canvas.drawArc(rect, pi, sweep, false, fill);

      // Needle dot at the current position.
      final angle = pi + sweep;
      final tip = center + Offset(cos(angle) * radius, sin(angle) * radius);
      canvas.drawCircle(tip, stroke / 2 + 2, Paint()..color = Colors.white);
      canvas.drawCircle(tip, stroke / 2 - 2, Paint()..color = color);
    }
  }

  @override
  bool shouldRepaint(_RadialGaugePainter oldDelegate) =>
      oldDelegate.value != value || oldDelegate.color != color;
}
