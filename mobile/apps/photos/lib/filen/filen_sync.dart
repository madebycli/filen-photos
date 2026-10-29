import 'dart:typed_data';

import 'package:filen_sdk/filen_sdk.dart';
import 'package:logging/logging.dart';
import 'package:photos/core/configuration.dart';
import 'package:photos/core/event_bus.dart';
import 'package:photos/db/collections_db.dart';
import 'package:photos/db/files_db.dart';
import 'package:photos/db/trash_db.dart';
import 'package:photos/events/collection_updated_event.dart';
import 'package:photos/events/files_updated_event.dart';
import 'package:photos/events/force_reload_home_gallery_event.dart';
import 'package:photos/events/local_photos_updated_event.dart';
import 'package:photos/events/trash_updated_event.dart';
import 'package:photos/filen/filen_account.dart';
import 'package:photos/filen/filen_ids.dart';
import 'package:photos/filen/filen_media_mapper.dart';
import 'package:photos/filen/filen_meta_overlay.dart';
import 'package:photos/filen/filen_state.dart';
import 'package:photos/filen/state/blob_store.dart';
import 'package:photos/filen/state/collection_store.dart';
import 'package:photos/filen/state/meta_store.dart';
import 'package:photos/gateways/trash/models/trash_item_request.dart';
import 'package:photos/models/api/collection/user.dart';
import 'package:photos/models/collection/collection.dart';
import 'package:photos/models/file/file.dart';
import 'package:photos/models/file/trash_file.dart';
import 'package:photos/services/collections_service.dart';
import 'package:photos/services/sync/diff_fetcher.dart';
import 'package:photos/services/sync/trash_sync_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

/// Filen side of Ente's collection/diff sync and of album operations.
///
/// Filen has no "changes since" endpoint, so every sync lists the library tree once; each
/// collection diff then compares that listing, the album membership documents and the stored
/// file metadata with the local database. Albums are the real folders under the photo library
/// plus virtual albums (favorites, user albums) from the state folder, see `state/`.
class FilenSyncService {
  FilenSyncService._();
  static final FilenSyncService instance = FilenSyncService._();

  static final _logger = Logger('FilenSyncService');

  FilenTree? _tree;
  String? _rootUuid;
  Map<String, FilenFile> _filesByUuid = {};
  final Map<int, String> _collectionUuids = {};

  /// Photos of this device that still wait for their upload, per collection; loaded once per
  /// listing and used to recognise photos that are on Filen already.
  Map<int, List<EnteFile>>? _pendingLocals;

  /// False when the state folder could not be read in the current sync: then nothing derived from
  /// it (membership, metadata) may be treated as "gone".
  bool _statePulled = false;

  FilenState get _state => FilenState.instance;

  /// Drops everything remembered from the last listing (logout).
  void reset() {
    _tree = null;
    _rootUuid = null;
    _filesByUuid = {};
    _collectionUuids.clear();
    _statePulled = false;
    _fetching = null;
  }

  User get _owner => User(
    id: Configuration.instance.getUserID()!,
    email: Configuration.instance.getEmail() ?? '',
  );

  Future<List<Collection>>? _fetching;

  /// Collections of the library: root (as Uncategorized), folders and virtual albums.
  /// Concurrent callers share one listing.
  Future<List<Collection>> fetchCollections() {
    return _fetching ??= _fetchCollections().whenComplete(
      () => _fetching = null,
    );
  }

