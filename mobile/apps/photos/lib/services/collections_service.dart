import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:collection/collection.dart';
import 'package:ente_pure_utils/ente_pure_utils.dart';
import "package:fast_base58/fast_base58.dart";
import 'package:flutter/foundation.dart';
import "package:flutter/material.dart";
import 'package:logging/logging.dart';
import 'package:photos/core/configuration.dart';
import 'package:photos/core/constants.dart';
import 'package:photos/core/event_bus.dart';
import 'package:photos/db/collections_db.dart';
import 'package:photos/db/device_files_db.dart';
import 'package:photos/db/files_db.dart';
import 'package:photos/events/collection_updated_event.dart';
import 'package:photos/events/files_updated_event.dart';
import 'package:photos/events/local_photos_updated_event.dart';
import 'package:photos/filen/filen_sync.dart';
import 'package:photos/models/collection/collection.dart';
import 'package:photos/models/file/file.dart';
import "package:photos/models/metadata/collection_magic.dart";
import "package:photos/service_locator.dart";
import "package:photos/services/favorites_service.dart";
import 'package:photos/services/sync/local_sync_service.dart';
import 'package:photos/services/sync/remote_sync_service.dart';
import "package:photos/settings/local_settings.dart";
import 'package:shared_preferences/shared_preferences.dart';

String? _resolvePublicAlbumAccessToken(Uri uri) {
  final tokenFromQuery = uri.queryParameters["t"];
  if (tokenFromQuery != null && tokenFromQuery.isNotEmpty) {
    return tokenFromQuery;
  }
  return uri.pathSegments.firstWhereOrNull((segment) => segment.isNotEmpty);
}

class CollectionsService {
  static const _collectionSyncTimeKeyPrefix = "collection_sync_time_";
  static const _collectionsSyncTimeKey = "collections_sync_time_x";

  static const int kMaximumWriteAttempts = 5;
  static const int _maxSocialCleanupRetries = 3;
  static const int _collectionKeyLength = 32;
  static const int _shareBatchSize = 10;

  final _logger = Logger("CollectionsService");

  late CollectionsDB _db;
  late FilesDB _filesDB;
  late Configuration _config;
  late SharedPreferences _prefs;
  StreamSubscription<CollectionUpdatedEvent>? _collectionUpdatedSubscription;

  final _collectionIDToCollections = <int, Collection>{};
  Collection? cachedDefaultHiddenCollection;
  Future<Map<int, int>>? _collectionIDToNewestFileTime;
  final Map<String, EnteFile> _coverCache = <String, EnteFile>{};
  final Map<int, int> _countCache = <int, int>{};

  static const int _maxRecentlyUsedCollections = 3;
  final _recentlyUsedCollectionIDs = <int>[];

  CollectionsService._privateConstructor() {
    _db = CollectionsDB.instance;
    _filesDB = FilesDB.instance;
    _config = Configuration.instance;
  }

  static final CollectionsService instance =
      CollectionsService._privateConstructor();

  Future<void> init(SharedPreferences preferences) async {
    _prefs = preferences;
    final collections = await _db.getAllCollections();

    for (final collection in collections) {
      _cacheCollection(collection);
    }
    if (_collectionUpdatedSubscription != null) {
      await _collectionUpdatedSubscription!.cancel();
    }
    _collectionUpdatedSubscription = Bus.instance
        .on<CollectionUpdatedEvent>()
        .listen((event) {
          _collectionIDToNewestFileTime = null;
          if (event.collectionID != null) {
            _coverCache.removeWhere(
              (key, value) => key.startsWith(event.collectionID!.toString()),
            );
            _countCache.remove(event.collectionID);
          }
        });
  }

  Configuration get config => _config;

  Map<int, Collection> get collectionIDToCollections =>
      _collectionIDToCollections;

  FilesDB get filesDB => _filesDB;

