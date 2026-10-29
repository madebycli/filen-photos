import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// One file of the on-device machine learning data (model or place database).
class AssetSpec {
  const AssetSpec({
    required this.url,
    required this.relativePath,
    required this.size,
    required this.sha256,
  });

  final String url;

  /// Where the file lives below its root (see [FilenAssets]).
  final String relativePath;
  final int size;
  final String sha256;
}

/// Puts the ML models and the place database in the folders the native ML code reads them from.
///
/// The files are public, versioned and verified by SHA-256; they are fetched with plain HTTPS
/// downloads from the same static host the models were published on, no account or server is
/// involved. The native downloader would do the same, but when it cannot reach the host (it uses
/// its own network stack) nothing worked at all, so the app does it itself first. A file that is
/// already present and correct is never downloaded again.
class FilenAssets {
  FilenAssets._();

  static final _logger = Logger('FilenAssets');
  static const _models = 'https://models.ente.com';
  static const _location = 'https://assets.ente.com/location/v2';

  static const faceDetection = AssetSpec(
    url: '$_models/yolov5s_face_640_640_static_b1.onnx',
    relativePath:
        'models/yolov5s_face_640_640_static_b1/yolov5s_face_640_640_static_b1.onnx',
    size: 32355091,
    sha256: 'e047647409403d52696035ecd445792173e50d7fbdcccac97b958a585db9aa3d',
  );
  static const faceEmbedding = AssetSpec(
    url: '$_models/mobilefacenet_portable_static_b1.onnx',
    relativePath:
        'models/mobilefacenet_portable_static_b1/mobilefacenet_portable_static_b1.onnx',
    size: 5278803,
    sha256: '0763fc33f54e138476194da95987e133b3e976075a6b1d3e1b2caedb251b1a36',
  );
  static const clipImage = AssetSpec(
    url: '$_models/mobileclip_s2_image_gelu_opset20.onnx',
    relativePath:
        'models/mobileclip_s2_image_gelu_opset20/mobileclip_s2_image_gelu_opset20.onnx',
    size: 143057352,
    sha256: '205a430af825e501c5138e5bb9abea942482a7a4fd4a680e98e47cf0830dce7e',
  );
  static const clipText = AssetSpec(
    url: '$_models/mobileclip_s2_text_opset18_quant.onnx',
    relativePath:
        'models/mobileclip_s2_text_opset18_quant/mobileclip_s2_text_opset18_quant.onnx',
    size: 67144712,
    sha256: 'd92f33dfcff83077fc2e0d3414250710efbb51795dfd89767bdbefb5fdc47322',
  );
  static const clipVocab = AssetSpec(
    url: '$_models/bpe_simple_vocab_16e6.txt',
    relativePath:
        'models/mobileclip_s2_text_opset18_quant/bpe_simple_vocab_16e6.txt',
    size: 3194984,
    sha256: '67603cfda2e032ad77b5f8808af37789d590db664b26df8705d2bf8b3c553fc8',
  );

  // Text recognition ("copy text from a photo"); the layout is the one the Rust OCR code reads.
  static const ocrDetector = AssetSpec(
    url: '$_models/det_fixed_v1.onnx',
    relativePath: 'models/ppocrv5_det_fixed_v1/det.onnx',
    size: 5548458,
    sha256: 'f655f119225b579fa8c3cbf64f6bb7cf56a26c9dc211706a25234d70a543ec8c',
  );
  static const ocrClassifier = AssetSpec(
    url: '$_models/cls_fixed_v1.onnx',
    relativePath: 'models/ppocrv5_cls_fixed_v1/cls.onnx',
    size: 590475,
    sha256: '378d52a73263828d08d4dda37f1d0aac2e36cbd486fdc6351bf309d515610654',
  );
  static const ocrRecognizer = AssetSpec(
    url: '$_models/rec_fixed_v1.onnx',
    relativePath: 'models/ppocrv5_rec_fixed_v1/rec.onnx',
    size: 17031601,
    sha256: '6dda4c0891af5a70c5b0f618b62588df7f3140616d1c560be5ec6496747b54fd',
  );
  static const ocrDictionary = AssetSpec(
    url: '$_models/PP-OCRv5/ppocrv5_dict.txt',
    relativePath: 'models/ppocrv5_dict/ppocrv5_dict.txt',
    size: 74012,
    sha256: 'd1979e9f794c464c0d2e0b70a7fe14dd978e9dc644c0e71f14158cdf8342af1b',
  );

  static const indexingModels = [faceDetection, faceEmbedding, clipImage];
  static const textModels = [clipText, clipVocab];

