import 'dart:io';

import 'package:flutter/material.dart';

import '../core/constants/app_colors.dart';
import '../core/services/tflite_service.dart';

/// Loud, unmissable warning that inference is fake.
///
/// `TFLiteService` deliberately falls back to seeded mock scores when the
/// model cannot be loaded, so the UI never crashes. The cost of that is a
/// stale build looking exactly like a broken model — which is what
/// "it scans everything as blight" turned out to be. A quiet chip on the
/// results screen was not enough; this says so before a scan is taken.
class MockModelBanner extends StatelessWidget {
  const MockModelBanner({super.key});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<void>(
      future: TFLiteService.instance.load(),
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done ||
            !TFLiteService.instance.isMockMode) {
          return const SizedBox.shrink();
        }
        return Material(
          color: AppColors.severitySevere,
          child: SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: const Row(
                children: [
                  Icon(Icons.science, color: Colors.white, size: 18),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'DEMO MODEL — model.tflite failed to load, results are '
                      'fake. Rebuild and reinstall the app.',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// A scan photo from disk, with the placeholder every caller wants when the
/// path is empty or the file has been cleaned up.
///
/// Four screens were repeating the same `Image.file` + `errorBuilder` +
/// empty-path ternary; this is that block, once.
class LeafImage extends StatelessWidget {
  const LeafImage({
    super.key,
    required this.path,
    this.icon = Icons.eco,
    this.iconSize,
  });

  final String path;
  final IconData icon;
  final double? iconSize;

  @override
  Widget build(BuildContext context) {
    final placeholder = ColoredBox(
      color: Colors.black12,
      child: Icon(icon, size: iconSize),
    );
    if (path.isEmpty) return placeholder;
    return Image.file(
      File(path),
      fit: BoxFit.cover,
      errorBuilder: (context, error, stack) => placeholder,
    );
  }
}

/// Drives a looping animation and hands the raw 0..1 value to [builder].
///
/// Replaces the StatefulWidget + AnimationController + initState + dispose
/// boilerplate that four separate widgets were each carrying to do this.
class PulseBuilder extends StatefulWidget {
  const PulseBuilder({
    super.key,
    required this.duration,
    required this.builder,
    this.reverse = false,
  });

  final Duration duration;

  /// True bounces 0->1->0; false ramps 0->1 and snaps back.
  final bool reverse;

  final Widget Function(BuildContext context, double t) builder;

  @override
  State<PulseBuilder> createState() => _PulseBuilderState();
}

class _PulseBuilderState extends State<PulseBuilder>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: widget.duration,
  )..repeat(reverse: widget.reverse);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _controller,
    builder: (context, _) => widget.builder(context, _controller.value),
  );
}