  Future<void> sync() async {
    _logger.info("Syncing collections");
    final EnteWatch watch = EnteWatch("syncCollection")..start();
    final lastCollectionUpdationTime =
        _prefs.getInt(_collectionsSyncTimeKey) ?? 0;

    _logger.info("[COLLECTIONS] Starting sync");

    final fetchedCollections = await _fetchCollections(
      lastCollectionUpdationTime,
    );
    _logger.info(
      "[COLLECTIONS] Fetched ${fetchedCollections.length} collections from API",
    );
    watch.log("remote fetch collections ${fetchedCollections.length}");

    if (fetchedCollections.isEmpty) {
      await _ensureUncategorizedCollectionExists();
      return;
    }
    final updatedCollections = <Collection>[];
    int maxUpdationTime = lastCollectionUpdationTime;
    final ownerID = _config.getUserID();
    bool shouldFireDeleteEvent = false;
    for (final collection in fetchedCollections) {
      if (collection.isDeleted) {
        await _filesDB.deleteCollection(collection.id);
        await setCollectionSyncTime(collection.id, null);
        if (_collectionIDToCollections.containsKey(collection.id)) {
          shouldFireDeleteEvent = true;
        }
      }
      if (collection.isDeleted && ownerID != collection.owner.id) {
        await _db.deleteCollection(collection.id);
      } else {
        // keep entry for deletedCollection as collectionKey may be used during
        // trash file decryption
        updatedCollections.add(collection);
      }
      maxUpdationTime = collection.updationTime > maxUpdationTime
          ? collection.updationTime
          : maxUpdationTime;
    }

    if (shouldFireDeleteEvent) {
      Bus.instance.fire(
        LocalPhotosUpdatedEvent(
          List<EnteFile>.empty(),
          source: "syncCollectionDeleted",
        ),
      );
    }

    await _updateDB(updatedCollections);
    await _prefs.setInt(_collectionsSyncTimeKey, maxUpdationTime);
    watch.logAndReset("till DB insertion ${updatedCollections.length}");
    _logger.info("[COLLECTIONS] Updated ${updatedCollections.length} in DB");

    for (final collection in fetchedCollections) {
      _cacheCollection(collection);
    }

    _logger.info("Collections synced");
    watch.log("${fetchedCollections.length} collection cached refreshed ");

    if (fetchedCollections.isNotEmpty) {
      Bus.instance.fire(
        CollectionUpdatedEvent(
          null,
          List<EnteFile>.empty(),
          "collections_updated",
        ),
      );
    }

    await _ensureUncategorizedCollectionExists();
  }

  void clearCache() {
    _collectionIDToCollections.clear();
    cachedDefaultHiddenCollection = null;
  }

  Future<Map<int, int>> getCollectionIDsToBeSynced() async {
    final idsToRemoveUpdateTimeMap = await _db
        .getActiveIDsAndRemoteUpdateTime();
    final result = <int, int>{};
    for (final MapEntry<int, int> e in idsToRemoveUpdateTimeMap.entries) {
      final int cid = e.key;
      final int remoteUpdateTime = e.value;
      if (remoteUpdateTime > getCollectionSyncTime(cid)) {
        result[cid] = remoteUpdateTime;
      }
    }
    return result;
  }

  bool allowUpload(int collectionID) {
    final Collection? c = _collectionIDToCollections[collectionID];
    if (c == null) {
      _logger.info('discardUpload: collectionMissing $collectionID');
      return false;
    }
    if (c.isDeleted) {
      _logger.info('discardUpload: collectionDeleted $collectionID');
      return false;
    }
    if (!c.isOwner(_config.getUserID()!)) {
      _logger.info('discardUpload: notOwner $collectionID');
      return false;
    }
    return true;
  }

  Future<List<Collection>> getArchivedCollection() async {
    final allCollections = getCollectionsForUI(includedShared: true);
    return allCollections
        .where((c) => c.isArchived() && !c.isHidden())
        .toList();
  }

  List<Collection> getHiddenCollections({bool includeDefaultHidden = true}) {
    if (includeDefaultHidden) {
      return _collectionIDToCollections.values
          .where((c) => c.isHidden())
          .toList();
    } else {
      return _collectionIDToCollections.values
          .where(
            (c) => c.isHidden() && c.id != cachedDefaultHiddenCollection?.id,
          )
          .toList();
    }
  }

  Set<int> getHiddenCollectionIds() {
    return _collectionIDToCollections.values
        .where((c) => c.isHidden())
        .map((e) => e.id)
        .toSet();
  }

