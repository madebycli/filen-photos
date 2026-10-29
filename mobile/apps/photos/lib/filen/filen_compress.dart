import 'dart:io';

import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:photos/service_locator.dart';

/// What actually goes to Filen for a photo: the original, or a smaller JPEG made from it.
class UploadSource {
  UploadSource(this.file, this.name, this.size, {this.temporary = false});

  final File file;
  final String name;
  final int size;
  final bool temporary;

  Future<void> dispose() async {
    if (temporary && await file.exists()) await file.delete();
  }
}

const _compressible = {'jpg', 'jpeg', 'heic', 'heif'};

/// Filen's camera upload option "compress / convert HEIC to JPEG": the photo is re-encoded as JPEG
/// (quality 80) and used only when that is smaller. Metadata (date, location, camera) is kept in
/// the new file. HEIC photos get the extension `.jpg`; everything else is uploaded as it is.
Future<UploadSource> compressForUpload(File original, String name) async {
  final size = await original.length();
  final plain = UploadSource(original, name, size);
  if (!backupSettings.shouldCompressUploads()) return plain;
  final ext = p.extension(name).replaceFirst('.', '').toLowerCase();
  if (!_compressible.contains(ext)) return plain;
  final logger = Logger('FilenCompress');
  final tmpDir = await getTemporaryDirectory();
  final target = p.join(
    tmpDir.path,
    'filen-upload-${DateTime.now().microsecondsSinceEpoch}.jpg',
  );
  try {
    final result = await FlutterImageCompress.compressAndGetFile(
      original.path,
      target,
      quality: 80,
      format: CompressFormat.jpeg,
      keepExif: true,
    );
    if (result == null) return plain;
    final compressed = File(result.path);
    final compressedSize = await compressed.length();
    if (compressedSize <= 0 || compressedSize >= size) {
      await compressed.delete();
      return plain;
    }
    logger.info('Compressed $size -> $compressedSize bytes');
    final newName = ext == 'heic' || ext == 'heif'
        ? '${p.basenameWithoutExtension(name)}.jpg'
        : name;
    return UploadSource(compressed, newName, compressedSize, temporary: true);
  } catch (e, s) {
    // The photo must never be lost over this: upload it as it is.
    logger.warning('Could not compress, uploading the original', e, s);
    final leftover = File(target);
    if (await leftover.exists()) await leftover.delete();
    return plain;
  }
}

/// Whether the local photo [local] is the file [remote] on Filen: same name, or a HEIC photo that
/// went up as JPEG (see [compressForUpload]).
bool sameUploadName(String? local, String remote) {
  if (local == remote) return true;
  if (local == null) return false;
  final ext = p.extension(local).replaceFirst('.', '').toLowerCase();
  return (ext == 'heic' || ext == 'heif') &&
      p.extension(remote).toLowerCase() == '.jpg' &&
      p.basenameWithoutExtension(local) == p.basenameWithoutExtension(remote);
}
