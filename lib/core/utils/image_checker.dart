import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

/// Outcome of a pre-inference frame quality check.
class FrameQualityResult {
  const FrameQualityResult({
    required this.brightness,
    required this.sharpness,
    required this.issues,
  });

  /// Mean luminance of the frame, 0 (black) – 255 (white).
  final double brightness;

  /// Variance of the Laplacian — higher means more edge detail (sharper).
  final double sharpness;

  /// Human-readable problems found; empty when the frame is usable.
  final List<String> issues;

  bool get isUsable => issues.isEmpty;

  @override
  String toString() =>
      'FrameQualityResult(brightness: ${brightness.toStringAsFixed(1)}, '
      'sharpness: ${sharpness.toStringAsFixed(1)}, issues: $issues)';
}

/// Lightweight brightness + blur validator run before every inference.
///
/// The frame is downscaled to [_analysisWidth] px so the whole check stays
/// in the tens of milliseconds, and the pixel work runs off the UI thread
/// via [compute].
class ImageChecker {
  ImageChecker._();

  /// Frames are resized to this width (aspect preserved) before analysis.
  static const int _analysisWidth = 224;

  /// Mean luminance below this reads as "too dark" (0–255 scale).
  static const double minBrightness = 40;

  /// Mean luminance above this reads as overexposed / washed out.
  static const double maxBrightness = 235;

  /// Laplacian variance below this reads as blurry. Tuned on downscaled
  /// 224px frames; raise it to be stricter about focus.
  static const double minSharpness = 45;

  static Future<FrameQualityResult> analyzeFile(String path) async {
    final bytes = await File(path).readAsBytes();
    return compute(_analyzeBytes, bytes);
  }

  static FrameQualityResult _analyzeBytes(Uint8List bytes) {
    final decoded = img.decodeImage(bytes);
    if (decoded == null) {
      return const FrameQualityResult(
        brightness: 0,
        sharpness: 0,
        issues: ['Could not read the image. Please try again.'],
      );
    }

    final gray = img.grayscale(img.copyResize(decoded, width: _analysisWidth));
    final w = gray.width;
    final h = gray.height;

    final luma = Float64List(w * h);
    var sum = 0.0;
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final v = gray.getPixel(x, y).r.toDouble();
        luma[y * w + x] = v;
        sum += v;
      }
    }
    final brightness = sum / (w * h);

    // Variance of the 4-neighbour Laplacian over interior pixels.
    var lapSum = 0.0;
    var lapSqSum = 0.0;
    final count = (w - 2) * (h - 2);
    for (var y = 1; y < h - 1; y++) {
      for (var x = 1; x < w - 1; x++) {
        final i = y * w + x;
        final lap =
            4 * luma[i] - luma[i - 1] - luma[i + 1] - luma[i - w] - luma[i + w];
        lapSum += lap;
        lapSqSum += lap * lap;
      }
    }
    final mean = lapSum / count;
    final sharpness = lapSqSum / count - mean * mean;

    final issues = <String>[
      if (brightness < minBrightness)
        'Too dark — move to better light or turn on the flash.',
      if (brightness > maxBrightness)
        'Too bright — avoid direct sunlight or glare on the leaf.',
      if (sharpness < minSharpness)
        'Image looks blurry — hold the phone steady and refocus.',
    ];

    return FrameQualityResult(
      brightness: brightness,
      sharpness: sharpness,
      issues: issues,
    );
  }
}

/// Convenience: `await File(path).validateForInference()`.
extension FrameQualityCheck on File {
  Future<FrameQualityResult> validateForInference() =>
      ImageChecker.analyzeFile(path);
}
