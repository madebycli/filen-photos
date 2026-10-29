import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:photos/filen/filen_assets.dart';

/// The app fetches the text recognition models itself; the files must be exactly the ones the Rust
/// OCR code looks for, or it would download them again (or fail) on its own.
void main() {
  final source = File(
    '../../../rust/crates/ml/src/ocr/assets.rs',
  ).readAsStringSync();

  for (final entry in {
    'det.onnx': FilenAssets.ocrDetector,
    'cls.onnx': FilenAssets.ocrClassifier,
    'rec.onnx': FilenAssets.ocrRecognizer,
    'ppocrv5_dict.txt': FilenAssets.ocrDictionary,
  }.entries) {
    test('${entry.key} matches the Rust OCR catalog', () {
      final spec = entry.value;
      final block = RegExp(
        'key: "([^"]+)",\\s*name: "${RegExp.escape(entry.key)}",\\s*'
        'url: "([^"]+)",\\s*size: ([0-9_]+),\\s*sha256: "([0-9a-f]+)"',
      ).firstMatch(source);
      expect(block, isNotNull);
      expect(spec.relativePath, 'models/${block!.group(1)}/${entry.key}');
      expect(spec.url, block.group(2));
      expect(spec.size, int.parse(block.group(3)!.replaceAll('_', '')));
      expect(spec.sha256, block.group(4));
    });
  }
}
