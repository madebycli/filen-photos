import 'dart:async';
import 'dart:io';

import "package:dio/dio.dart";
import 'package:ente_pure_utils/ente_pure_utils.dart';
import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';
import "package:permission_handler/permission_handler.dart";
import "package:photos/core/constants.dart";
import 'package:photos/core/errors.dart';
import 'package:photos/core/event_bus.dart';
import 'package:photos/db/files_db.dart';
import 'package:photos/db/upload_locks_db.dart';
import "package:photos/events/backup_updated_event.dart";
import "package:photos/events/file_uploaded_event.dart";
import 'package:photos/events/files_updated_event.dart';
import 'package:photos/events/local_photos_updated_event.dart';
import 'package:photos/filen/filen_upload.dart';
import "package:photos/main.dart" show isProcessBg;
import "package:photos/models/backup/backup_item.dart";
import 'package:photos/models/file/file.dart';
import 'package:photos/module/upload/model/media_upload_data.dart';
import 'package:photos/module/upload/service/upload_artifact_lifecycle.dart';
import 'package:photos/module/upload/service/upload_queue.dart';
import "package:photos/module/upload/upload_data.dart";
import 'package:photos/services/collections_service.dart';
import "package:photos/services/process_activity.dart"
    show isBackgroundEngineActive;
import 'package:photos/services/sync/local_sync_service.dart';
import 'package:photos/services/sync/sync_service.dart';
import "package:photos/utils/device_storage_error.dart";
import "package:photos/utils/network_util.dart";
import 'package:shared_preferences/shared_preferences.dart';

class FileUploader {
  static const kMaximumConcurrentUploads = 4;
  static const kMaximumConcurrentVideoUploads = 2;
  static const kMaxFileSize10Gib = 10737418240;
  static const kMaxFileSize20Gib = 21474836480;
  static const kBlockedUploadsPollFrequency = Duration(seconds: 2);
  static const _longRunningUploadThreshold = Duration(minutes: 50);
  static const k20MBStorageBuffer = 20 * 1024 * 1024;
  static const _lastStaleFileCleanupTime = "lastStaleFileCleanupTime";

  final _logger = Logger("FileUploader");
  final _queue = UploadQueue(
    (change) => Bus.instance.fire(BackupUpdatedEvent(change)),
  );
  final _uploadLocks = UploadLocksDB.instance;
  final _uploadArtifactLifecycle = UploadArtifactLifecycle(
    UploadLocksDB.instance,
    FilesDB.instance,
  );
  final kSafeBufferForLockExpiry = const Duration(hours: 4).inMicroseconds;
  Map<String, BackupItem> get allBackups => _queue.backupItems;

  bool get isUploading => _queue.isUploading;

  bool get hasPendingUploads => _queue.hasPendingUploads;
  late ProcessType _processType;
  late SharedPreferences _prefs;
  bool _hasStartedBackgroundUploadPolling = false;

  StreamSubscription<LocalPhotosUpdatedEvent>? _localPhotosUpdatedSubscription;

  FileUploader._privateConstructor();

  static FileUploader instance = FileUploader._privateConstructor();

  Future<void> init(SharedPreferences preferences, bool isBackground) async {
    _prefs = preferences;
    _processType = isBackground
        ? ProcessType.background
        : ProcessType.foreground;
    final currentTime = DateTime.now().microsecondsSinceEpoch;
    await _uploadLocks.releaseLocksAcquiredByOwnerBefore(
      _processType.toString(),
      currentTime,
    );
    await _uploadLocks.releaseAllLocksAcquiredBefore(
      currentTime - kSafeBufferForLockExpiry,
    );
    if (!isBackground) {
      final isBGTaskDead = !await isBackgroundEngineActive();
      if (isBGTaskDead) {
        await _uploadLocks.releaseLocksAcquiredByOwnerBefore(
          ProcessType.background.toString(),
          currentTime,
        );
        _logger.info("BG task was found dead, cleared all locks");
      } else {
        _logger.info("BG task is alive, not clearing locks");
      }
      if (!_hasStartedBackgroundUploadPolling) {
        _hasStartedBackgroundUploadPolling = true;
        // ignore: unawaited_futures
        _pollBackgroundUploadStatus();
      }
    }
    if (currentTime - (_prefs.getInt(_lastStaleFileCleanupTime) ?? 0) >
        tempDirCleanUpInterval) {
      await removeStaleFiles();
      await _prefs.setInt(_lastStaleFileCleanupTime, currentTime);
    }
    if (_localPhotosUpdatedSubscription != null) {
      await _localPhotosUpdatedSubscription!.cancel();
    }
    _localPhotosUpdatedSubscription = Bus.instance
        .on<LocalPhotosUpdatedEvent>()
        .listen((event) {
          if (event.type == EventType.deletedFromDevice ||
              event.type == EventType.deletedFromEverywhere) {
            final deletedGeneratedIDs = event.updatedFiles
                .map((file) => file.generatedID)
                .toSet();
            removeFromQueueWhere(
              (file) => deletedGeneratedIDs.contains(file.generatedID),
              InvalidFileError(
                "File already deleted",
                InvalidReason.assetDeletedEvent,
              ),
            );
          }
        });
  }

