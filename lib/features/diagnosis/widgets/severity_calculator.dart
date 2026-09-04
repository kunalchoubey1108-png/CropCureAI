import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

import '../../../core/constants/app_colors.dart';

/// Infection severity bands based on lesion surface coverage.
enum SeverityCategory {
  /// Less than 10% of leaf area affected.
  mild,

  /// 10–30% of leaf area affected.
  moderate,

  /// More than 30% of leaf area affected.
  severe,
}

extension SeverityCategoryLabels on SeverityCategory {
  String get labelEn => switch (this) {
    SeverityCategory.mild => 'Mild',
    SeverityCategory.moderate => 'Moderate',
    SeverityCategory.severe => 'Severe',
  };

  String get labelHi => switch (this) {
    SeverityCategory.mild => 'हल्का',
    SeverityCategory.moderate => 'मध्यम',
    SeverityCategory.severe => 'गंभीर',
  };

  String label(String lang) => lang == 'hi' ? labelHi : labelEn;

  /// The one place severity maps to a color. Callers that only have a raw
  /// percentage go through [SeverityCalculator.categorize] first rather
  /// than re-hardcoding the 10 / 30 band edges.
  Color get color => switch (this) {
    SeverityCategory.mild => AppColors.severityHealthy,
    SeverityCategory.moderate => AppColors.severityModerate,
    SeverityCategory.severe => AppColors.severitySevere,
  };
}

/// Result of the pixel-level lesion analysis.
class SeverityResult {
  const SeverityResult({
    required this.infectionPercent,
    required this.category,
    required this.leafCoverage,
    required this.lesionGrid,
    required this.isReliable,
  });

  /// Lesion pixels as a percentage of all leaf pixels, 0–100.
  final double infectionPercent;

  final SeverityCategory category;

  /// Fraction of the whole frame recognized as leaf (healthy + lesion).
  final double leafCoverage;

  /// [SeverityCalculator.gridSize]² lesion-density map normalized to 0–1,
  /// indexed `[row][col]`. Drives the Grad-CAM style heatmap overlay.
  final List<List<double>> lesionGrid;

  /// False when too little of the frame is leaf for the ratio to mean much.
  final bool isReliable;

  String get percentLabel => '${infectionPercent.toStringAsFixed(1)}%';

  @override
  String toString() =>
      'SeverityResult($percentLabel, ${category.name}, '
      'leaf: ${(leafCoverage * 100).toStringAsFixed(0)}%'
      '${isReliable ? '' : ', UNRELIABLE'})';
}

/// Estimates infected leaf surface by classifying pixel colors:
/// healthy green tissue vs chlorotic yellow / necrotic brown lesion tissue.
///
/// Pure color-space heuristic — cheap, offline, and explainable, which is
/// exactly what the "Why This Diagnosis?" breakdown needs.
class SeverityCalculator {
  SeverityCalculator._();

  /// Analysis runs on a copy downscaled to this width.
  static const int analysisWidth = 224;

  /// Lesion density grid is [gridSize] x [gridSize].
  static const int gridSize = 14;

  /// Below this leaf-pixel fraction the ratio is flagged unreliable.
  static const double minLeafCoverage = 0.08;

  static const double _mildUpperPercent = 10;
  static const double _moderateUpperPercent = 30;

  static Future<SeverityResult> analyzeFile(String path) async {
    final bytes = await File(path).readAsBytes();
    return compute(_analyzeBytes, bytes);
  }

  static SeverityResult _analyzeBytes(Uint8List bytes) {
    final decoded = img.decodeImage(bytes);
    if (decoded == null) {
      return SeverityResult(
        infectionPercent: 0,
        category: SeverityCategory.mild,
        leafCoverage: 0,
        lesionGrid: _emptyGrid(),
        isReliable: false,
      );
    }
    return analyze(img.copyResize(decoded, width: analysisWidth));
  }

  /// Analyzes an already-decoded image buffer.
  static SeverityResult analyze(img.Image image) {
    final w = image.width;
    final h = image.height;

    var healthy = 0;
    var lesion = 0;
    final lesionCounts = _emptyGrid();
    final cellTotals = _emptyGrid();

    for (var y = 0; y < h; y++) {
      final row = min(y * gridSize ~/ h, gridSize - 1);
      for (var x = 0; x < w; x++) {
        final col = min(x * gridSize ~/ w, gridSize - 1);
        cellTotals[row][col] += 1;

        final p = image.getPixel(x, y);
        switch (_classify(p.r, p.g, p.b)) {
          case _PixelClass.healthy:
            healthy++;
          case _PixelClass.lesion:
            lesion++;
            lesionCounts[row][col] += 1;
          case _PixelClass.background:
            break;
        }
      }
    }

    final leafPixels = healthy + lesion;
    final total = w * h;
    final infectionPercent = leafPixels == 0 ? 0.0 : lesion / leafPixels * 100;

    // Convert per-cell lesion counts to density, then normalize so the
    // strongest cell is 1.0 — relative focus, like a Grad-CAM activation.
    var maxDensity = 0.0;
    for (var r = 0; r < gridSize; r++) {
      for (var c = 0; c < gridSize; c++) {
        final density = cellTotals[r][c] == 0
            ? 0.0
            : lesionCounts[r][c] / cellTotals[r][c];
        lesionCounts[r][c] = density;
        maxDensity = max(maxDensity, density);
      }
    }
    if (maxDensity > 0) {
      for (final row in lesionCounts) {
        for (var c = 0; c < gridSize; c++) {
          row[c] /= maxDensity;
        }
      }
    }

    return SeverityResult(
      infectionPercent: infectionPercent,
      category: categorize(infectionPercent),
      leafCoverage: leafPixels / total,
      lesionGrid: lesionCounts,
      isReliable: leafPixels / total >= minLeafCoverage,
    );
  }

  static SeverityCategory categorize(double percent) {
    if (percent < _mildUpperPercent) return SeverityCategory.mild;
    if (percent <= _moderateUpperPercent) return SeverityCategory.moderate;
    return SeverityCategory.severe;
  }

  /// HSV-band pixel classifier:
  /// - green hues (65°–175°) with real saturation = healthy tissue
  /// - yellow through brown hues (5°–65°) = chlorotic/necrotic lesion
  /// - everything else (dark, washed out, gray, blue/red) = background
  static _PixelClass _classify(num r8, num g8, num b8) {
    final r = r8 / 255.0;
    final g = g8 / 255.0;
    final b = b8 / 255.0;

    final maxC = max(r, max(g, b));
    final minC = min(r, min(g, b));
    final delta = maxC - minC;

    if (maxC < 0.12) return _PixelClass.background; // deep shadow
    final sat = delta / maxC;
    if (sat < 0.14) return _PixelClass.background; // gray / glare / soil dust

    double hue;
    if (delta == 0) {
      hue = 0;
    } else if (maxC == r) {
      hue = 60 * (((g - b) / delta) % 6);
    } else if (maxC == g) {
      hue = 60 * ((b - r) / delta + 2);
    } else {
      hue = 60 * ((r - g) / delta + 4);
    }
    if (hue < 0) hue += 360;

    if (hue >= 65 && hue <= 175) return _PixelClass.healthy;
    if (hue >= 5 && hue < 65) return _PixelClass.lesion;
    return _PixelClass.background;
  }

  static List<List<double>> _emptyGrid() =>
      List.generate(gridSize, (_) => List.filled(gridSize, 0.0));
}

enum _PixelClass { healthy, lesion, background }
