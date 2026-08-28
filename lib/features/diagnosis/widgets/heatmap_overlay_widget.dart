import 'dart:io';

import 'package:flutter/material.dart';

import 'severity_calculator.dart';

/// Leaf photo with a toggleable Grad-CAM style "AI focus" heatmap.
///
/// The thermal blobs are driven by the lesion-density grid from
/// [SeverityCalculator] — a visual simulation of the model's activation
/// map, concentrated over the regions that actually contain lesion-colored
/// tissue.
class GradCAMHeatmapOverlay extends StatefulWidget {
  const GradCAMHeatmapOverlay({
    super.key,
    required this.imagePath,
    required this.diseaseClass,
    this.severity,
    this.aspectRatio = 4 / 3,
  });

  final String imagePath;

  /// Raw model label, e.g. `Tomato___Early_blight`; shown in the caption.
  final String diseaseClass;

  /// Precomputed analysis; when null the widget computes it itself.
  final SeverityResult? severity;

  final double aspectRatio;

  @override
  State<GradCAMHeatmapOverlay> createState() => _GradCAMHeatmapOverlayState();
}

class _GradCAMHeatmapOverlayState extends State<GradCAMHeatmapOverlay> {
  late Future<SeverityResult> _severityFuture;
  bool _showHeatmap = false;

  @override
  void initState() {
    super.initState();
    _severityFuture = widget.severity != null
        ? Future.value(widget.severity)
        : SeverityCalculator.analyzeFile(widget.imagePath);
  }

  String get _prettyClassName =>
      widget.diseaseClass.replaceAll('___', ' ').replaceAll('_', ' ');

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<SeverityResult>(
      future: _severityFuture,
      builder: (context, snapshot) {
        final severity = snapshot.data;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: AspectRatio(
                aspectRatio: widget.aspectRatio,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Image.file(
                      File(widget.imagePath),
                      fit: BoxFit.cover,
                      errorBuilder: (context, error, stack) => const ColoredBox(
                        color: Colors.black12,
                        child: Icon(Icons.broken_image, size: 48),
                      ),
                    ),
                    AnimatedOpacity(
                      opacity: _showHeatmap ? 1 : 0,
                      duration: const Duration(milliseconds: 350),
                      child: severity == null
                          ? const SizedBox.shrink()
                          : CustomPaint(
                              painter:
                                  _HeatmapPainter(grid: severity.lesionGrid),
                            ),
                    ),
                    if (_showHeatmap)
                      Positioned(
                        left: 12,
                        bottom: 12,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.6),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            'AI focus — $_prettyClassName',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            FilledButton.tonalIcon(
              onPressed: severity == null
                  ? null
                  : () => setState(() => _showHeatmap = !_showHeatmap),
              icon: Icon(
                _showHeatmap ? Icons.visibility_off : Icons.local_fire_department,
              ),
              label: Text(
                _showHeatmap
                    ? 'Hide AI Focus (Grad-CAM)'
                    : 'Show AI Focus (Grad-CAM)',
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Paints soft thermal blobs over each grid cell, sized and colored by
/// lesion density (blue -> green -> yellow -> orange -> red).
class _HeatmapPainter extends CustomPainter {
  const _HeatmapPainter({required this.grid});

  final List<List<double>> grid;

  /// Densities below this stay unpainted, keeping healthy tissue clear.
  static const double _minDensity = 0.08;

  static const List<Color> _thermalStops = [
    Color(0xFF2196F3), // cool blue
    Color(0xFF4CAF50), // green
    Color(0xFFFFEB3B), // yellow
    Color(0xFFFF9800), // orange
    Color(0xFFF44336), // hot red
  ];

  static Color _thermal(double t) {
    final scaled = t.clamp(0.0, 1.0) * (_thermalStops.length - 1);
    final i = scaled.floor().clamp(0, _thermalStops.length - 2);
    return Color.lerp(_thermalStops[i], _thermalStops[i + 1], scaled - i)!;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final rows = grid.length;
    if (rows == 0) return;
    final cols = grid.first.length;
    final cellW = size.width / cols;
    final cellH = size.height / rows;
    final radius = (cellW > cellH ? cellW : cellH) * 1.1;

    for (var r = 0; r < rows; r++) {
      for (var c = 0; c < cols; c++) {
        final d = grid[r][c];
        if (d < _minDensity) continue;
        final center = Offset((c + 0.5) * cellW, (r + 0.5) * cellH);
        final paint = Paint()
          ..color = _thermal(d).withValues(alpha: 0.15 + 0.45 * d)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, radius * 0.5);
        canvas.drawCircle(center, radius * (0.6 + 0.4 * d), paint);
      }
    }
  }

  @override
  bool shouldRepaint(_HeatmapPainter oldDelegate) => oldDelegate.grid != grid;
}