  Future<EnteFile> upload(EnteFile file, int collectionID) {
    if (file.localID == null || file.localID!.isEmpty) {
      return Future.error(Exception("file's localID can not be null or empty"));
    }
    final request = _queue.add(file, collectionID);
    if (request.disposition == UploadQueueDisposition.added) {
      _pollQueue();
      return request.item.completer.future;
    }
    if (request.disposition == UploadQueueDisposition.sameCollection) {
      return request.item.completer.future;
    }
    debugPrint(
      "Wait on another upload on same local ID to finish before "
      "adding it to new collection",
    );
    return request.item.completer.future.then((uploadedFile) async {
      _logger.info(
        "original upload completer resolved, try adding the file to another "
        "collection",
      );

      final fileInCollection = uploadedFile.copyWith();
      await CollectionsService.instance.addOrCopyToCollection(collectionID, [
        fileInCollection,
      ]);
      return fileInCollection;
    });
  }

  int getCurrentSessionUploadCount() {
    return _queue.sessionUploadCount;
  }

  void clearQueue(final Error reason) {
    _queue.clear(reason);
  }

  void removeFromQueueWhere(
    final bool Function(EnteFile) fn,
    final Error reason,
  ) {
    final removedCount = _queue.removeWhere(fn, reason);
    _logger.info('number of entries removed from queue $removedCount');
  }

  void _pollQueue() {
    if (SyncService.instance.shouldStopSync()) {
      clearQueue(SyncStopRequestedError());
      return;
    }
    final pendingItem = _queue.startNext(
      maximumConcurrentUploads: kMaximumConcurrentUploads,
      maximumConcurrentVideoUploads: kMaximumConcurrentVideoUploads,
    );
    if (pendingItem != null) {
      _encryptAndUploadFileToCollection(pendingItem);
    }
  }

  Future<EnteFile?> _encryptAndUploadFileToCollection(
    UploadQueueItem item, {
    bool forcedUpload = false,
  }) async {
    final file = item.file;
    final collectionID = item.collectionID;
    final stopwatch = Stopwatch()..start();
    try {
      final uploadedFile = await _tryToUpload(
        file,
        collectionID,
        forcedUpload,
        onSendProgress: (sent, total) =>
            _queue.updateBackupProgress(item, file.localID!, sent, total),
      );
      stopwatch.stop();
      if (stopwatch.elapsed >= _longRunningUploadThreshold) {
        _logger.info(
          "Long-running upload completed in ${stopwatch.elapsed} for ${file.tag}",
        );
      }
      _queue.complete(item, uploadedFile);
      return uploadedFile;
    } catch (e) {
      if (e is LockAlreadyAcquiredError &&
          _processType == ProcessType.foreground) {
        return _queue.moveToBackground(item);
      }
      if (isDeviceStorageFullError(e)) {
        final error = DeviceStorageFullError();
        _logger.warning("Device storage is full for ${file.tag}", e);
        SyncService.instance.stopSync();
        clearQueue(error);
        _queue.fail(item, error);
        return null;
      }
      _queue.fail(item, e);
      return null;
    } finally {
      _queue.finishAttempt(item);
      _pollQueue();
    }
  }

  Future<void> removeStaleFiles() =>
      _uploadArtifactLifecycle.removeStaleFiles();

  Future<void> checkNetworkForUpload({bool isForceUpload = false}) async {
    if (isForceUpload) {
      return;
    }
    final canUploadUnderCurrentNetworkConditions = await canUseHighBandwidth();

    if (!canUploadUnderCurrentNetworkConditions) {
      throw WiFiUnavailableError();
    }
  }

