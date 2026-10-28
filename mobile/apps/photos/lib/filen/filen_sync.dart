import 'package:filen_sdk/filen_sdk.dart';
import 'package:logging/logging.dart';
import 'package:photos/core/configuration.dart';
import 'package:photos/db/collections_db.dart';
import 'package:photos/db/files_db.dart';
import 'package:photos/filen/filen_account.dart';
import 'package:photos/filen/filen_ids.dart';
import 'package:photos/filen/filen_media_mapper.dart';
import 'package:photos/models/api/collection/user.dart';
import 'package:photos/models/collection/collection.dart';
import 'package:photos/models/file/file.dart';
import 'package:photos/services/collections_service.dart';
import 'package:photos/services/sync/diff_fetcher.dart';

/// Read side of the Filen backend, plugged into Ente's collection/diff sync at two seams
/// (`CollectionsService._fetchCollections` and `DiffFetcher.getEncryptedFilesDiff`).
///
/// Filen has no "changes since" endpoint, so every sync lists the library tree once and each
/// collection diff compares that listing with the local database.
class FilenSyncService {
  FilenSyncService._();
  static final FilenSyncService instance = FilenSyncService._();

  static final _logger = Logger('FilenSyncService');

  FilenTree? _tree;
  String? _rootUuid;

  /// Albums of the library: the root (as Uncategorized) and every sub-folder.
  Future<List<Collection>> fetchCollections() async {
    final rootUuid = await FilenAccount.instance.photosRootUuid();
    final tree = await FilenSdk.instance.listTree(rootUuid);
    _tree = tree;
    _rootUuid = rootUuid;
    return collectionsFromTree(
      tree,
      rootUuid: rootUuid,
      owner: User(
        id: Configuration.instance.getUserID()!,
        email: Configuration.instance.getEmail() ?? '',
      ),
      // Every sync must re-diff every collection: Filen folders carry no change counter.
      updationTime: DateTime.now().microsecondsSinceEpoch,
    );
  }

  /// Files directly in a Filen folder, from the most recent listing (plus this session's uploads).
  List<FilenFile> filesInFolder(String folderUuid) {
    final tree = _tree;
    if (tree == null) return const [];
    return [
      for (final f in tree.files)
        if (f.parentUuid == folderUuid) f,
    ];
  }

  /// Makes an upload visible to name/size checks of later uploads in the same sync.
  void noteUploaded(FilenFile file) {
    final tree = _tree;
    if (tree == null) return;
    _tree = FilenTree(tree.dirs, [...tree.files, file]);
  }

  /// Album for a device folder (the "backup folder" concept of Ente): a sub-folder of the photo
  /// library with the folder's name, created on Filen when missing.
  Future<Collection> getOrCreateAlbum(String name) async {
    final rootUuid = _rootUuid ?? await FilenAccount.instance.photosRootUuid();
    final tree = _tree ?? await FilenSdk.instance.listTree(rootUuid);
    _tree ??= tree;
    _rootUuid ??= rootUuid;
    final clean = name.replaceAll('/', '_').trim();
    final safeName = clean.isEmpty ? 'Unknown Folder' : clean;
    FilenDir? dir;
    for (final d in tree.dirs) {
      if (d.parentUuid == rootUuid && d.name == safeName) {
        dir = d;
        break;
      }
    }
    final String uuid;
    if (dir != null) {
      uuid = dir.uuid;
    } else {
      uuid = await FilenSdk.instance.createDir(
        parentUuid: rootUuid,
        name: safeName,
      );
      _tree = FilenTree([
        ...tree.dirs,
        FilenDir(uuid: uuid, parentUuid: rootUuid, name: safeName),
      ], tree.files);
    }
    final collection = filenDirToCollection(
      uuid: uuid,
      name: safeName,
      isLibraryRoot: false,
      owner: User(
        id: Configuration.instance.getUserID()!,
        email: Configuration.instance.getEmail() ?? '',
      ),
      updationTime: DateTime.now().microsecondsSinceEpoch,
    );
    await CollectionsDB.instance.insert([collection]);
    CollectionsService.instance.collectionIDToCollections[collection.id] =
        collection;
    return collection;
  }

  /// Files of [collectionID] as seen on Filen right now, plus the ones that vanished.
  /// Never touches the database for deletions unless the listing itself succeeded.
  Future<Diff> getDiff(int collectionID) async {
    final tree = _tree;
    final rootUuid = _rootUuid;
    if (tree == null || rootUuid == null) {
      throw StateError(
        'Filen listing missing; collections must be fetched first',
      );
    }
    final ownerID = Configuration.instance.getUserID()!;
    final db = FilesDB.instance;
    final existingIDs = await db.getUploadedFileIDs(collectionID);

    final updated = <EnteFile>[];
    final seen = <int>{};
    for (final f in tree.files) {
      if (filenUuidToId(f.parentUuid) != collectionID) continue;
      final id = filenUuidToId(f.uuid);
      final existing = existingIDs.contains(id)
          ? await db.getUploadedFile(id, collectionID)
          : null;
      final mapped = filenFileToEnteFile(
        f,
        collectionID: collectionID,
        ownerID: ownerID,
        existingGeneratedID: existing?.generatedID,
      );
      if (mapped == null) continue;
      seen.add(id);
      updated.add(mapped);
    }

    final deleted = <EnteFile>[
      for (final id in existingIDs.difference(seen))
        EnteFile()
          ..uploadedFileID = id
          ..collectionID = collectionID,
    ];
    _logger.info(
      '[Collection-$collectionID] ${updated.length} files on Filen, '
      '${deleted.length} gone',
    );
    return Diff(updated, deleted, false, DateTime.now().microsecondsSinceEpoch);
  }
}

/// Pure tree -> collections mapping (unit tested).
List<Collection> collectionsFromTree(
  FilenTree tree, {
  required String rootUuid,
  required User owner,
  required int updationTime,
}) {
  return [
    filenDirToCollection(
      uuid: rootUuid,
      name: kFilenPhotosRootName,
      isLibraryRoot: true,
      owner: owner,
      updationTime: updationTime,
    ),
    for (final d in tree.dirs)
      if (d.name != null)
        filenDirToCollection(
          uuid: d.uuid,
          name: d.name!,
          isLibraryRoot: false,
          owner: owner,
          updationTime: updationTime,
        ),
  ];
}
