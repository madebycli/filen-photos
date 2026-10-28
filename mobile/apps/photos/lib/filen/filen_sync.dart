import 'package:filen_sdk/filen_sdk.dart';
import 'package:logging/logging.dart';
import 'package:photos/core/configuration.dart';
import 'package:photos/db/files_db.dart';
import 'package:photos/filen/filen_account.dart';
import 'package:photos/filen/filen_ids.dart';
import 'package:photos/filen/filen_media_mapper.dart';
import 'package:photos/models/api/collection/user.dart';
import 'package:photos/models/collection/collection.dart';
import 'package:photos/models/file/file.dart';
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