  Future<List<Collection>> _fetchCollections() async {
    final watch = Stopwatch()..start();
    final rootUuid = await FilenAccount.instance.photosRootUuid();
    await _state.ensureInitialized();
    try {
      await _state.pull();
      _statePulled = true;
    } catch (e, s) {
      _statePulled = false;
      _logger.warning(
        'Could not read the Filen state folder, using what is local',
        e,
        s,
      );
    }
    final tree = await FilenSdk.instance.listTree(
      rootUuid,
      skipDirNames: const [kFilenStateDirName],
    );
    _logger.info(
      'Filen listing: ${tree.dirs.length} folders, ${tree.files.length} files '
      'in ${watch.elapsedMilliseconds} ms',
    );
    _tree = tree;
    _pendingLocals = null;
    _rootUuid = rootUuid;
    _filesByUuid = {for (final f in tree.files) f.uuid: f};

    final owner = _owner;
    // Every sync must re-diff every collection: Filen folders carry no change counter.
    final now = DateTime.now().microsecondsSinceEpoch;
    final prefs = await SharedPreferences.getInstance();
    final folders = collectionsFromTree(
      tree,
      rootUuid: rootUuid,
      owner: owner,
      updationTime: now,
      keepEmpty: (prefs.getStringList(_appFoldersKey) ?? const []).toSet(),
    );
    if (_statePulled) {
      for (final c in folders) {
        applyCollectionMeta(c, _state.collections.folderMeta(c.encryptedKey));
      }
    }
    final virtual = _statePulled
        ? [
            for (final v in _state.collections.virtualCollections)
              filenVirtualToCollection(v, owner),
          ]
        : <Collection>[];

    _collectionUuids.clear();
    for (final c in [...folders, ...virtual]) {
      _collectionUuids[c.id] = c.encryptedKey;
    }

    // Collections that were deleted on Filen (or in the app on another device) disappear here too;
    // only the local mirror is touched.
    final present = _collectionUuids.keys.toSet();
    final vanished = [
      for (final c
          in CollectionsService.instance.collectionIDToCollections.values)
        if (filenDirUuidOf(c) != null &&
            !c.isDeleted &&
            !present.contains(c.id))
          // A failed state read must not make albums look deleted.
          if (_statePulled || _isFolder(c)) filenDeletedCollection(c, now),
    ];
    return [...folders, ...virtual, ...vanished];
  }

  /// Folders the app created or picked itself (for a device folder to back up). They show up as
  /// albums even while they hold no photo yet; other folders without photos are not albums.
  static const _appFoldersKey = 'filen_app_folders';

  Future<void> _rememberAppFolder(String uuid) async {
    final prefs = await SharedPreferences.getInstance();
    final known = prefs.getStringList(_appFoldersKey) ?? <String>[];
    if (!known.contains(uuid)) {
      await prefs.setStringList(_appFoldersKey, [...known, uuid]);
    }
  }

  bool _isFolder(Collection c) {
    final uuid = filenDirUuidOf(c);
    return uuid != null &&
        (uuid == _rootUuid ||
            (_tree?.dirs.any((d) => d.uuid == uuid) ?? false));
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
    _filesByUuid[file.uuid] = file;
  }