  Set<int> archivedOrHiddenCollectionIds() {
    return _collectionIDToCollections.values
        .where((c) => c.isArchived() || c.isHidden())
        .map((e) => e.id)
        .toSet();
  }

  int getCollectionSyncTime(int collectionID) {
    return _prefs.getInt(
          _collectionSyncTimeKeyPrefix + collectionID.toString(),
        ) ??
        0;
  }

  Future<Map<int, int>> getCollectionIDToNewestFileTime() {
    _collectionIDToNewestFileTime ??= _filesDB
        .getCollectionIDToMaxCreationTime();
    return _collectionIDToNewestFileTime!;
  }

  Future<void> sortCollectionsByAlbumPreferences(
    List<Collection> collections, {
    AlbumSortKey? sortKey,
    AlbumSortDirection? sortDirection,
  }) async {
    if (collections.length < 2) {
      return;
    }
    final comparator = await _albumPreferenceComparator(
      sortKey: sortKey,
      sortDirection: sortDirection,
    );
    collections.sort(comparator);
  }

  Future<List<Collection>> orderCollectionsForAlbums(
    Iterable<Collection> collections,
  ) async {
    final sorted = collections.toList();
    final userID = _config.getUserID();
    bool isPinnedForCurrentUser(Collection collection) =>
        userID != null && !collection.isOwner(userID)
        ? collection.hasShareePinned()
        : collection.isPinned;
    await sortCollectionsByAlbumPreferences(sorted);
    return [
      ...sorted.where(
        (collection) => collection.type == CollectionType.favorites,
      ),
      ...sorted.where(
        (collection) =>
            collection.type != CollectionType.favorites &&
            isPinnedForCurrentUser(collection),
      ),
      ...sorted.where(
        (collection) =>
            collection.type != CollectionType.favorites &&
            !isPinnedForCurrentUser(collection),
      ),
    ];
  }

  Future<Comparator<Collection>> _albumPreferenceComparator({
    AlbumSortKey? sortKey,
    AlbumSortDirection? sortDirection,
  }) async {
    final effectiveSortKey = sortKey ?? localSettings.albumSortKey();
    final effectiveSortDirection =
        sortDirection ?? localSettings.albumSortDirection();
    final newestPhotoTimeByCollectionID =
        effectiveSortKey == AlbumSortKey.newestPhoto
        ? await getCollectionIDToNewestFileTime()
        : const <int, int>{};

    return (Collection first, Collection second) {
      final comparison = switch (effectiveSortKey) {
        AlbumSortKey.albumName => compareAsciiLowerCaseNatural(
          first.displayName,
          second.displayName,
        ),
        AlbumSortKey.newestPhoto =>
          (newestPhotoTimeByCollectionID[second.id] ?? -intMaxValue).compareTo(
            newestPhotoTimeByCollectionID[first.id] ?? -intMaxValue,
          ),
        AlbumSortKey.lastUpdated => second.updationTime.compareTo(
          first.updationTime,
        ),
      };
      return effectiveSortDirection == AlbumSortDirection.ascending
          ? comparison
          : -comparison;
    };
  }

  Future<EnteFile?> getCover(Collection c) async {
    final int localSyncTime = getCollectionSyncTime(c.id);
    final String coverKey = '${c.id}_${localSyncTime}_${c.updationTime}';
    if (_coverCache.containsKey(coverKey)) {
      return Future.value(_coverCache[coverKey]!);
    }
    if (kDebugMode) {
      debugPrint("getCover for collection ${c.id} ${c.displayName}");
    }
    if (c.hasCover) {
      final coverID = c.pubMagicMetadata.coverID ?? 0;
      final EnteFile? cover = await filesDB.getUploadedFile(coverID, c.id);
      if (cover != null) {
        _coverCache[coverKey] = cover;
        return Future.value(cover);
      }
    }
    final coverFile = await filesDB.getCollectionFileFirstOrLast(
      c.id,
      c.pubMagicMetadata.asc ?? false,
    );
    if (coverFile != null) {
      _coverCache[coverKey] = coverFile;
      return Future.value(coverFile);
    }
    return null;
  }

  EnteFile? getCoverCache(Collection c) {
    final int localSyncTime = getCollectionSyncTime(c.id);
    final String coverKey = '${c.id}_${localSyncTime}_${c.updationTime}';
    return _coverCache[coverKey];
  }

