import 'dart:io';
import 'dart:typed_data';

import 'package:filen_sdk/filen_sdk.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:photos/core/configuration.dart';
import 'package:photos/filen/filen_ids.dart';
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
  try {
    await FilenSdk.instance.downloadFile(uuid: uuid, destPath: dest.path);
  } catch (e) {
    if (dest.existsSync()) {
      await dest.delete();
    }
    rethrow;
  }
  return dest;
}

/// Thumbnail bytes for the gallery grid. The SDK makes WebP thumbnails from the encrypted
/// stream (embedded previews where possible, so large RAW/HEIC files stay cheap). Types the
/// SDK cannot thumbnail fall back to scaling the downloaded image; videos have no fallback yet.
Future<Uint8List> filenThumbnail(EnteFile file) async {
  final uuid = filenUuidOf(file);
  final fromSdk = await FilenSdk.instance.thumbnail(uuid);
  if (fromSdk != null) return fromSdk;

  if (file.fileType != FileType.image) {
    throw UnsupportedError(
      'No Filen thumbnail for ${file.fileType.name} ${file.tag}',
    );
  }
  _logger.info('SDK has no thumbnail for ${file.tag}, scaling the original');
  final original = await filenDownloadOriginal(file);
  try {
    return await compressThumbnailToSizeLimit(await original.readAsBytes());
  } finally {
    await original.delete();
  }
}
