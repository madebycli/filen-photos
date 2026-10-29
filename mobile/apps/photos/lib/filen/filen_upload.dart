import 'dart:convert';

import 'package:filen_sdk/filen_sdk.dart';
import 'package:logging/logging.dart';
import 'package:photos/core/configuration.dart';
import 'package:photos/core/errors.dart';
import 'package:photos/db/files_db.dart';
import 'package:photos/filen/filen_compress.dart';
import 'package:photos/filen/filen_ids.dart';
import 'package:photos/filen/filen_sync.dart';
import 'package:photos/filen/filen_upload_progress.dart';
import 'package:photos/models/file/file.dart';
import 'package:photos/models/metadata/file_magic.dart';
import 'package:photos/module/metadata/exif.dart';
import 'package:photos/module/upload/model/media_upload_data.dart';
import 'package:photos/module/upload/upload_metadata.dart';
import 'package:photos/services/collections_service.dart';

final _logger = Logger('FilenUpload');

/// Uploads the prepared [data] of [file] into the Filen folder that backs [collectionID] and
/// returns the file record the gallery should store.
///
/// Safety rules, because a backup must never lose or silently replace data:
///  * A file that is already in the folder with the same name and size is linked, not uploaded
///    again (reinstall / second device), so no duplicates pile up.
///  * A name that is taken by a different file is never overwritten; the new file gets a free
///    name ("IMG_1 (2).jpg"), because Filen would otherwise replace the existing file.
///
/// Besides the file itself, what Filen cannot hold (hash, GPS position, duration, image size,
/// camera, a preview image) is written to the app's state folder, so other devices and a
/// reinstall get the same information.
Future<EnteFile> filenUploadFile(
  EnteFile file,
  int collectionID,
  MediaUploadData data,
) async {
  final source = data.sourceFile;
  final collection = CollectionsService.instance.getCollectionByID(
    collectionID,
  );
  final parentUuid = collection == null ? null : filenDirUuidOf(collection);
  if (parentUuid == null) {
    throw StateError('Collection $collectionID is not a Filen folder');
  }

  // Edits of an already uploaded file are not pushed to Filen (no in-place update yet); stop
  // the gallery from retrying it forever.
  if (file.uploadedFileID != null) {
    _logger.info(
      'Re-upload of ${file.tag} is not supported, keeping the remote copy',
    );
    file.updationTime = DateTime.now().microsecondsSinceEpoch;
    await FilesDB.instance.update(file);
    return file;
  }

  final exifData = data.derivedMetadata.exifData;
  final exifTime = exifData != null
      ? await tryParseExifDateTime(null, exifData)
      : null;
  file.metadataVersion = EnteFile.kCurrentMetadataVersion;
  final prepared = await prepareUploadMetadata(file, data, exifTime);

  final name = (file.title == null || file.title!.isEmpty)
      ? source.uri.pathSegments.last
      : file.title!;
  final size = await source.length();
  final sync = FilenSyncService.instance;
  final inFolder = sync.filesInFolder(parentUuid);

  FilenFile? remote;
  var uploadedNow = false;
  for (final f in inFolder) {
    if (f.name == name && f.size == size) {
      remote = f;
      break;
    }
  }
  if (remote != null) {
    _logger.info(
      '${file.tag} already on Filen (same name and size), linking instead of uploading',
    );
  } else {
    _logger.info('Uploading ${file.tag}: $size bytes into folder $parentUuid');
    final watch = Stopwatch()..start();
    final created = file.creationTime;
    final modified = file.modificationTime;
    final progressId =
        '${file.generatedID ?? name}-${DateTime.now().microsecondsSinceEpoch}';
    // A dropped connection is retried a few times before the file is given up (the next sync
    // tries again anyway).
    final send = await compressForUpload(source, name);
    try {
      for (var attempt = 1; ; attempt++) {
        FilenUploadProgress.instance.fileStarted(progressId, send.size);
        try {
          remote = await FilenSdk.instance.uploadFile(
            localPath: send.file.path,
            parentUuid: parentUuid,
            name: freeFilenName(send.name, {for (final f in inFolder) f.name}),
            createdMs: created == null ? null : created ~/ 1000,
            modifiedMs: modified == null ? null : modified ~/ 1000,
            id: progressId,
          );
          uploadedNow = true;
          break;
        } on FilenException catch (e) {
          if (e.code == 'STORAGE_FULL') throw StorageLimitExceededError();
          if (e.code != 'NETWORK' || attempt >= 3) rethrow;
          _logger.warning(
            'Upload of ${file.tag} hit a network error, retry $attempt of 2',
          );
          await Future<void>.delayed(Duration(seconds: 2 * attempt));
        } finally {
          FilenUploadProgress.instance.fileEnded(progressId);
        }
      }
    } finally {
      await send.dispose();
    }
    sync.noteUploaded(remote);
    _logger.info('Uploaded ${file.tag} in ${watch.elapsedMilliseconds} ms');
  }

  final remoteFile = EnteFile.from(file)
    ..uploadedFileID = filenUuidToId(remote.uuid)
    ..collectionID = collectionID
    ..ownerID = Configuration.instance.getUserID()
    ..encryptedKey = remote.uuid
    ..keyDecryptionNonce = kFilenKeyMarker
    ..fileSize = remote.size
    ..updationTime = remote.modifiedMs * 1000
    ..addedTime = -1
    ..metadataVersion = EnteFile.kCurrentMetadataVersion;
  if (prepared.publicMetadata.isNotEmpty && remoteFile.pubMmdVersion == 0) {
    remoteFile
      ..pubMmdEncodedJson = jsonEncode(prepared.publicMetadata)
      ..pubMmdVersion = 1
      ..pubMagicMetadata = PubMagicMetadata.fromJson(prepared.publicMetadata);
  }

  final db = FilesDB.instance;
  final known = await db.getUploadedFile(
    remoteFile.uploadedFileID!,
    collectionID,
  );
  if (known != null && known.generatedID != file.generatedID) {
    // The listing already created a row for this Filen file (after a reinstall or on a second
    // device). That row takes over the identity of the local file and the pending local row is
    // dropped, so there is exactly one row per photo and the unique index is never violated.
    remoteFile.generatedID = known.generatedID;
    if (file.generatedID != null) {
      await db.deleteByGeneratedID(file.generatedID!);
    }
  }
  await db.update(remoteFile);

  try {
    await sync.noteUploadedMeta(
      remoteFile,
      remote,
      thumbnail: uploadedNow || known == null ? data.thumbnail : null,
    );
  } catch (e, s) {
    // The photo is safe on Filen; the extras are written again by a later sync.
    _logger.warning('Could not record the details of ${file.tag}', e, s);
  }
  return remoteFile;
}

/// [name], or "name (2).ext", "name (3).ext"... when [taken] already contains it.
String freeFilenName(String name, Set<String> taken) {
  if (!taken.contains(name)) return name;
  final dot = name.lastIndexOf('.');
  final stem = dot > 0 ? name.substring(0, dot) : name;
  final ext = dot > 0 ? name.substring(dot) : '';
  for (var i = 2; ; i++) {
    final candidate = '$stem ($i)$ext';
    if (!taken.contains(candidate)) return candidate;
  }
}