  static const locationFiles = [
    AssetSpec(
      url: '$_location/cities.bin',
      relativePath: 'location/v2/cities.bin',
      size: 2809615,
      sha256:
          '898dca892a71fd601ae8e75e5c55fd6d4591e4c98de335d9b33e7f076aa668f5',
    ),
    AssetSpec(
      url: '$_location/urban-centres.bin',
      relativePath: 'location/v2/urban-centres.bin',
      size: 1825064,
      sha256:
          'e981b0383e6502ede56b52d5be96cda66f53d7352492e677d8978467c106dab0',
    ),
    AssetSpec(
      url: '$_location/countries.bin',
      relativePath: 'location/v2/countries.bin',
      size: 2504017,
      sha256:
          '3ead1ef2bb03b4ffa95813df4316cf149d37c82d16a322352bd6e3b19218c796',
    ),
    AssetSpec(
      url: '$_location/disputes.bin',
      relativePath: 'location/v2/disputes.bin',
      size: 61543,
      sha256:
          'c44d0af6ad40a3b195bc10cb87512c16998a20e837af190ff1a46b00170dfd7b',
    ),
  ];

  /// Root of the models: `<app support>/assets/<relativePath>`.
  static Future<String> modelsRoot() async =>
      p.join((await getApplicationSupportDirectory()).path, 'assets');

  /// Root of the place database: `<app support>/<relativePath>`.
  static Future<String> locationRoot() async =>
      (await getApplicationSupportDirectory()).path;

  static Future<void> seedModels({
    bool indexing = true,
    bool text = false,
    void Function(String name, int received, int total)? onProgress,
  }) async {
    final root = await modelsRoot();
    for (final spec in [
      if (indexing) ...indexingModels,
      if (text) ...textModels,
    ]) {
      await ensure(spec, root, onProgress: onProgress);
    }
  }

  /// The text recognition models (about 23 MB, fetched on first use). The detector alone is enough
  /// to outline text; the rest is needed to read it.
  static Future<void> seedOcr({required bool recognizer}) async {
    if (recognizer ? _ocrFullyChecked : _ocrDetectorChecked) return;
    final root = await modelsRoot();
    var ok = true;
    for (final spec in [
      ocrDetector,
      if (recognizer) ...[ocrClassifier, ocrRecognizer, ocrDictionary],
    ]) {
      ok = await ensure(spec, root) && ok;
    }
    // Only a complete, verified set is remembered; a failed fetch is tried again next time.
    if (ok) {
      _ocrDetectorChecked = true;
      if (recognizer) _ocrFullyChecked = true;
    }
  }

  static bool _ocrDetectorChecked = false;
  static bool _ocrFullyChecked = false;

  static Future<void> seedLocation() async {
    final root = await locationRoot();
    for (final spec in locationFiles) {
      await ensure(spec, root);
    }
  }

  /// Makes sure [spec] exists below [root] with the right content. Returns false (after logging)
  /// when the file could not be fetched, so the caller can fall back to the native downloader.
  static Future<bool> ensure(
    AssetSpec spec,
    String root, {
    void Function(String name, int received, int total)? onProgress,
    Dio? dio,
  }) async {
    final dest = File(p.join(root, spec.relativePath));
    try {
      if (await _isValid(dest, spec)) return true;
      await dest.parent.create(recursive: true);
      final part = File('${dest.path}.part');
      if (part.existsSync()) await part.delete();
      final name = p.basename(spec.relativePath);
      _logger.info('Downloading $name (${spec.size} bytes)');
      final watch = Stopwatch()..start();
      await (dio ?? Dio()).download(
        spec.url,
        part.path,
        options: Options(
          receiveTimeout: const Duration(minutes: 5),
          sendTimeout: const Duration(seconds: 30),
        ),
        onReceiveProgress: (received, total) =>
            onProgress?.call(name, received, total <= 0 ? spec.size : total),
      );
      if (!await _isValid(part, spec)) {
        _logger.warning('Downloaded $name does not match its checksum');
        await part.delete();
        return false;
      }
      await part.rename(dest.path);
      _logger.info('Downloaded $name in ${watch.elapsedMilliseconds} ms');
      return true;
    } catch (e, s) {
      _logger.warning('Could not fetch ${spec.relativePath}', e, s);
      return false;
    }
  }

  static Future<bool> _isValid(File f, AssetSpec spec) async {
    if (!f.existsSync() || f.lengthSync() != spec.size) return false;
    final digest = await sha256.bind(f.openRead()).first;
    return digest.toString() == spec.sha256;
  }
}
