import 'dart:async';

import 'package:logging/logging.dart';
import 'package:photos/core/event_bus.dart';
import 'package:photos/db/trash_db.dart';
import 'package:photos/events/collection_updated_event.dart';
import 'package:photos/events/force_reload_trash_page_event.dart';
import 'package:photos/events/trash_updated_event.dart';
import 'package:photos/filen/filen_sync.dart';
import 'package:photos/gateways/trash/models/trash_item_request.dart';
import 'package:photos/models/file/file.dart';
import 'package:photos/models/file/trash_file.dart';
import 'package:photos/models/ignored_file.dart';
import 'package:photos/service_locator.dart';
import 'package:photos/services/ignored_files_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The trash page: photos and videos that were moved to Filen's trash. Filen has no "changes
/// since" feed for its trash, so every sync compares the whole (top level) trash with the local
/// table, see `FilenSyncService.trashDiff`.
class TrashSyncService {
  final _logger = Logger("TrashSyncService");

  final _trashDB = TrashDB.instance;
  static const kLastTrashSyncTime = "last_trash_sync_time";
  late SharedPreferences _prefs;

  TrashSyncService(this._prefs) {
    _logger.info("TrashSyncService constructor");
  }

  void init(SharedPreferences preferences) {
    _prefs = preferences;
  }

  Future<void> syncTrash() async {
    bool isLocalTrashUpdated = false;
    final diff = await FilenSyncService.instance.trashDiff();
    if (diff.trashedFiles.isNotEmpty) {
      isLocalTrashUpdated = true;
      _logger.info("inserting ${diff.trashedFiles.length} items in trash");
      await _trashDB.insertMultiple(diff.trashedFiles);
    }
    if (diff.deletedUploadIDs.isNotEmpty) {
      _logger.info("discard ${diff.deletedUploadIDs.length} deleted items");
      final itemsDeleted = await _trashDB.delete(diff.deletedUploadIDs);
      isLocalTrashUpdated = isLocalTrashUpdated || itemsDeleted > 0;
    }

    await _updateIgnoredFiles(diff);

    if (diff.lastSyncedTimeStamp != 0) {
      await _prefs.setInt(kLastTrashSyncTime, diff.lastSyncedTimeStamp);
    }
    if (isLocalTrashUpdated) {
      Bus.instance.fire(TrashUpdatedEvent());
      Bus.instance.fire(
        CollectionUpdatedEvent(0, <EnteFile>[], "trash_change"),
      );
    }
  }

  Future<void> _updateIgnoredFiles(TrashDiff diff) =>
      _ignoreTrashed(diff.trashedFiles);

  /// Remembers that these photos were deleted, so the phone they came from does not upload them
  /// again.
  Future<void> _ignoreTrashed(List<EnteTrashFile> trashed) async {
    // Filen's own camera upload uploads a deleted photo again; Ente remembers and skips it.
    if (backupSettings.shouldReuploadDeleted()) return;
    final ignoredFiles = <IgnoredFile>[];
    for (final t in trashed) {
      final file = IgnoredFile.fromTrashItem(t);
      if (file != null) {
        ignoredFiles.add(file);
      }
    }
    if (ignoredFiles.isNotEmpty) {
      _logger.info('updating ${ignoredFiles.length} ignored files ');
      await IgnoredFilesService.instance.cacheAndInsert(ignoredFiles);
    }
  }

  /// Moves the files to Filen's trash (they are not deleted permanently).
  Future<void> trashFilesOnServer(List<TrashRequest> trashRequestItems) async {
    final trashed = await FilenSyncService.instance.trashFiles(
      trashRequestItems,
    );
    if (trashed.isEmpty) return;
    await _trashDB.insertMultiple(trashed);
    await _ignoreTrashed(trashed);
    Bus.instance.fire(TrashUpdatedEvent());
  }

  /// Permanently deletes photos from the trash after the user confirmed it.
  Future<void> deleteFromTrash(List<EnteTrashFile> files) async {
    await FilenSyncService.instance.deleteFromTrash(files);
    unawaited(syncTrash());
  }

  /// Permanently deletes the photos and videos shown in the trash page. Everything else in the
  /// Filen trash stays.
  Future<void> emptyTrash() async {
    final all = await _trashDB.getTrashedFiles(0, 1 << 62);
    await FilenSyncService.instance.deleteFromTrash([
      for (final f in all.files) f as EnteTrashFile,
    ]);
    await _trashDB.clearTable();
    Bus.instance.fire(TrashUpdatedEvent());
    Bus.instance.fire(ForceReloadTrashPageEvent());
  }
}

class TrashDiff {
  final List<EnteTrashFile> trashedFiles;
  final List<EnteTrashFile> restoredFiles;
  final List<int> deletedUploadIDs;
  final bool hasMore;
  final int lastSyncedTimeStamp;
  TrashDiff(
    this.trashedFiles,
    this.restoredFiles,
    this.deletedUploadIDs,
    this.hasMore,
    this.lastSyncedTimeStamp,
  );
}