  Future<int> getFileCount(Collection c, {bool useCache = true}) async {
    if (_countCache.containsKey(c.id) && useCache) {
      return _countCache[c.id]!;
    } else {
      final count = await _filesDB.collectionFileCount(c.id);
      _countCache[c.id] = count;
      return count;
    }
  }

  int? getCachedFileCount(Collection c) {
    return _countCache[c.id];
  }

  Future<bool> setCollectionSyncTime(int collectionID, int? time) async {
    final key = _collectionSyncTimeKeyPrefix + collectionID.toString();
    if (time == null) {
      return _prefs.remove(key);
    }
    return _prefs.setInt(key, time);
  }

  List<Collection> getActiveCollections() {
    return _collectionIDToCollections.values
        .toList()
        .where((element) => !element.isDeleted)
        .toList();
  }

  Future<Collection> getUncategorizedCollection() async {
    final int? userID = _config.getUserID();
    if (userID == null) {
      throw StateError("Cannot get Uncategorized without a configured user");
    }

    final matchedCollection = _collectionIDToCollections.values
        .firstWhereOrNull(
          (collection) =>
              !collection.isDeleted &&
              collection.type == CollectionType.uncategorized &&
              collection.isOwner(userID),
        );
    if (matchedCollection != null) {
      return matchedCollection;
    }

    return _createUncategorizedCollection();
  }

  Future<void> _ensureUncategorizedCollectionExists() async {
    try {
      await getUncategorizedCollection();
    } catch (e, s) {
      _logger.warning("Failed to ensure Uncategorized collection exists", e, s);
    }
  }

  Set<int> nonHiddenOwnedCollections() {
    final int ownerID = _config.getUserID()!;
    return _collectionIDToCollections.values
        .toList()
        .where(
          (element) =>
              !element.isDeleted &&
              !element.isHidden() &&
              element.isOwner(ownerID),
        )
        .map((e) => e.id)
        .toSet();
  }

  List<Collection> getCollectionsForUI({
    bool includedShared = false,
    bool includeCollab = false,
    bool includeUncategorized = false,
  }) {
    final Set<CollectionParticipantRole> allowedRoles = {
      CollectionParticipantRole.owner,
    };
    if (includedShared) {
      allowedRoles.add(CollectionParticipantRole.viewer);
    }
    if (includedShared || includeCollab) {
      allowedRoles.add(CollectionParticipantRole.collaborator);
      allowedRoles.add(CollectionParticipantRole.admin);
    }
    final int? userID = _config.getUserID();
    if (userID == null) {
      _logger.info(
        "Skipping collections for UI because user ID is unavailable",
      );
      return <Collection>[];
    }
    return _collectionIDToCollections.values
        .where(
          (c) =>
              !c.isDeleted &&
              (includeUncategorized ||
                  c.type != CollectionType.uncategorized ||
                  !c.isOwner(userID)) &&
              !c.isHidden() &&
              allowedRoles.contains(c.getRole(userID)),
        )
        .toList();
  }

  void recordCollectionUsage(int collectionID) {
    _recentlyUsedCollectionIDs.remove(collectionID);
    _recentlyUsedCollectionIDs.insert(0, collectionID);
    if (_recentlyUsedCollectionIDs.length > _maxRecentlyUsedCollections) {
      _recentlyUsedCollectionIDs.removeLast();
    }
  }

  List<Collection> getRecentlyUsedCollections() {
    final List<Collection> result = [];
    for (final id in _recentlyUsedCollectionIDs) {
      final collection = _collectionIDToCollections[id];
      if (collection != null &&
          !collection.isDeleted &&
          !collection.isHidden()) {
        result.add(collection);
      }
    }
    return result;
  }

  List<int> getAllOwnedCollectionIDs() {
    final int userID = _config.getUserID()!;
    return _collectionIDToCollections.values
        .where((c) => !c.isDeleted && c.isOwner(userID))
        .map((e) => e.id)
        .toList();
  }

