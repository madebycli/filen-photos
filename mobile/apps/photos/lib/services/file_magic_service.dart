import 'dart:convert';

import 'package:ente_pure_utils/ente_pure_utils.dart';
import 'package:logging/logging.dart';
import 'package:photos/core/configuration.dart';
import 'package:photos/core/constants.dart';
import 'package:photos/core/event_bus.dart';
import 'package:photos/db/files_db.dart';
import 'package:photos/events/files_updated_event.dart';
import 'package:photos/events/force_reload_home_gallery_event.dart';
import 'package:photos/events/local_photos_updated_event.dart';
import 'package:photos/filen/filen_sync.dart';
import 'package:photos/models/file/file.dart';
import "package:photos/models/metadata/common_keys.dart";
import "package:photos/models/metadata/file_magic.dart";
import 'package:photos/services/sync/remote_sync_service.dart';
import "package:synchronized/synchronized.dart";

class _MagicMetadataUpdate<T> {
  const _MagicMetadataUpdate({
    required this.file,
    required this.encodedJson,
    required this.decodedMetadata,
    required this.nextVersion,
  });

  final EnteFile file;
  final String encodedJson;
  final T decodedMetadata;
  final int nextVersion;
}

/// Edits of the "magic metadata" of photos: archive/hide, caption, edited date, location...
/// The values are kept in the local database and queued for the app's state folder on Filen
/// (see `FilenMetaStore`), versioned so that the newest edit wins on every device.
class FileMagicService {
  final _logger = Logger("FileMagicService");
  final _privateMetadataLock = Lock();
  final _publicMetadataLock = Lock();
  late FilesDB _filesDB;

  FileMagicService._privateConstructor() {
    _filesDB = FilesDB.instance;
  }

  static final FileMagicService instance =
      FileMagicService._privateConstructor();

  Future<void> changeVisibility(List<EnteFile> files, int visibility) async {
    final Map<String, dynamic> update = {magicKeyVisibility: visibility};
    await _updateMagicData(files, update);
    if (visibility == visibleVisibility) {
      Bus.instance.fire(ForceReloadHomeGalleryEvent("unarchivedFiles"));
      Bus.instance.fire(
        LocalPhotosUpdatedEvent(
          files,
          type: EventType.unarchived,
          source: "vizChange",
        ),
      );
    } else {
      Bus.instance.fire(
        LocalPhotosUpdatedEvent(
          files,
          type: EventType.archived,
          source: "vizChange",
        ),
      );
    }
  }

  Future<void> updatePublicMagicMetadata(
    List<EnteFile> files,
    Map<String, dynamic>? newMetadataUpdate, {
    Map<int, Map<String, dynamic>>? metadataUpdateMap,
  }) {
    return _publicMetadataLock.synchronized(
      () => _updatePublicMagicMetadata(
        files,
        newMetadataUpdate,
        metadataUpdateMap: metadataUpdateMap,
      ),
    );
  }

  Future<void> _updatePublicMagicMetadata(
    List<EnteFile> files,
    Map<String, dynamic>? newMetadataUpdate, {
    Map<int, Map<String, dynamic>>? metadataUpdateMap,
  }) async {
    final updates = <_MagicMetadataUpdate<PubMagicMetadata>>[];
    final int ownerID = Configuration.instance.getUserID()!;
    try {
      for (final file in files) {
        _assertCanUpdate(file, ownerID);
        final newUpdates = metadataUpdateMap != null
            ? metadataUpdateMap[file.uploadedFileID]
            : newMetadataUpdate;
        assert(
          newUpdates != null && newUpdates.isNotEmpty,
          "can not apply empty updates",
        );
        final int currentVersion = file.pubMmdVersion == 0
            ? 1
            : file.pubMmdVersion;
        updates.add(
          _prepareUpdate(
            file: file,
            encodedJson: file.pubMmdEncodedJson,
            currentVersion: currentVersion,
            newMetadata: newUpdates!,
            decode: PubMagicMetadata.fromJson,
          ),
        );
      }
      for (final update in updates) {
        update.file
          ..pubMmdEncodedJson = update.encodedJson
          ..pubMagicMetadata = update.decodedMetadata
          ..pubMmdVersion = update.nextVersion;
        FilenSyncService.instance.noteFileMeta(update.file);
      }
      await _filesDB.insertMultiple(files);
      RemoteSyncService.instance.sync(silently: true).ignore();
    } catch (e, s) {
      _logger.severe("failed to save public metadata", e, s);
      rethrow;
    }
  }

  Future<void> _updateMagicData(
    List<EnteFile> files,
    Map<String, dynamic> newMetadataUpdate,
  ) {
    return _privateMetadataLock.synchronized(
      () => _updatePrivateMagicMetadata(files, newMetadataUpdate),
    );
  }

  Future<void> _updatePrivateMagicMetadata(
    List<EnteFile> files,
    Map<String, dynamic> newMetadataUpdate,
  ) async {
    final int ownerID = Configuration.instance.getUserID()!;
    final batchedFiles = files.chunks(batchSize);
    try {
      for (final batch in batchedFiles) {
        final updates = <_MagicMetadataUpdate<MagicMetadata>>[];
        for (final file in batch) {
          _assertCanUpdate(file, ownerID);
          updates.add(
            _prepareUpdate(
              file: file,
              encodedJson: file.mMdEncodedJson,
              currentVersion: file.mMdVersion,
              newMetadata: newMetadataUpdate,
              decode: MagicMetadata.fromJson,
            ),
          );
        }
        for (final update in updates) {
          update.file
            ..mMdEncodedJson = update.encodedJson
            ..magicMetadata = update.decodedMetadata
            ..mMdVersion = update.nextVersion;
          FilenSyncService.instance.noteFileMeta(update.file);
        }
        await _filesDB.insertMultiple(batch);
      }

      RemoteSyncService.instance.sync(silently: true).ignore();
    } catch (e, s) {
      _logger.severe("failed to save metadata", e, s);
      rethrow;
    }
  }

  void _assertCanUpdate(EnteFile file, int ownerID) {
    if (file.uploadedFileID == null) {
      throw AssertionError("operation is only supported on backed up files");
    } else if (file.ownerID != ownerID) {
      throw AssertionError("cannot modify memories not owned by you");
    }
  }

  _MagicMetadataUpdate<T> _prepareUpdate<T>({
    required EnteFile file,
    required String? encodedJson,
    required int currentVersion,
    required Map<String, dynamic> newMetadata,
    required T Function(dynamic json) decode,
  }) {
    final Map<String, dynamic> jsonToUpdate = jsonDecode(encodedJson ?? '{}');
    jsonToUpdate.addAll(newMetadata);
    return _MagicMetadataUpdate(
      file: file,
      encodedJson: jsonEncode(jsonToUpdate),
      decodedMetadata: decode(jsonToUpdate),
      nextVersion: currentVersion + 1,
    );
  }
}