  Future<void> verifyMediaLocationAccess() async {
    if (Platform.isAndroid) {
      final bool hasPermission = await Permission.accessMediaLocation.isGranted;
      if (!hasPermission) {
        if (isProcessBg) {
          _logger.severe(
            "Media location access not granted in background isolate - cannot request permission",
          );
          throw NoMediaLocationAccessError();
        }
        final permissionStatus = await Permission.accessMediaLocation.request();
        if (!permissionStatus.isGranted) {
          _logger.severe(
            "Media location access denied with permission status: ${permissionStatus.name}",
          );
          throw NoMediaLocationAccessError();
        }
      }
    }
  }

  Future<EnteFile> forceUpload(EnteFile file, int collectionID) {
    return _uploadArtifactLifecycle.runForceUpload(() async {
      final localID = file.localID!;
      final backupOwner = _queue.backupOwner(localID);
      if (backupOwner != null) {
        _queue.markBackupUploading(backupOwner, localID);
      }
      try {
        final result = await _tryToUpload(
          file,
          collectionID,
          true,
          onSendProgress: backupOwner == null
              ? null
              : (sent, total) => _queue.updateBackupProgress(
                  backupOwner,
                  localID,
                  sent,
                  total,
                ),
        );
        if (backupOwner != null) {
          _queue.markBackupUploaded(backupOwner, localID);
        }
        return result;
      } catch (error) {
        if (backupOwner != null) {
          _queue.markBackupForRetry(backupOwner, localID, error);
        }
        rethrow;
      }
    });
  }

  Future<EnteFile> _tryToUpload(
    EnteFile file,
    int collectionID,
    bool forcedUpload, {
    ProgressCallback? onSendProgress,
  }) async {
    await checkNetworkForUpload(isForceUpload: forcedUpload);
    if (!forcedUpload) {
      final fileOnDisk = await FilesDB.instance.getFile(file.generatedID!);
      final wasAlreadyUploaded =
          fileOnDisk != null &&
          fileOnDisk.uploadedFileID != null &&
          (fileOnDisk.updationTime ?? -1) != -1 &&
          (fileOnDisk.collectionID ?? -1) == collectionID;
      if (wasAlreadyUploaded) {
        _logger.info("File is already uploaded ${fileOnDisk.tag}");
        return fileOnDisk;
      }
    }

    if ((file.localID ?? '') == '') {
      _logger.severe('Trying to upload file with missing localID');
      return file;
    }
    if (!CollectionsService.instance.allowUpload(collectionID)) {
      _logger.warning('Upload not allowed for collection $collectionID');
      if (!file.isUploaded && file.generatedID != null) {
        _logger.info("Deleting file entry for " + file.toString());
        await FilesDB.instance.deleteByGeneratedID(file.generatedID!);
      }
      return file;
    }

    final String lockKey = file.localID!;

    late final bool acquiredLock;
    try {
      acquiredLock = await _uploadLocks.tryAcquireLock(
        lockKey,
        _processType.toString(),
        DateTime.now().microsecondsSinceEpoch,
      );
    } catch (e, s) {
      _logger.severe(
        "Upload lock database failure for ${file.tag}: "
        "targetCollectionID=$collectionID, requestOwner=$_processType, "
        "forcedUpload=$forcedUpload",
        e,
        s,
      );
      rethrow;
    }
    if (!acquiredLock) {
      final lockInfo = await _uploadLocks.getLockData(lockKey);
      _logger.warning(
        "Upload already active for ${file.tag}: "
        "targetCollectionID=$collectionID, requestOwner=$_processType, "
        "forcedUpload=$forcedUpload, lock=$lockInfo",
      );
      throw LockAlreadyAcquiredError();
    }

    MediaUploadData? mediaUploadData;
    try {
      mediaUploadData = await getUploadDataFromEnteFile(file);
    } catch (e) {
      if (e is InvalidFileError) {
        _logger.severe("File upload ignored for " + file.toString(), e);
        await _onInvalidFileError(file, e);
      }
      await _uploadLocks.releaseLock(lockKey, _processType.toString());
      rethrow;
    }

    var uploadCompleted = false;
    var uploadHardFailure = false;

    try {
      // The Filen SDK encrypts and uploads the file.
      final remoteFile = await filenUploadFile(
        file,
        collectionID,
        mediaUploadData,
        onSendProgress: onSendProgress,
      );
      if (mediaUploadData.isDeleted) {
        _logger.info("File found to be deleted");
        remoteFile.localID = null;
        await FilesDB.instance.update(remoteFile);
      }
      Bus.instance.fire(
        LocalPhotosUpdatedEvent([remoteFile], source: "uploadCompleted"),
      );
      _logger.info("File upload complete for " + remoteFile.toString());
      uploadCompleted = true;
      Bus.instance.fire(FileUploadedEvent(remoteFile));
      return remoteFile;
    } catch (e, s) {
      if (isDeviceStorageFullError(e)) {
        uploadHardFailure = true;
      } else if (!(e is StorageLimitExceededError ||
          e is WiFiUnavailableError ||
          e is SilentlyCancelUploadsError ||
          e is InvalidFileError)) {
        _logger.severe("File upload failed for " + file.toString(), e, s);
      }
      if (e is InvalidFileError) {
        _logger.severe("File upload ignored for " + file.toString(), e);
        await _onInvalidFileError(file, e);
      }
      if (e is StorageLimitExceededError || e is InvalidFileError) {
        // These failures cannot be retried without user intervention.
        uploadHardFailure = true;
      }
      rethrow;
    } finally {
      await _onUploadDone(
        mediaUploadData,
        uploadCompleted,
        uploadHardFailure,
        file,
        lockKey: lockKey,
      );
    }
  }

