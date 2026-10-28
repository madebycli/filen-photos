import 'dart:io';

import 'package:filen_sdk/filen_sdk.dart';
import 'package:logging/logging.dart';
import 'package:photos/core/configuration.dart';
import 'package:photos/core/errors.dart';
import 'package:photos/db/files_db.dart';
import 'package:photos/filen/filen_ids.dart';
import 'package:photos/filen/filen_sync.dart';
import 'package:photos/models/file/file.dart';
import 'package:photos/services/collections_service.dart';

final _logger = Logger('FilenUpload');

/// Uploads [source] (the readable copy of [file] that Ente prepared) into the Filen folder that
/// backs [collectionID] and returns the file record Ente should store.
///
/// Safety rules, because a backup must never lose or silently replace data:
///  * A file that is already in the folder with the same name and size is linked, not uploaded
///    again (reinstall / second device), so no duplicates pile up.
///  * A name that is taken by a different file is never overwritten; the new file gets a free
///    name ("IMG_1 (2).jpg"), because Filen would otherwise replace the existing file.
Future<EnteFile> filenUploadFile(
  EnteFile file,
  int collectionID,
  File source,
) async {
  final collection = CollectionsService.instance.getCollectionByID(
    collectionID,
  );
  final parentUuid = collection == null ? null : filenDirUuidOf(collection);
  if (parentUuid == null) {
    throw StateError('Collection $collectionID is not a Filen folder');
  }

  // Edits of an already uploaded file are not pushed to Filen (no in-place update yet); stop Ente
  // from retrying it forever.
  if (file.uploadedFileID != null) {
    _logger.info(
      'Re-upload of ${file.tag} is not supported, keeping the remote copy',
    );
    file.updationTime = DateTime.now().microsecondsSinceEpoch;
    await FilesDB.instance.update(file);
    return file;
  }

  final name = (file.title == null || file.title!.isEmpty)
      ? source.uri.pathSegments.last
      : file.title!;
  final size = await source.length();
  final sync = FilenSyncService.instance;
  final inFolder = sync.filesInFolder(parentUuid);

  FilenFile? remote;
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
    try {
      remote = await FilenSdk.instance.uploadFile(
        localPath: source.path,
        parentUuid: parentUuid,
        name: freeFilenName(name, {for (final f in inFolder) f.name}),
        createdMs: created == null ? null : created ~/ 1000,
        modifiedMs: modified == null ? null : modified ~/ 1000,
      );
    } on FilenException catch (e) {
      if (e.code == 'STORAGE_FULL') throw StorageLimitExceededError();
      rethrow;
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
  await FilesDB.instance.update(remoteFile);
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
