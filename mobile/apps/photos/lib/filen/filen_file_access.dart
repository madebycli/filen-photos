import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:filen_sdk/filen_sdk.dart';
import 'package:logging/logging.dart';
import 'package:native_video_editor/native_video_editor.dart';
import 'package:path/path.dart' as p;
import 'package:photos/core/configuration.dart';
import 'package:photos/core/constants.dart';
import 'package:photos/filen/filen_ids.dart';
import 'package:photos/filen/filen_state.dart';
import 'package:photos/models/file/file.dart';
import 'package:photos/models/file/file_type.dart';
import 'package:photos/module/download/thumbnail.dart'
    show compressThumbnailToSizeLimit;
import 'package:uuid/uuid.dart';

final _logger = Logger('FilenFileAccess');

/// Downloads the original of a Filen file into the app's temp directory. The SDK decrypts while
/// streaming; the caller owns (and must delete or move) the returned file.
Future<File> filenDownloadOriginal(EnteFile file) async {
  final uuid = filenUuidOf(file);
  final ext = p.extension(file.title ?? '');
  final dest = File(
    p.join(
      Configuration.instance.getTempDirectory(),
      'filen-${const Uuid().v4()}$ext',
    ),
  );
  final watch = Stopwatch()..start();
  try {
    await FilenSdk.instance.downloadFile(uuid: uuid, destPath: dest.path);
    _logger.info(
      'Downloaded ${file.tag} (${file.fileSize ?? '?'} bytes) in ${watch.elapsedMilliseconds} ms',
    );
  } catch (e) {
    _logger.warning(
      'Download of ${file.tag} failed after ${watch.elapsedMilliseconds} ms: $e',
    );
    if (dest.existsSync()) {
      await dest.delete();
    }
    rethrow;
  }
  return dest;
}

/// A local http address the SDK serves the decrypted video from. The player asks for byte ranges,
/// so only what is watched is fetched and nothing is written to disk - the same
/// "stream, don't keep" behaviour Ente has for videos.
Future<String> filenStreamUrl(EnteFile file) async {
  final url = await FilenSdk.instance.streamUrl(filenUuidOf(file));
  _logger.info('Streaming ${file.tag} (${file.fileSize ?? '?'} bytes)');
  return url;
}

/// The preview of [file], or null when [isCancelled] says nobody wants it any more by the time
/// its turn comes. Like Ente, a preview that scrolled off screen before it started is never
/// fetched, so flinging through a big library does not queue thousands of requests.
Future<Uint8List?> filenThumbnail(
  EnteFile file, {
  bool Function()? isCancelled,
}) async {
  final uuid = filenUuidOf(file);
  final watch = Stopwatch()..start();
  final state = FilenState.instance;
  await state.ensureInitialized();

  // 1. A preview stored on Filen by this or another device: a few KB instead of the original.
  try {
    await state.thumbs.ensureIndexed();
    final stored = await state.thumbs.get(uuid);
    if (stored != null) {
      _logger.fine(
        'Thumbnail ${file.tag}: ${stored.length} bytes from the state folder '
        'in ${watch.elapsedMilliseconds} ms',
      );
      return stored;
    }
  } catch (e, s) {
    _logger.warning('Could not read the stored preview of ${file.tag}', e, s);
  }

  // 2. Make one from the original (needs the file, so it is rate limited) ...
  final data = await _thumbnailLimiter.run(() async {
    if (isCancelled?.call() ?? false) return null;
    return _generateThumbnail(file, uuid);
  });
  if (data == null) {
    _logger.fine('Thumbnail ${file.tag} no longer needed, skipped');
    return null;
  }
  _logger.info(
    'Thumbnail ${file.tag}: ${data.length} bytes generated in ${watch.elapsedMilliseconds} ms',
  );

  // 3. ... and keep it for the next time and for other devices.
  unawaited(
    state.thumbs.put(uuid, data).catchError((Object e, StackTrace s) {
      _logger.warning('Could not store the preview of ${file.tag}', e, s);
    }),
  );
  return data;
}

Future<Uint8List> _generateThumbnail(EnteFile file, String uuid) async {
  if (file.fileType == FileType.video) {
    return _videoThumbnail(file, uuid);
  }
  final fromSdk = await FilenSdk.instance.thumbnail(uuid);
  if (fromSdk != null) {
    return fromSdk;
  }
  _logger.info('SDK has no thumbnail for ${file.tag}, scaling the original');
  final original = await filenDownloadOriginal(file);
  try {
    return await compressThumbnailToSizeLimit(await original.readAsBytes());
  } finally {
    await original.delete();
  }
}

/// First frame of a video, read through the SDK's local streaming server so only the start of
/// the file is fetched.
Future<Uint8List> _videoThumbnail(EnteFile file, String uuid) async {
  final url = await FilenSdk.instance.streamUrl(uuid);
  final out = File(
    p.join(
      Configuration.instance.getTempDirectory(),
      'filen-video-thumb-${const Uuid().v4()}.jpg',
    ),
  );
  try {
    await NativeVideoEditor.extractFrame(
      VideoFrameRequest(
        inputPath: url,
        outputPath: out.path,
        position: Duration.zero,
        maxWidth: thumbnailLargeSize,
        maxHeight: thumbnailLargeSize,
        quality: 80,
      ),
    );
    return await compressThumbnailToSizeLimit(await out.readAsBytes());
  } finally {
    if (out.existsSync()) {
      await out.delete();
    }
  }
}

/// Runs at most [limit] actions at a time.
class _Limiter {
  _Limiter(this.limit);
  final int limit;
  int _running = 0;
  final _waiting = <Completer<void>>[];

  Future<T> run<T>(Future<T> Function() action) async {
    if (_running >= limit) {
      final turn = Completer<void>();
      _waiting.add(turn);
      await turn.future;
    } else {
      _running++;
    }
    try {
      return await action();
    } finally {
      if (_waiting.isNotEmpty) {
        _waiting.removeAt(0).complete();
      } else {
        _running--;
      }
    }
  }
}

final _thumbnailLimiter = _Limiter(3);
