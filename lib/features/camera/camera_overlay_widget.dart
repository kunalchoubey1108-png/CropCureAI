import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/constants/app_colors.dart';

/// One state of the floating hint pill above/below the viewfinder.
class ScannerHint {
  const ScannerHint({
    required this.text,
    required this.icon,
    required this.color,
    this.pulsing = false,
  });

  final String text;
  final IconData icon;
  final Color color;

  /// Pulsing pills draw attention (guidance); solid pills confirm.
  final bool pulsing;
}

/// Animated scanning overlay: dimmed surround with a rounded leaf frame,
/// pulsing corner brackets, a vertical laser sweep simulating live edge
/// analysis, and a dynamic status pill.
class CameraOverlayWidget extends StatefulWidget {
  const CameraOverlayWidget({
    super.key,
    this.boxFraction = 0.72,
    this.hints = const [
      ScannerHint(
        text: 'Hold steady • Center leaf',
        icon: Icons.center_focus_strong,
        color: AppColors.severityModerate,
        pulsing: true,
      ),
      ScannerHint(
        text: 'Good Lighting Detected',
        icon: Icons.wb_sunny,
        color: AppColors.severityHealthy,
      ),
      ScannerHint(
        text: 'पत्ती को बीच में रखें',
        icon: Icons.eco,
        color: AppColors.severityModerate,
        pulsing: true,
      ),
    ],
  });

  /// Side of the bounding box as a fraction of the shorter screen edge.
  final double boxFraction;

  /// Hint states cycled while scanning.
  final List<ScannerHint> hints;

  @override
  State<CameraOverlayWidget> createState() => _CameraOverlayWidgetState();
}

