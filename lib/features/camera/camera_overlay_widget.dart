import 'dart:async';

import 'package:flutter/material.dart';

/// Dimmed overlay with a centered leaf bounding box and cycling
/// real-time capture hints.
class CameraOverlayWidget extends StatefulWidget {
  const CameraOverlayWidget({
    super.key,
    this.boxFraction = 0.72,
    this.hints = const [
      'Center the leaf inside the frame',
      'Hold phone steady',
    ],
  });

  /// Side of the bounding box as a fraction of the shorter screen edge.
  final double boxFraction;

  /// Hints cycled below the bounding box.
  final List<String> hints;

  @override
  State<CameraOverlayWidget> createState() => _CameraOverlayWidgetState();
}

class _CameraOverlayWidgetState extends State<CameraOverlayWidget> {
  Timer? _hintTimer;
  int _hintIndex = 0;

  @override
  void initState() {
    super.initState();
    if (widget.hints.length > 1) {
      _hintTimer = Timer.periodic(const Duration(seconds: 3), (_) {
        setState(() => _hintIndex = (_hintIndex + 1) % widget.hints.length);
      });
    }
  }

  @override
  void dispose() {
    _hintTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
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
              CustomPaint(painter: _ScannerFramePainter(box: box)),
              Positioned(
                top: box.bottom + 20,
                left: 24,
                right: 24,
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 400),
                  child: Container(
                    key: ValueKey(_hintIndex),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.55),
                      borderRadius: BorderRadius.circular(24),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(
                          Icons.center_focus_strong,
                          color: Colors.white70,
                          size: 18,
                        ),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            widget.hints[_hintIndex],
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 15,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ],
                    ),
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

/// Paints the dimmed surround with a rounded cutout and corner brackets.
class _ScannerFramePainter extends CustomPainter {
  const _ScannerFramePainter({required this.box});

  final Rect box;

  static const double _cornerRadius = 24;
  static const double _bracketLength = 30;
  static const double _bracketStroke = 4;

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
      Paint()..color = Colors.black.withValues(alpha: 0.45),
    );

    // Corner brackets.
    final bracket = Paint()
      ..color = const Color(0xFF9CFF57)
      ..style = PaintingStyle.stroke
      ..strokeWidth = _bracketStroke
      ..strokeCap = StrokeCap.round;

    void corner(Offset anchor, double dx, double dy) {
      canvas.drawPath(
        Path()
          ..moveTo(anchor.dx + dx * _bracketLength, anchor.dy)
          ..lineTo(anchor.dx + dx * _cornerRadius, anchor.dy)
          ..arcToPoint(
            Offset(anchor.dx, anchor.dy + dy * _cornerRadius),
            radius: const Radius.circular(_cornerRadius),
            clockwise: dx * dy < 0,
          )
          ..lineTo(anchor.dx, anchor.dy + dy * _bracketLength),
        bracket,
      );
    }

    corner(box.topLeft, 1, 1);
    corner(box.topRight, -1, 1);
    corner(box.bottomLeft, 1, -1);
    corner(box.bottomRight, -1, -1);
  }

  @override
  bool shouldRepaint(_ScannerFramePainter oldDelegate) =>
      oldDelegate.box != box;
}
