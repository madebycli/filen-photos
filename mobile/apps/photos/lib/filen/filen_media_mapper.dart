import 'package:filen_sdk/filen_sdk.dart';
import 'package:photos/filen/filen_ids.dart';
import 'package:photos/models/api/collection/user.dart';
import 'package:photos/models/collection/collection.dart';
import 'package:photos/models/file/file.dart';
import 'package:photos/models/file/file_type.dart';

const _imageExtensions = {
  'jpg',
  'jpeg',
  'png',
  'gif',
  'webp',
  'bmp',
  'heic',
  'heif',
  'avif',
  'tif',
  'tiff',
  'dng',
  'cr2',
  'cr3',
  'nef',
  'arw',
  'orf',
  'rw2',
  'raf',
  'jfif',
};
const _videoExtensions = {
  'mp4',
  'mov',
  'm4v',
  'mkv',
  'webm',
  '3gp',
  'avi',
  'mts',
  'm2ts',
};

/// Photos/videos only: Filen drives hold arbitrary files, the gallery must not.
/// Returns null for everything else. The extension is consulted when the stored mime is
/// generic, because mime types are written once by whichever client uploaded the file.
FileType? filenFileType(String mime, String name) {
  final m = mime.toLowerCase();
  if (m.startsWith('image/')) return FileType.image;
  if (m.startsWith('video/')) return FileType.video;
  final dot = name.lastIndexOf('.');
  if (dot < 0 || dot == name.length - 1) return null;
  final ext = name.substring(dot + 1).toLowerCase();
  if (_imageExtensions.contains(ext)) return FileType.image;
  if (_videoExtensions.contains(ext)) return FileType.video;
  return null;
}

/// Maps a Filen file to Ente's gallery model, or null if it is not a photo/video.
/// [existingGeneratedID] keeps the row identity of an already synced file.
EnteFile? filenFileToEnteFile(
  FilenFile f, {
  required int collectionID,
  required int ownerID,
  int? existingGeneratedID,
}) {
  final type = filenFileType(f.mime, f.name);
  if (type == null) return null;
  final modifiedMicros = f.modifiedMs * 1000;
  final createdMicros = (f.createdMs ?? f.modifiedMs) * 1000;
  return EnteFile()
    ..generatedID = existingGeneratedID
    ..uploadedFileID = filenUuidToId(f.uuid)
    ..collectionID = collectionID
    ..ownerID = ownerID
    ..title = f.name
    ..fileType = type
    ..creationTime = createdMicros
    ..modificationTime = modifiedMicros
    ..updationTime = modifiedMicros
    // -1 marks "not added by someone else", as Ente does for own files.
    ..addedTime = -1
    ..fileSize = f.size
    ..duration = 0
    ..metadataVersion = EnteFile.kCurrentMetadataVersion
    ..encryptedKey = f.uuid
    ..keyDecryptionNonce = kFilenKeyMarker;
}

/// The tombstone Ente's collection sync expects for a collection that no longer exists.
Collection filenDeletedCollection(Collection gone, int updationTime) {
  final c = Collection(
    gone.id,
    gone.owner,
    gone.encryptedKey,
    gone.keyDecryptionNonce,
    gone.displayName,
    null,
    null,
    gone.type,
    CollectionAttributes(),
    [],
    [],
    updationTime,
    isDeleted: true,
  );
  c.setName(gone.displayName);
  return c;
}

/// A Filen folder as an Ente collection. The photo library root becomes the "Uncategorized"
/// collection (files directly in it), every sub-folder an album. The folder's UUID is kept in
/// [Collection.encryptedKey] and tagged with [kFilenKeyMarker], mirroring what is done for files.
Collection filenDirToCollection({
  required String uuid,
  required String name,
  required bool isLibraryRoot,
  required User owner,
  required int updationTime,
}) {
  final c = Collection(
    filenUuidToId(uuid),
    owner,
    uuid,
    kFilenKeyMarker,
    name,
    null,
    null,
    isLibraryRoot ? CollectionType.uncategorized : CollectionType.album,
    CollectionAttributes(),
    [],
    [],
    updationTime,
  );
  c.setName(name);
  return c;
}