  Future<void> _onUploadDone(
    MediaUploadData? mediaUploadData,
    bool uploadCompleted,
    bool uploadHardFailure,
    EnteFile file, {
    required String lockKey,
  }) async {
    // Shared media is copied into the app for the upload; drop the copy once it is on Filen.
    if (mediaUploadData != null &&
        uploadCompleted &&
        file.isSharedMediaToAppSandbox) {
      await deleteFileSystemEntityIfPresent(mediaUploadData.sourceFile);
    }
    await _uploadLocks.releaseLock(lockKey, _processType.toString());
  }

  Future _onInvalidFileError(EnteFile file, InvalidFileError e) async {
    try {
      final bool canIgnoreFile =
          file.localID != null &&
          file.deviceFolder != null &&
          file.title != null &&
          !file.isSharedMediaToAppSandbox;
      final bool deleteEntry =
          !file.isUploaded && (!canIgnoreFile || e.reason.isLivePhotoErr);

      if (e.reason != InvalidReason.thumbnailMissing || !canIgnoreFile) {
        _logger.severe(
          "Invalid file, localDelete: $deleteEntry, ignored: $canIgnoreFile",
          e,
        );
      }
      if (deleteEntry) {
        await FilesDB.instance.deleteLocalFile(file);
      }
      if (canIgnoreFile) {
        await LocalSyncService.instance.ignoreUpload(file, e);
      }
    } catch (e, s) {
      _logger.severe("Failed to handle invalid file error", e, s);
    }
  }

  Future<void> _pollBackgroundUploadStatus() async {
    final blockedUploads = _queue.backgroundItems;
    for (final upload in blockedUploads) {
      try {
        final file = upload.file;
        final isStillLocked = await _uploadLocks.isLocked(
          file.localID!,
          ProcessType.background.toString(),
        );
        if (!isStillLocked) {
          final dbFile = await FilesDB.instance.getFile(file.generatedID!);
          final persistedState =
              "targetCollectionID=${upload.collectionID}, "
              "backgroundLockPresent=false, "
              "persistedFile=${dbFile != null}, "
              "uploadedFileID=${dbFile?.uploadedFileID}, "
              "updationTime=${dbFile?.updationTime}, "
              "persistedCollectionID=${dbFile?.collectionID}";
          if (dbFile?.uploadedFileID != null) {
            _logger.info(
              "Background upload success detected ${file.tag}: "
              "$persistedState",
            );
            _queue.complete(upload, dbFile!);
          } else {
            _logger.warning(
              "Background upload failure detected ${file.tag}: "
              "$persistedState",
            );
            // The upload is marked as in background but has no background lock.
            // Release any foreground lock and complete it with an error.
            final releasedForegroundLocks = await _uploadLocks.releaseLock(
              file.localID!,
              ProcessType.foreground.toString(),
            );
            if (releasedForegroundLocks > 0) {
              _logger.warning(
                "Released a foreground upload lock while reconciling "
                "${file.tag}: targetCollectionID=${upload.collectionID}",
              );
            }
            _queue.fail(upload, SilentlyCancelUploadsError());
          }
        }
      } catch (e, s) {
        _logger.severe(
          "Background upload status polling stopped while checking "
          "${upload.file.tag}: targetCollectionID=${upload.collectionID}",
          e,
          s,
        );
        rethrow;
      }
    }
    Future.delayed(kBlockedUploadsPollFrequency, () async {
      await _pollBackgroundUploadStatus();
    });
  }
}

enum ProcessType { background, foreground }