  /// Album for a device folder (the "backup folder" concept of Ente): a sub-folder of the photo
  /// library with the folder's name, created on Filen when missing.
  Future<Collection> getOrCreateAlbum(String name) async {
    final rootUuid = _rootUuid ?? await FilenAccount.instance.photosRootUuid();
    final tree =
        _tree ??
        await FilenSdk.instance.listTree(
          rootUuid,
          skipDirNames: const [kFilenStateDirName],
        );
    _tree ??= tree;
    _rootUuid ??= rootUuid;
    final clean = name.replaceAll('/', '_').trim();
    final safeName = clean.isEmpty || clean == kFilenStateDirName
        ? 'Unknown Folder'
        : clean;
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
      _logger.info('Created Filen folder "$safeName" for a device folder');
      _tree = FilenTree([
        ...tree.dirs,
        FilenDir(uuid: uuid, parentUuid: rootUuid, name: safeName),
      ], tree.files);
    }
    await _rememberAppFolder(uuid);
    final collection = filenDirToCollection(
      uuid: uuid,
      name: safeName,
      isLibraryRoot: false,
      owner: _owner,
      updationTime: DateTime.now().microsecondsSinceEpoch,
    );
    _collectionUuids[collection.id] = uuid;
    await _cache(collection);
    return collection;
  }

  Future<void> _cache(Collection c) async {
    await CollectionsDB.instance.insert([c]);
    CollectionsService.instance.collectionIDToCollections[c.id] = c;
  }

  // ---- albums -------------------------------------------------------------------------------

  /// A new user album or the favorites collection. They exist only in the state folder.
  Future<Collection> createVirtualCollection({
    required String name,
    required CollectionType type,
    String? magicMetadataJson,
  }) async {
    await _state.ensureInitialized();
    final uuid = const Uuid().v4();
    final kind = type == CollectionType.favorites ? 'favorites' : 'album';
    final meta = magicMetadataJson == null
        ? const CollectionMeta()
        : CollectionMeta(mmd: magicMetadataJson, mv: 1);
    final v = await _state.collections.create(
      uuid: uuid,
      name: name,
      type: kind,
      meta: meta,
    );
    final c = filenVirtualToCollection(v, _owner);
    _collectionUuids[c.id] = uuid;
    await _cache(c);
    _logger.info('Created $kind "$name"');
    return c;
  }

  /// The photo library root as the Uncategorized collection (it always exists).
  Future<Collection> libraryRootCollection() async {
    final rootUuid = _rootUuid ?? await FilenAccount.instance.photosRootUuid();
    final c = filenDirToCollection(
      uuid: rootUuid,
      name: kFilenPhotosRootName,
      isLibraryRoot: true,
      owner: _owner,
      updationTime: DateTime.now().microsecondsSinceEpoch,
    );
    _collectionUuids[c.id] = rootUuid;
    await _cache(c);
    return c;
  }

  /// "Add to album" (and favorites): the photos stay where they are and become members of the
  /// collection. With [updateDb] false only the membership is recorded.
  Future<void> addFiles(
    int collectionID,
    List<EnteFile> files, {
    bool updateDb = true,
  }) async {
    final existing = await FilesDB.instance.getUploadedFileIDs(collectionID);
    final todo = [
      for (final f in files)
        if (isFilenFile(f) &&
            f.uploadedFileID != null &&
            !existing.contains(f.uploadedFileID))
          f,
    ];
    if (todo.isEmpty) return;
    addToCollection(collectionID, todo);
    if (!updateDb) return;
    for (final f in todo) {
      f.generatedID = null; // a new row for this collection
      f.collectionID = collectionID;
    }
    await FilesDB.instance.insertMultiple(todo);
    Bus.instance.fire(CollectionUpdatedEvent(collectionID, todo, 'addTo'));
  }

  /// Queues the magic metadata of [file] (archive/hide/caption/date/location edits) for the cloud.
  void noteFileMeta(EnteFile file) {
    if (!isFilenFile(file)) return;
    _state.meta.queue(filenUuidOf(file), metaEntryOf(file));
  }

  /// Renames a folder album on Filen or a virtual album in the state folder.
  Future<void> renameCollection(Collection c, String name) async {
    final uuid = filenDirUuidOf(c)!;
    if (_state.collections.virtualCollection(uuid) != null) {
      await _state.collections.rename(uuid, name);
    } else if (uuid == _rootUuid) {
      throw StateError('The library root cannot be renamed');
    } else {
      await FilenSdk.instance.renameDir(uuid: uuid, name: name);
    }
  }

  /// Deletes a virtual album (the photos stay) or trashes a folder album on Filen.
  /// A folder that still holds photos goes to Filen's trash *with* them, but only when
  /// [withFiles] is set.
  Future<void> deleteCollection(Collection c, {required bool withFiles}) async {
    final uuid = filenDirUuidOf(c)!;
    if (_state.collections.virtualCollection(uuid) != null) {
      if (withFiles) {
        // "Delete album and photos": the member photos go to Filen's trash.
        for (final m in _state.collections.membersOf(uuid)) {
          await FilenSdk.instance.trashFile(m);
        }
      }
      await _state.collections.delete(uuid);
      return;
    }
    if (uuid == _rootUuid) {
      throw StateError('The library root cannot be deleted');
    }
    if (!withFiles && filesInFolder(uuid).isNotEmpty) {
      throw StateError('Album is not empty');
    }
    await FilenSdk.instance.trashDir(uuid);
  }

  /// Persists collection settings (visibility/pin/sort/cover). Folders and virtual albums share
  /// the mechanism.
  Future<void> updateCollectionMeta(
    Collection c, {
    String? mmd,
    int mv = 0,
    String? pub,
    int pv = 0,
  }) async {
    await _state.collections.updateMeta(
      filenDirUuidOf(c)!,
      CollectionMeta(mmd: mmd, mv: mv, pub: pub, pv: pv),
    );
  }

  // ---- membership ---------------------------------------------------------------------------

  /// Adds photos to an album without moving them (how favorites and "add to album" work).
  void addToCollection(int collectionID, Iterable<EnteFile> files) {
    final uuid =
        _collectionUuids[collectionID] ??
        filenDirUuidOf(
          CollectionsService.instance.getCollectionByID(collectionID)!,
        );
    if (uuid == null) {
      throw StateError('Collection $collectionID is not a Filen album');
    }
    final fileUuids = [
      for (final f in files)
        if (isFilenFile(f)) filenUuidOf(f),
    ];
    _state.collections.addMembers(uuid, fileUuids);
  }

  void removeMembership(int collectionID, Iterable<EnteFile> files) {
    final uuid =
        _collectionUuids[collectionID] ??
        filenDirUuidOf(
          CollectionsService.instance.getCollectionByID(collectionID)!,
        );
    if (uuid == null) {
      throw StateError('Collection $collectionID is not a Filen album');
    }
    _state.collections.removeMembers(uuid, [
      for (final f in files)
        if (isFilenFile(f)) filenUuidOf(f),
    ]);
  }

  /// Whether [file] physically lives in the folder behind [collectionID].
  bool isHomeOf(int collectionID, EnteFile file) {
    final home = _filesByUuid[filenUuidOf(file)]?.parentUuid;
    return home != null && home == _collectionUuids[collectionID];
  }

  // ---- file operations ------------------------------------------------------------------------

  /// Moves files to Filen's trash (not permanently deleted). Throws on the first failure, so the
  /// caller only forgets the local rows when everything worked; files already trashed disappear
  /// from the next listing on their own.
  Future<void> trashFiles(List<TrashRequest> requests) async {
    final db = FilesDB.instance;
    for (final r in requests) {
      // The row of the album the user looked at, else any row of the same photo (a photo can be
      // listed in several albums).
      final row =
          await db.getUploadedFile(r.fileID, r.collectionID) ??
          await db.getAnyUploadedFile(r.fileID);
      if (row == null || !isFilenFile(row)) {
        // Never pretend: the caller would forget the local rows and the photo would come back.
        throw StateError(
          'Cannot move ${r.fileID} to the Filen trash: not a known Filen file',
        );
      }
      final uuid = filenUuidOf(row);
      try {
        await FilenSdk.instance.trashFile(uuid);
      } on FilenException catch (e) {
        // Already gone from the drive (trashed elsewhere): that is what the user wanted.
        if (e.code != 'NOT_FOUND') rethrow;
        _logger.info('${row.tag} was already gone from Filen');
      }
      _logger.info('Trashed ${row.tag} on Filen');
    }
  }

  /// "Move to album": from the album's point of view the photo leaves [fromCollectionID] and joins
  /// [toCollectionID]. Between two folders that is a real move on Filen; whenever a virtual album
  /// is involved only the membership changes and the photo stays where it is physically.
  Future<void> moveFiles(
    List<EnteFile> files, {
    required int toCollectionID,
    required int fromCollectionID,
  }) async {
    final toUuid = _collectionUuids[toCollectionID];
    if (toUuid == null) {
      throw StateError('Collection $toCollectionID is not a Filen album');
    }
    final toIsFolder = _state.collections.virtualCollection(toUuid) == null;
    final taken = toIsFolder
        ? {for (final f in filesInFolder(toUuid)) f.name}
        : <String>{};
    final moved = <EnteFile>[];
    for (final file in files) {
      if (!isFilenFile(file)) continue;
      if (toIsFolder && isHomeOf(fromCollectionID, file)) {
        if (file.title != null && taken.contains(file.title)) {
          throw const FilenException(
            'NAME_TAKEN',
            'A file with this name already exists in the target album',
          );
        }
        await FilenSdk.instance.moveFile(
          uuid: filenUuidOf(file),
          newParentUuid: toUuid,
        );
        if (file.title != null) taken.add(file.title!);
        _updateTreeAfterMove(filenUuidOf(file), toUuid);
      } else {
        // Membership only. A photo whose home is the source folder cannot leave it without being
        // moved, so it is moved to the library root first.
        if (isHomeOf(fromCollectionID, file)) {
          await FilenSdk.instance.moveFile(
            uuid: filenUuidOf(file),
            newParentUuid: _rootUuid!,
          );
          _updateTreeAfterMove(filenUuidOf(file), _rootUuid!);
        } else {
          removeMembership(fromCollectionID, [file]);
        }
        if (!isHomeOf(toCollectionID, file)) {
          addToCollection(toCollectionID, [file]);
        }
      }
      moved.add(
        file.copyWith()
          ..generatedID = null
          ..collectionID = toCollectionID,
      );
    }
    await _applyMoveLocally(moved, fromCollectionID, toCollectionID);
  }

  void _updateTreeAfterMove(String fileUuid, String newParentUuid) {
    final tree = _tree;
    final f = _filesByUuid[fileUuid];
    if (tree == null || f == null) return;
    final moved = FilenFile(
      uuid: f.uuid,
      parentUuid: newParentUuid,
      name: f.name,
      mime: f.mime,
      size: f.size,
      createdMs: f.createdMs,
      modifiedMs: f.modifiedMs,
      canMakeThumbnail: f.canMakeThumbnail,
    );
    _filesByUuid[fileUuid] = moved;
    _tree = FilenTree(tree.dirs, [
      for (final x in tree.files) x.uuid == fileUuid ? moved : x,
    ]);
  }

  Future<void> _applyMoveLocally(List<EnteFile> moved, int from, int to) async {
    final db = FilesDB.instance;
    await db.removeFromCollection(
      from,
      moved.map((f) => f.uploadedFileID!).toList(),
    );
    Bus.instance.fire(
      CollectionUpdatedEvent(
        from,
        moved,
        'moveFrom',
        type: EventType.deletedFromRemote,
      ),
    );
    await db.insertMultiple(moved);
    Bus.instance.fire(CollectionUpdatedEvent(to, moved, 'moveTo'));
    Bus.instance.fire(LocalPhotosUpdatedEvent(moved, source: 'filenMove'));
  }

  /// "Remove from album": a membership is dropped; a photo that lives in the folder moves to the
  /// library root (Uncategorized) so it is never lost from view.
  Future<void> removeFromAlbum(int collectionID, List<EnteFile> files) async {
    final rootUuid = _rootUuid ?? await FilenAccount.instance.photosRootUuid();
    final home = [
      for (final f in files)
        if (isFilenFile(f) && isHomeOf(collectionID, f)) f,
    ];
    final extra = [
      for (final f in files)
        if (isFilenFile(f) && !isHomeOf(collectionID, f)) f,
    ];
    if (extra.isNotEmpty) removeMembership(collectionID, extra);
    if (home.isNotEmpty) {
      await moveFiles(
        home,
        toCollectionID: filenUuidToId(rootUuid),
        fromCollectionID: collectionID,
      );
    }
  }

  // ---- diff -----------------------------------------------------------------------------------

  /// Files of [collectionID] as seen on Filen right now, plus the ones that vanished. Only rows that
  /// differ from the local database are returned, so an unchanged library costs one query per
  /// collection and no gallery refresh. Nothing is declared gone unless the listing succeeded.
  Future<Diff> getDiff(int collectionID) async {
    final tree = _tree;
    final rootUuid = _rootUuid;
    if (tree == null || rootUuid == null) {
      throw StateError(
        'Filen listing missing; collections must be fetched first',
      );
    }
    final uuid = _collectionUuids[collectionID];
    if (uuid == null) {
      // A collection the listing no longer knows (deleted); its rows are cleaned up elsewhere.
      return Diff([], [], false, DateTime.now().microsecondsSinceEpoch);
    }
    final ownerID = Configuration.instance.getUserID()!;
    final existingRows = {
      for (final r in await FilesDB.instance.getAllFilesCollection(
        collectionID,
      ))
        if (r.uploadedFileID != null) r.uploadedFileID!: r,
    };
    final isVirtual = _state.collections.virtualCollection(uuid) != null;

    final candidates = <String, FilenFile>{};
    if (!isVirtual) {
      for (final f in tree.files) {
        if (f.parentUuid == uuid) {
          candidates[f.uuid] = f;
        }
      }
    }
    if (_statePulled) {
      for (final m in _state.collections.membersOf(uuid)) {
        final f = _filesByUuid[m];
        if (f != null) {
          candidates[m] = f;
        }
      }
    }

    final updated = <EnteFile>[];
    final seen = <int>{};
    var queuedForUpload = 0;
    var linkedToLocal = 0;
    for (final f in candidates.values) {
      final id = filenUuidToId(f.uuid);
      final existing = existingRows[id];
      final mapped = filenFileToEnteFile(
        f,
        collectionID: collectionID,
        ownerID: ownerID,
        existingGeneratedID: existing?.generatedID,
      );
      if (mapped == null) {
        continue;
      }
      // A photo of this device that was backed up before (reinstall, second sign-in) must not
      // show up a second time: the Filen file takes over the local row.
      final EnteFile? local = existing == null
          ? await _takeLocalMatch(collectionID, f, mapped)
          : null;
      if (local != null) {
        mapped.localID = local.localID;
        mapped.deviceFolder = local.deviceFolder;
        linkedToLocal++;
      }
      if (_statePulled) {
        final rec = reconcileMeta(
          local: existing != null
              ? metaEntryOf(existing)
              : (local != null ? metaEntryOf(local) : const FileMetaEntry()),
          cloud: _state.meta.effective(f.uuid),
        );
        applyMetaEntry(mapped, rec.entry);
        if (rec.uploadNeeded) {
          _state.meta.queue(f.uuid, rec.entry);
          queuedForUpload++;
        }
      } else if (existing != null) {
        applyMetaEntry(mapped, metaEntryOf(existing));
      }
      seen.add(id);
      if (existing == null || !filenRowUnchanged(existing, mapped)) {
        updated.add(mapped);
      }
    }

    final deleted = _statePulled || !isVirtual
        ? <EnteFile>[
            for (final id in existingRows.keys)
              if (!seen.contains(id))
                EnteFile()
                  ..uploadedFileID = id
                  ..collectionID = collectionID,
          ]
        : <EnteFile>[];
    if (updated.isNotEmpty || deleted.isNotEmpty || queuedForUpload > 0) {
      _logger.info(
        '[Collection-$collectionID] ${candidates.length} files on Filen, '
        '${updated.length} new or changed, ${deleted.length} gone'
        '${linkedToLocal > 0 ? ', $linkedToLocal matched to photos of this device' : ''}'
        '${queuedForUpload > 0 ? ', $queuedForUpload metadata records queued for the cloud' : ''}',
      );
    }
    return Diff(updated, deleted, false, DateTime.now().microsecondsSinceEpoch);
  }

  // ---- trash --------------------------------------------------------------------------------

  /// Photos and videos in Filen's trash as Ente trash entries. Filen has no "changes since" for
  /// its trash, so the whole (top level) trash is compared with the local trash table. Anything
  /// that is not a photo or video is ignored and never touched.
  Future<TrashDiff> trashDiff() async {
    final items = await FilenSdk.instance.listTrash();
    final ownerID = Configuration.instance.getUserID()!;
    final current = <int, EnteTrashFile>{};
    for (final f in items) {
      final mapped = filenFileToEnteFile(f, collectionID: -1, ownerID: ownerID);
      if (mapped == null) {
        continue;
      }
      // The trash table needs a collection id; Filen does not say which album a photo came from.
      mapped.collectionID = -1;
      final trashedAt = f.modifiedMs * 1000;
      current[mapped.uploadedFileID!] = EnteTrashFile.from(
        mapped,
        deleteBy: kFilenTrashKeepsForever,
        createdAt: trashedAt,
        updateAt: trashedAt,
      );
    }
    final local = await TrashDB.instance.getTrashedFiles(0, 1 << 62);
    final localIDs = {for (final t in local.files) t.uploadedFileID!};
    return TrashDiff(
      [
        for (final e in current.entries)
          if (!localIDs.contains(e.key)) e.value,
      ],
      const [],
      [
        for (final id in localIDs)
          if (!current.containsKey(id)) id,
      ],
      false,
      DateTime.now().microsecondsSinceEpoch,
    );
  }

  /// Permanently deletes the given photos from Filen's trash (the user confirmed in the trash page).
  /// Other things in the Filen trash are never touched.
  Future<void> deleteFromTrash(List<EnteTrashFile> files) async {
    for (final f in files) {
      await FilenSdk.instance.deleteFilePermanently(filenUuidOf(f));
    }
    await TrashDB.instance.delete([for (final f in files) f.uploadedFileID!]);
    Bus.instance.fire(TrashUpdatedEvent());
  }

  /// Puts photos back from the trash into [toCollectionID]: into that folder, or, for a virtual
  /// album, as members while the file returns to its old folder.
  Future<void> restoreFromTrash(
    int toCollectionID,
    List<EnteFile> files,
  ) async {
    final toUuid = _collectionUuids[toCollectionID];
    if (toUuid == null) {
      throw StateError('Collection $toCollectionID is not a Filen album');
    }
    final toIsFolder = _state.collections.virtualCollection(toUuid) == null;
    final restored = <EnteFile>[];
    for (final file in files) {
      if (!isFilenFile(file)) {
        continue;
      }
      final uuid = filenUuidOf(file);
      await FilenSdk.instance.restoreFile(uuid);
      if (toIsFolder) {
        await FilenSdk.instance.moveFile(uuid: uuid, newParentUuid: toUuid);
      } else {
        _state.collections.addMembers(toUuid, [uuid]);
      }
      restored.add(file);
    }
    for (final f in restored) {
      f.generatedID = null;
      f.collectionID = toCollectionID;
    }
    await FilesDB.instance.insertMultiple(restored);
    await TrashDB.instance.delete([
      for (final f in restored) f.uploadedFileID!,
    ]);
    Bus.instance.fire(
      CollectionUpdatedEvent(toCollectionID, restored, 'restore'),
    );
    Bus.instance.fire(FilesUpdatedEvent(restored, source: 'restore'));
    Bus.instance.fire(TrashUpdatedEvent());
    Bus.instance.fire(ForceReloadHomeGalleryEvent('restoredFromTrash'));
  }

  /// The not yet uploaded row of this device that is the same photo as [remote]: same name, same
  /// capture time. Each row is handed out once.
  Future<EnteFile?> _takeLocalMatch(
    int collectionID,
    FilenFile remote,
    EnteFile mapped,
  ) async {
    var byCollection = _pendingLocals;
    if (byCollection == null) {
      byCollection = {};
      for (final row in await FilesDB.instance.getFilesPendingForUpload()) {
        (byCollection[row.collectionID!] ??= []).add(row);
      }
      _pendingLocals = byCollection;
    }
    final rows = byCollection[collectionID];
    if (rows == null) return null;
    final createdMs = remote.createdMs ?? remote.modifiedMs;
    for (var i = 0; i < rows.length; i++) {
      final row = rows[i];
      if (row.title != remote.name || row.fileType != mapped.fileType) {
        continue;
      }
      final rowMs = (row.creationTime ?? 0) ~/ 1000;
      if ((rowMs - createdMs).abs() > 2000) continue;
      rows.removeAt(i);
      return row;
    }
    return null;
  }

  /// Records what only this device knows about a file it just uploaded (hash, GPS, duration...).
  Future<void> noteUploadedMeta(
    EnteFile uploaded,
    FilenFile remote, {
    Uint8List? thumbnail,
  }) async {
    await _state.ensureInitialized();
    _state.meta.queue(remote.uuid, metaEntryOf(uploaded));
    if (thumbnail != null && thumbnail.isNotEmpty) {
      await _state.thumbs.ensureIndexed();
      await _state.thumbs.put(remote.uuid, thumbnail);
    }
  }
}

/// Pure tree -> collections mapping (unit tested).
List<Collection> collectionsFromTree(
  FilenTree tree, {
  required String rootUuid,
  required User owner,
  required int updationTime,
  Set<String> keepEmpty = const {},
}) {
  // Only folders that hold photos or videos are albums; the rest of a drive tree (folders for
  // metadata, app files, or only sub-folders) is not shown.
  final withMedia = {
    for (final f in tree.files)
      if (filenFileType(f.mime, f.name) != null) f.parentUuid,
  };
  return [
    filenDirToCollection(
      uuid: rootUuid,
      name: kFilenPhotosRootName,
      isLibraryRoot: true,
      owner: owner,
      updationTime: updationTime,
    ),
    for (final d in tree.dirs)
      if (d.name != null &&
          d.name != kFilenStateDirName &&
          (withMedia.contains(d.uuid) || keepEmpty.contains(d.uuid)))
        filenDirToCollection(
          uuid: d.uuid,
          name: d.name!,
          isLibraryRoot: false,
          owner: owner,
          updationTime: updationTime,
        ),
  ];
}
