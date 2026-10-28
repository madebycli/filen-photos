import 'dart:io';

import 'package:logging/logging.dart';
import 'package:path/path.dart' as file_path;
import "package:photo_manager/photo_manager.dart";
import "package:photos/core/event_bus.dart";
import "package:photos/db/device_files_db.dart";
import "package:photos/db/files_db.dart";
import "package:photos/events/local_photos_updated_event.dart";
import 'package:photos/models/file/file.dart';
import "package:photos/models/file/file_type.dart";
import "package:photos/module/download/download_error.dart";
import "package:photos/module/download/file.dart";
import "package:photos/services/sync/local_sync_service.dart";
import "package:photos/utils/device_storage_error.dart";
import "package:photos/utils/gallery_save_title.dart";

final _logger = Logger("file_download_util");

String getDownloadSkipToastFileName(EnteFile file) {
  final title = (file.title ?? "").trim();
  final displayName = file.displayName.trim();
  return title.isNotEmpty ? title : displayName;
}

String _getGallerySaveTitle(EnteFile file, String fallbackPath) {
  final displayName = file.displayName;
  final title = displayName.trim().isNotEmpty
      ? displayName
      : ((file.title != null && file.title!.trim().isNotEmpty)
            ? file.title!
            : file_path.basename(fallbackPath));
  if (file.fileType == FileType.image &&
      file_path.extension(title).isEmpty &&
      file_path.extension(fallbackPath).toLowerCase() == ".unknown") {
    return "$title.jpg";
  }
  return title;
}

Future<String?> getExistingLocalFolderNameForDownloadSkipToast(
  EnteFile file,
) async {
  if (file.localID == null) {
    return null;
  }
  final asset = await file.getAsset;
  if (asset == null || !(await asset.exists)) {
    return null;
  }
  final folderNames = await FilesDB.instance.getDeviceCollectionNamesForLocalID(
    file.localID!,
  );
  if (folderNames.isNotEmpty) {
    return folderNames.last;
  }
  // The asset exists on device but no device-collection mapping is recorded
  // yet (e.g. LocalSyncService hasn't ingested it). Treat this as "not
  // skippable" rather than crashing; a duplicate save is preferable to an
  // unhandled StateError surfacing in the download flow.
  _logger.severe(
    "No device collection name found for localID=${file.localID} "
    "despite asset existing on device.",
  );
  return null;
}

Future<void> downloadToGallery(
  EnteFile file, {
  bool forceResumableDownload = false,
  bool persistToFilesDB = true,
}) async {
  try {
    final FileType type = file.fileType;
    AssetEntity? savedAsset;
    final File? fileToSave = await getFile(
      file,
      forGalleryDownload: forceResumableDownload,
    );
    if (fileToSave == null) {
      throw DownloadFailedError("Unable to fetch file for gallery download");
    }
    final galleryTitle = _getGallerySaveTitle(file, fileToSave.path);
    final mediaStoreTitle = await getMediaStoreCompatibleTitle(galleryTitle);
    // Keep sync from seeing the saved asset before it is inserted into FilesDB.
    // https://github.com/ente/ente/issues/4296
    await LocalSyncService.instance.getLock().synchronized(() async {
      await PhotoManager.stopChangeNotify();
      if (type == FileType.image) {
        savedAsset = await PhotoManager.editor.saveImageWithPath(
          fileToSave.path,
          title: mediaStoreTitle,
        );
      } else if (type == FileType.video) {
        savedAsset = await PhotoManager.editor.saveVideo(
          fileToSave,
          title: mediaStoreTitle,
        );
      }

      if (savedAsset != null) {
        if (persistToFilesDB) {
          file.localID = savedAsset!.id;
          await FilesDB.instance.insert(file);
          Bus.instance.fire(
            LocalPhotosUpdatedEvent([file], source: "download"),
          );
        }
      } else {
        _logger.severe('Failed to save asset of type $type');
      }
    });
  } catch (e, s) {
    if (forceResumableDownload && isDeviceStorageFullError(e)) {
      _logger.severe("Failed to save file due to storage limit", e, s);
      throw const DeviceStorageFullException();
    }
    _logger.severe("Failed to save file", e, s);
    rethrow;
  } finally {
    await PhotoManager.startChangeNotify();
    LocalSyncService.instance.checkAndSync().ignore();
  }
}