  /// The albums shown on the Albums tab: every normal album, favorites first, then pinned ones.
  Future<List<Collection>> getCollectionsForAlbumsTab() async {
    final bool hasFavorites = FavoritesService.instance.hasFavorites();
    return orderCollectionsForAlbums(
      getCollectionsForUI().where(
        (collection) =>
            collection.type != CollectionType.uncategorized &&
            !collection.isHidden() &&
            !collection.isArchived() &&
            (collection.type != CollectionType.favorites || hasFavorites),
      ),
    );
  }

  Future<List<Collection>> getCollectionForWidgetSelection() async {
    const bool includeShared = true;
    final List<Collection> collections = CollectionsService.instance
        .getCollectionsForUI(includedShared: includeShared);
    final bool hasFavorites = FavoritesService.instance.hasFavorites();
    await sortCollectionsByAlbumPreferences(collections);
    final List<Collection> favorites = [];
    final List<Collection> pinned = [];
    final List<Collection> rest = [];
    for (final collection in collections) {
      if (collection.type == CollectionType.uncategorized ||
          collection.isQuickLinkCollection() ||
          collection.isHidden() ||
          collection.isArchived()) {
        continue;
      }
      if (collection.type == CollectionType.favorites) {
        if (hasFavorites) {
          favorites.add(collection);
        }
      } else if (collection.isPinned) {
        pinned.add(collection);
      } else {
        rest.add(collection);
      }
    }

    return favorites + pinned + rest;
  }

  Future<List<Collection>> getCollectionsForRituals() async {
    final List<Collection> collections = CollectionsService.instance
        .getCollectionsForUI();
    final bool hasFavorites = FavoritesService.instance.hasFavorites();
    await sortCollectionsByAlbumPreferences(collections);
    final List<Collection> favorites = [];
    final List<Collection> pinned = [];
    final List<Collection> rest = [];
    final int? userId = Configuration.instance.getUserID();
    for (final collection in collections) {
      if (collection.type == CollectionType.uncategorized ||
          collection.isQuickLinkCollection() ||
          (collection.isHidden()) ||
          ((userId == null || !collection.canAutoAdd(userId)))) {
        continue;
      }
      if (collection.type == CollectionType.favorites) {
        if (hasFavorites) {
          favorites.add(collection);
        }
      } else if (collection.isPinned) {
        pinned.add(collection);
      } else {
        rest.add(collection);
      }
    }

    return favorites + pinned + rest;
  }

  /// Deletes the album together with its photos (they go to Filen's trash).
  Future<void> trashNonEmptyCollection(Collection collection) async {
    try {
      await _turnOffDeviceFolderSync(collection);
      await FilenSyncService.instance.deleteCollection(
        collection,
        withFiles: true,
      );
      await _handleCollectionDeletion(collection);
    } catch (e) {
      _logger.severe('failed to trash collection', e);
      rethrow;
    }
  }

  Future<void> _turnOffDeviceFolderSync(Collection collection) async {
    final deviceCollections = await _filesDB.getDeviceCollections();
    final Map<String, bool> devicePathIDsToUnSync = Map.fromEntries(
      deviceCollections
          .where((e) => e.shouldBackup && e.collectionID == collection.id)
          .map((e) => MapEntry(e.id, false)),
    );

    if (devicePathIDsToUnSync.isNotEmpty) {
      _logger.info(
        'turning off backup status for folders $devicePathIDsToUnSync',
      );
      await RemoteSyncService.instance.updateDeviceFolderSyncStatus(
        devicePathIDsToUnSync,
      );
    }
  }

  /// Deletes an album that holds no photos (any photo was moved out before).
  Future<void> trashEmptyCollection(
    Collection collection, {
    // Avoid rapid gallery refreshes during bulk deletion.
    bool isBulkDelete = false,
  }) async {
    try {
      if (!isBulkDelete) {
        await _turnOffDeviceFolderSync(collection);
      }
      await FilenSyncService.instance.deleteCollection(
        collection,
        withFiles: false,
      );
      if (isBulkDelete) {
        final deletedCollection = collection.copyWith(isDeleted: true);
        _collectionIDToCollections[collection.id] = deletedCollection;
        unawaited(_db.insert([deletedCollection]));
      } else {
        await _handleCollectionDeletion(collection);
      }
    } catch (e) {
      _logger.severe('failed to trash empty collection', e);
      rethrow;
    }
  }

