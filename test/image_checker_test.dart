import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:cropcure_ai/core/utils/image_checker.dart';

Future<File> _writeImage(String name, img.Image image) async {
  final file = File('${Directory.systemTemp.path}/$name');
  await file.writeAsBytes(img.encodePng(image));
  return file;
}

img.Image _filled(int value) {
  final image = img.Image(width: 256, height: 256);
  img.fill(image, color: img.ColorRgb8(value, value, value));
  return image;
}

void main() {
  test('sharp, well-lit image passes', () async {
    // High-contrast checkerboard: mid brightness, lots of edges.
    final image = img.Image(width: 256, height: 256);
    for (var y = 0; y < 256; y++) {
      for (var x = 0; x < 256; x++) {
        final v = ((x ~/ 8) + (y ~/ 8)).isEven ? 70 : 190;
        image.setPixelRgb(x, y, v, v, v);
      }
    }
    final result = await (await _writeImage(
      'sharp.png',
      image,
    )).validateForInference();
    expect(result.isUsable, isTrue, reason: '$result');
  });

  test('dark image is rejected as too dark', () async {
    final result = await (await _writeImage(
      'dark.png',
      _filled(10),
    )).validateForInference();
    expect(result.isUsable, isFalse);
    expect(result.issues, anyElement(contains('Too dark')));
  });

  test('overexposed image is rejected as too bright', () async {
    final result = await (await _writeImage(
      'bright.png',
      _filled(250),
    )).validateForInference();
    expect(result.isUsable, isFalse);
    expect(result.issues, anyElement(contains('Too bright')));
  });

  test('featureless (blurry) image is rejected', () async {
    final result = await (await _writeImage(
      'flat.png',
      _filled(128),
    )).validateForInference();
    expect(result.isUsable, isFalse);
    expect(result.issues, anyElement(contains('blurry')));
  });
}