class _CameraOverlayWidgetState extends State<CameraOverlayWidget>
    with TickerProviderStateMixin {
  late final AnimationController _laser;
  late final AnimationController _pulse;
  Timer? _hintTimer;
  int _hintIndex = 0;

  @override
  void initState() {
    super.initState();
    _laser = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2200),
    )..repeat(reverse: true);
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
    if (widget.hints.length > 1) {
      _hintTimer = Timer.periodic(const Duration(seconds: 3), (_) {
        setState(() => _hintIndex = (_hintIndex + 1) % widget.hints.length);
      });
    }
  }

  @override
  void dispose() {
    _laser.dispose();
    _pulse.dispose();
    _hintTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hint = widget.hints[_hintIndex];
    return IgnorePointer(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final size = Size(constraints.maxWidth, constraints.maxHeight);
          final side = size.shortestSide * widget.boxFraction;
          final box = Rect.fromCenter(
            center: Offset(size.width / 2, size.height / 2 - 24),
            width: side,
            height: side,
          );

          return Stack(
            fit: StackFit.expand,
            children: [
              AnimatedBuilder(
                animation: Listenable.merge([_laser, _pulse]),
                builder: (context, _) => CustomPaint(
                  painter: _ScannerFramePainter(
                    box: box,
                    laserT: Curves.easeInOut.transform(_laser.value),
                    // Bracket glow breathes between 0.55 and 1.0.
                    bracketGlow: 0.55 + 0.45 * _pulse.value,
                  ),
                ),
              ),
              // Floating status pill.
              Positioned(
                top: box.top - 64,
                left: 24,
                right: 24,
                child: Center(
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 400),
                    child: _HintPill(
                      key: ValueKey(_hintIndex),
                      hint: hint,
                      pulse: _pulse,
                    ),
                  ),
                ),
              ),
              // Analysis caption under the frame.
              Positioned(
                top: box.bottom + 18,
                left: 24,
                right: 24,
                child: FadeTransition(
                  opacity:
                      Tween(begin: 0.5, end: 1.0).animate(_pulse),
                  child: const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.radar,
                          color: AppColors.scannerAccent, size: 18),
                      SizedBox(width: 8),
                      Text(
                        'Scanning for leaf...',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.4,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Semi-transparent status pill; amber guidance pills pulse, green
/// confirmation pills hold solid.
class _HintPill extends StatelessWidget {
  const _HintPill({super.key, required this.hint, required this.pulse});

  final ScannerHint hint;
  final Animation<double> pulse;

  @override
  Widget build(BuildContext context) {
    final pill = Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 11),
      decoration: BoxDecoration(
        color: hint.color.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: Colors.white.withValues(alpha: 0.7)),
        boxShadow: [
          BoxShadow(
            color: hint.color.withValues(alpha: 0.45),
            blurRadius: 16,
            spreadRadius: 1,
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(hint.icon, color: Colors.white, size: 20),
          const SizedBox(width: 9),
          Flexible(
            child: Text(
              hint.text,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 15.5,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.2,
              ),
            ),
          ),
        ],
      ),
    );
    if (!hint.pulsing) return pill;
    return FadeTransition(
      opacity: Tween(begin: 0.65, end: 1.0).animate(pulse),
      child: ScaleTransition(
        scale: Tween(begin: 0.97, end: 1.0).animate(pulse),
        child: pill,
      ),
    );
  }
}

/// Paints the dimmed surround, glowing corner brackets, and the vertical
/// laser sweep line inside the frame.
class _ScannerFramePainter extends CustomPainter {
  const _ScannerFramePainter({
    required this.box,
    required this.laserT,
    required this.bracketGlow,
  });

  final Rect box;

  /// 0..1 vertical position of the laser line within the box.
  final double laserT;

  /// 0..1 bracket brightness for the pulsing effect.
  final double bracketGlow;

  static const double _cornerRadius = 24;
  static const double _bracketLength = 30;
  static const double _bracketStroke = 4.5;

  @override
  void paint(Canvas canvas, Size size) {
    final cutout = RRect.fromRectAndRadius(
      box,
      const Radius.circular(_cornerRadius),
    );

    // Dim everything except the bounding box.
    final dimPath = Path.combine(
      PathOperation.difference,
      Path()..addRect(Offset.zero & size),
      Path()..addRRect(cutout),
    );
    canvas.drawPath(
      dimPath,
      Paint()..color = Colors.black.withValues(alpha: 0.48),
    );

    // Laser sweep line (clipped to the frame).
    canvas.save();
    canvas.clipRRect(cutout);
    final y = box.top + box.height * laserT;
    final laserRect = Rect.fromLTRB(box.left, y - 26, box.right, y + 26);
    canvas.drawRect(
      laserRect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            AppColors.scannerAccent.withValues(alpha: 0),
            AppColors.scannerAccent.withValues(alpha: 0.28),
            AppColors.scannerAccent.withValues(alpha: 0),
          ],
        ).createShader(laserRect),
    );
    canvas.drawLine(
      Offset(box.left + 8, y),
      Offset(box.right - 8, y),
      Paint()
        ..color = AppColors.scannerAccent.withValues(alpha: 0.95)
        ..strokeWidth = 2.4
        ..strokeCap = StrokeCap.round
        ..maskFilter = const MaskFilter.blur(BlurStyle.solid, 3),
    );
    canvas.restore();

    // Pulsing corner brackets with a soft glow.
    final bracket = Paint()
      ..color = AppColors.scannerAccent.withValues(alpha: bracketGlow)
      ..style = PaintingStyle.stroke
      ..strokeWidth = _bracketStroke
      ..strokeCap = StrokeCap.round;
    final glow = Paint()
      ..color =
          AppColors.scannerAccent.withValues(alpha: 0.35 * bracketGlow)
      ..style = PaintingStyle.stroke
      ..strokeWidth = _bracketStroke + 5
      ..strokeCap = StrokeCap.round
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6);

    void corner(Offset anchor, double dx, double dy) {
      final path = Path()
        ..moveTo(anchor.dx + dx * _bracketLength, anchor.dy)
        ..lineTo(anchor.dx + dx * _cornerRadius, anchor.dy)
        ..arcToPoint(
          Offset(anchor.dx, anchor.dy + dy * _cornerRadius),
          radius: const Radius.circular(_cornerRadius),
          clockwise: dx * dy < 0,
        )
        ..lineTo(anchor.dx, anchor.dy + dy * _bracketLength);
      canvas.drawPath(path, glow);
      canvas.drawPath(path, bracket);
    }

    corner(box.topLeft, 1, 1);
    corner(box.topRight, -1, 1);
    corner(box.bottomLeft, 1, -1);
    corner(box.bottomRight, -1, -1);
  }

  @override
  bool shouldRepaint(_ScannerFramePainter oldDelegate) =>
      oldDelegate.box != box ||
      oldDelegate.laserT != laserT ||
      oldDelegate.bracketGlow != bracketGlow;
}