  Future<void> _handleCollectionDeletion(Collection collection) async {
    await _filesDB.deleteCollection(collection.id);
    final deletedCollection = collection.copyWith(isDeleted: true);
    unawaited(_db.insert([deletedCollection]));
    _collectionIDToCollections[collection.id] = deletedCollection;
    Bus.instance.fire(
      CollectionUpdatedEvent(
        collection.id,
        <EnteFile>[],
        "delete_collection",
        type: EventType.deletedFromRemote,
      ),
    );
    sync().ignore();
    // not required once remote & local world are separate
    LocalSyncService.instance.syncAll().ignore();
  }

  Future<void> rename(Collection collection, String newName) async {
    try {
      await FilenSyncService.instance.renameCollection(collection, newName);
      collection.setName(newName);
      _collectionIDToCollections[collection.id] = collection;
      unawaited(_db.insert([collection]));
      Bus.instance.fire(
        CollectionUpdatedEvent(
          collection.id,
          <EnteFile>[],
          "rename_collection",
        ),
      );
    } catch (e, s) {
      _logger.warning("failed to rename collection", e, s);
      rethrow;
    }
  }

  Future<void> updateMagicMetadata(
    Collection collection,
    Map<String, dynamic> newMetadataUpdate,
  ) async {
    try {
      final Map<String, dynamic> jsonToUpdate = jsonDecode(
        collection.mMdEncodedJson ?? '{}',
      );
      newMetadataUpdate.forEach((key, value) {
        jsonToUpdate[key] = value;
      });
      final int nextVersion = max(collection.mMdVersion, 1) + 1;
      final json = jsonEncode(jsonToUpdate);
      await FilenSyncService.instance.updateCollectionMeta(
        collection,
        mmd: json,
        mv: nextVersion,
      );
      collection.mMdEncodedJson = json;
      collection.magicMetadata = CollectionMagicMetadata.fromJson(jsonToUpdate);
      collection.mMdVersion = nextVersion;
      _collectionIDToCollections[collection.id] = collection;
      unawaited(_db.insert([collection]));
    } catch (e, s) {
      _logger.severe("failed to save album settings", e, s);
      rethrow;
    }
  }

  Future<void> updatePublicMagicMetadata(
    Collection collection,
    Map<String, dynamic> newMetadataUpdate,
  ) async {
    try {
      final Map<String, dynamic> jsonToUpdate = jsonDecode(
        collection.mMdPubEncodedJson ?? '{}',
      );
      newMetadataUpdate.forEach((key, value) {
        jsonToUpdate[key] = value;
      });
      final int nextVersion = max(collection.mMbPubVersion, 1) + 1;
      final json = jsonEncode(jsonToUpdate);
      await FilenSyncService.instance.updateCollectionMeta(
        collection,
        pub: json,
        pv: nextVersion,
      );
      collection.mMdPubEncodedJson = json;
      collection.pubMagicMetadata = CollectionPubMagicMetadata.fromJson(
        jsonToUpdate,
      );
      collection.mMbPubVersion = nextVersion;
      _cacheCollection(collection);
      unawaited(_db.insert([collection]));
    } catch (e, s) {
      _logger.severe("failed to save album settings", e, s);
      rethrow;
    }
  }

  Future<List<Collection>> _fetchCollections(int sinceTime) =>
      FilenSyncService.instance.fetchCollections();

  Uint8List _decodePublicCollectionKey(String albumKey) {
    if (albumKey.isEmpty) {
      throw const FormatException("Missing public collection key");
    }
    final collectionKey = Uint8List.fromList(Base58Decode(albumKey));
    if (collectionKey.length != _collectionKeyLength) {
      throw const FormatException("Invalid public collection key length");
    }
    return collectionKey;
  }

  Collection? getCollectionByID(int collectionID) {
    return _collectionIDToCollections[collectionID];
  }

  Future<Collection> createAlbum(String albumName) =>
      createCollection(name: albumName);

  Future<Collection> getOrCreateForPath(String path) =>
      FilenSyncService.instance.getOrCreateAlbum(path);

  Future<void> addOrCopyToCollection(
    int dstCollectionID,
    List<EnteFile> files, {
    bool toCopy = true,
  }) async {
    if (files.any((f) => f.uploadedFileID == null)) {
      throw ArgumentError('File should be already uploaded');
    }
    await _addToCollection(dstCollectionID, files);
  }

