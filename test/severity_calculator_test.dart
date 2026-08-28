import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:cropcure_ai/features/diagnosis/widgets/severity_calculator.dart';

img.Image _leaf({
  required double lesionFraction,
  int size = 112,
}) {
  // Left portion lesion-brown, rest healthy green.
  final image = img.Image(width: size, height: size);
  final lesionCols = (size * lesionFraction).round();
  for (var y = 0; y < size; y++) {
    for (var x = 0; x < size; x++) {
      if (x < lesionCols) {
        image.setPixelRgb(x, y, 139, 90, 30); // necrotic brown
      } else {
        image.setPixelRgb(x, y, 60, 140, 60); // healthy green
      }
    }
  }
  return image;
}

void main() {
  test('fully green leaf -> ~0% infection, Mild', () {
    final result = SeverityCalculator.analyze(_leaf(lesionFraction: 0));
    expect(result.infectionPercent, lessThan(1));
    expect(result.category, SeverityCategory.mild);
    expect(result.isReliable, isTrue);
  });

  test('20% brown -> Moderate with ~20% infection', () {
    final result = SeverityCalculator.analyze(_leaf(lesionFraction: 0.20));
    expect(result.infectionPercent, closeTo(20, 3));
    expect(result.category, SeverityCategory.moderate);
  });

  test('half brown -> Severe', () {
    final result = SeverityCalculator.analyze(_leaf(lesionFraction: 0.5));
    expect(result.infectionPercent, closeTo(50, 3));
    expect(result.category, SeverityCategory.severe);
  });

  test('chlorotic yellow counts as lesion tissue', () {
    final image = _leaf(lesionFraction: 0);
    for (var y = 0; y < image.height; y++) {
      for (var x = 0; x < image.width ~/ 4; x++) {
        image.setPixelRgb(x, y, 200, 180, 40); // chlorotic yellow
      }
    }
    final result = SeverityCalculator.analyze(image);
    expect(result.infectionPercent, closeTo(25, 3));
  });

  test('gray background is excluded from the leaf ratio', () {
    // Half the frame neutral gray, half healthy green: infection stays ~0
    // but leaf coverage is only ~50%.
    final image = img.Image(width: 100, height: 100);
    for (var y = 0; y < 100; y++) {
      for (var x = 0; x < 100; x++) {
        if (y < 50) {
          image.setPixelRgb(x, y, 128, 128, 128);
        } else {
          image.setPixelRgb(x, y, 60, 140, 60);
        }
      }
    }
    final result = SeverityCalculator.analyze(image);
    expect(result.infectionPercent, lessThan(1));
    expect(result.leafCoverage, closeTo(0.5, 0.05));
  });

  test('non-leaf frame is flagged unreliable', () {
    final image = img.Image(width: 100, height: 100);
    img.fill(image, color: img.ColorRgb8(120, 120, 120));
    final result = SeverityCalculator.analyze(image);
    expect(result.isReliable, isFalse);
  });

  test('lesion grid localizes the infected region', () {
    // Lesions on the left third: left columns should be hot, right cold.
    final result = SeverityCalculator.analyze(_leaf(lesionFraction: 0.33));
    final grid = result.lesionGrid;
    expect(grid.length, SeverityCalculator.gridSize);
    expect(grid.first.length, SeverityCalculator.gridSize);
    expect(grid[5][0], closeTo(1.0, 0.01)); // fully lesion cell
    expect(grid[5][SeverityCalculator.gridSize - 1], 0); // healthy side
  });

  test('category boundaries: <10 mild, 10-30 moderate, >30 severe', () {
    expect(SeverityCalculator.categorize(9.9), SeverityCategory.mild);
    expect(SeverityCalculator.categorize(10), SeverityCategory.moderate);
    expect(SeverityCalculator.categorize(30), SeverityCategory.moderate);
    expect(SeverityCalculator.categorize(30.1), SeverityCategory.severe);
  });
}
