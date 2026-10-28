import 'package:filen_sdk/filen_sdk.dart';
import 'package:logging/logging.dart';
import 'package:photos/core/configuration.dart';
import 'package:photos/core/event_bus.dart';
import 'package:photos/db/collections_db.dart';
import 'package:photos/db/files_db.dart';
import 'package:photos/events/collection_updated_event.dart';
import 'package:photos/events/files_updated_event.dart';
import 'package:photos/events/local_photos_updated_event.dart';
import 'package:photos/filen/filen_account.dart';
import 'package:photos/filen/filen_ids.dart';
import 'package:photos/filen/filen_media_mapper.dart';
import 'package:photos/gateways/trash/models/trash_item_request.dart';
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
    final watch = Stopwatch()..start();
    final rootUuid = await FilenAccount.instance.photosRootUuid();
    final tree = await FilenSdk.instance.listTree(rootUuid);
    _logger.info(
      'Filen listing: ${tree.dirs.length} folders, ${tree.files.length} files in ${watch.elapsedMilliseconds} ms',
    );
    _tree = tree;
    _rootUuid = rootUuid;
    final owner = User(
      id: Configuration.instance.getUserID()!,
      email: Configuration.instance.getEmail() ?? '',
    );
    // Every sync must re-diff every collection: Filen folders carry no change counter.
    final now = DateTime.now().microsecondsSinceEpoch;
    final current = collectionsFromTree(
      tree,
      rootUuid: rootUuid,
      owner: owner,
      updationTime: now,
    );
    // Folders deleted on Filen disappear here too (only the local mirror is touched).
    final present = {
      filenUuidToId(rootUuid),
      for (final d in tree.dirs) filenUuidToId(d.uuid),
    };
    final vanished = [
      for (final c
          in CollectionsService.instance.collectionIDToCollections.values)
        if (filenDirUuidOf(c) != null &&
            !c.isDeleted &&
            !present.contains(c.id))
          filenDeletedCollection(c, now),
    ];
    return [...current, ...vanished];
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

  /// Moves files to Filen's trash (not permanently deleted). Throws on the first failure, so the
  /// caller only forgets the local rows when everything worked; files already trashed disappear
  /// from the next listing on their own.
  Future<void> trashFiles(List<TrashRequest> requests) async {
    final db = FilesDB.instance;
    for (final r in requests) {
      final row = await db.getUploadedFile(r.fileID, r.collectionID);
      if (row == null || !isFilenFile(row)) {
        _logger.warning(
          'Skipping trash of ${r.fileID}: not a known Filen file',
        );
        continue;
      }
      await FilenSdk.instance.trashFile(filenUuidOf(row));
    }
  }

  /// Moves files between albums (= between Filen folders) and mirrors it in the local database.
  /// Refuses to move onto a name that is already taken in the target folder.
  Future<void> moveFiles(
    List<EnteFile> files, {
    required int toCollectionID,
    required int fromCollectionID,
  }) async {
    final target = CollectionsService.instance.getCollectionByID(
      toCollectionID,
    );
    final targetUuid = target == null ? null : filenDirUuidOf(target);
    if (targetUuid == null) {
      throw StateError('Collection $toCollectionID is not a Filen folder');
    }
    final taken = {for (final f in filesInFolder(targetUuid)) f.name};
    final moved = <EnteFile>[];
    for (final file in files) {
      if (!isFilenFile(file)) continue;
      if (file.title != null && taken.contains(file.title)) {
        throw const FilenException(
          'NAME_TAKEN',
          'A file with this name already exists in the target album',
        );
      }
      await FilenSdk.instance.moveFile(
        uuid: filenUuidOf(file),
        newParentUuid: targetUuid,
      );
      if (file.title != null) taken.add(file.title!);
      moved.add(
        file.copyWith()
          ..generatedID = null
          ..collectionID = toCollectionID,
      );
    }
    final db = FilesDB.instance;
    await db.removeFromCollection(
      fromCollectionID,
      moved.map((f) => f.uploadedFileID!).toList(),
    );
    Bus.instance.fire(
      CollectionUpdatedEvent(
        fromCollectionID,
        moved,
        'moveFrom',
        type: EventType.deletedFromRemote,
      ),
    );
    await db.insertMultiple(moved);
    Bus.instance.fire(CollectionUpdatedEvent(toCollectionID, moved, 'moveTo'));
    Bus.instance.fire(LocalPhotosUpdatedEvent(moved, source: 'filenMove'));
  }

  /// "Remove from album" on Filen: the file moves to the library root (Uncategorized).
  Future<void> removeFromAlbum(int collectionID, List<EnteFile> files) async {
    final rootUuid = _rootUuid ?? await FilenAccount.instance.photosRootUuid();
    await moveFiles(
      files,
      toCollectionID: filenUuidToId(rootUuid),
      fromCollectionID: collectionID,
    );
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