  Future<void> _addToCollection(int collectionID, List<EnteFile> files) =>
      FilenSyncService.instance.addFiles(collectionID, files);

  // Dedupe uses this without updating FilesDB or mutating the EnteFile objects.
  Future<void> addSilentlyToCollection(
    int collectionID,
    List<EnteFile> files,
  ) async {
    if (files.isEmpty) {
      return;
    }
    if (files.any((element) => element.uploadedFileID == null)) {
      throw ArgumentError('Can only add uploaded files silently');
    }
    await FilenSyncService.instance.addFiles(
      collectionID,
      files,
      updateDb: false,
    );
  }

  Future<void> restore(int toCollectionID, List<EnteFile> files) =>
      FilenSyncService.instance.restoreFromTrash(toCollectionID, files);

  Future<void> move(
    List<EnteFile> files, {
    required int toCollectionID,
    required int fromCollectionID,
  }) async {
    _validateMoveRequest(toCollectionID, fromCollectionID, files);
    final filesToMove = files.map((file) => file.copyWith()).toList();
    filesToMove.removeWhere((element) => element.uploadedFileID == null);
    if (filesToMove.isEmpty) {
      _logger.info("nothing to move to collection");
      return;
    }
    return FilenSyncService.instance.moveFiles(
      filesToMove,
      toCollectionID: toCollectionID,
      fromCollectionID: fromCollectionID,
    );
  }

  void _validateMoveRequest(
    int toCollectionID,
    int fromCollectionID,
    List<EnteFile> files,
  ) {
    final int userID = Configuration.instance.getUserID()!;
    if (toCollectionID == fromCollectionID) {
      throw AssertionError("Can't move to same album");
    }
    final Collection? toCollection = _collectionIDToCollections[toCollectionID];
    final Collection? fromCollection =
        _collectionIDToCollections[fromCollectionID];
    if (toCollection != null && !toCollection.isOwner(userID)) {
      throw AssertionError("Can't move to a collection you don't own");
    }
    if (fromCollection != null && !fromCollection.isOwner(userID)) {
      throw AssertionError("Can't move from a collection you don't own");
    }
    for (final file in files) {
      if (file.uploadedFileID == null) {
        throw AssertionError("Can only move uploaded memories");
      }
      if (file.collectionID != fromCollectionID) {
        throw AssertionError("All memories should belong to the same album");
      }
      if (file.ownerID != Configuration.instance.getUserID()) {
        throw AssertionError("Can only move memories uploaded by you");
      }
    }
  }

  Future<void> removeFromCollection(int collectionID, List<EnteFile> files) =>
      FilenSyncService.instance.removeFromAlbum(collectionID, files);

  /// Creates an album (or the favorites collection). Albums that are not a folder on Filen live in
  /// the app's state folder, see `FilenCollectionStore`.
  Future<Collection> createCollection({
    required String name,
    CollectionType type = CollectionType.album,
    Map<String, dynamic>? magicMetadata,
  }) async {
    final created = await FilenSyncService.instance.createVirtualCollection(
      name: name,
      type: type,
      magicMetadataJson: magicMetadata == null
          ? null
          : jsonEncode(magicMetadata),
    );
    Bus.instance.fire(
      CollectionUpdatedEvent(
        created.id,
        List<EnteFile>.empty(),
        "createCollection",
      ),
    );
    return created;
  }

  Future<Collection> _createUncategorizedCollection() async {
    final root = await FilenSyncService.instance.libraryRootCollection();
    _collectionIDToCollections[root.id] = root;
    return root;
  }

  Collection _cacheCollection(Collection collection) {
    _collectionIDToCollections[collection.id] = collection;
    return collection;
  }

  bool hasSyncedCollections() {
    return _prefs.containsKey(_collectionsSyncTimeKey);
  }

  Future _updateDB(List<Collection> collections, {int attempt = 1}) async {
    if (collections.isEmpty) {
      return;
    }
    try {
      await _db.insert(collections);
    } catch (e) {
      _logger.severe("Failed to update collections", e);
      if (attempt < kMaximumWriteAttempts) {
        return _updateDB(collections, attempt: ++attempt);
      } else {
        rethrow;
      }
    }
  }
}
