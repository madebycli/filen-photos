import 'dart:async';
import 'dart:io';

import "package:dio/dio.dart" show ProgressCallback;
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:logging/logging.dart';
import 'package:motionphoto/motionphoto.dart';
import 'package:path/path.dart';
import 'package:photos/core/cache/image_cache.dart';
import 'package:photos/core/cache/thumbnail_in_memory_cache.dart';
import 'package:photos/core/cache/video_cache_manager.dart';
import 'package:photos/core/configuration.dart';
import 'package:photos/core/constants.dart';
import 'package:photos/filen/filen_file_access.dart';
import 'package:photos/filen/filen_ids.dart';
import "package:photos/models/file/extensions/file_props.dart";
import 'package:photos/models/file/file.dart';
import 'package:photos/models/file/file_type.dart';

final _logger = Logger("FileUtil");

void preloadFile(EnteFile file) {
  if (file.fileType == FileType.video) {
    return;
  }
  getFile(file);
}

// IMPORTANT: Delete the returned file if `isOrigin` is set to true
// https://github.com/CaiJingLong/flutter_photo_manager#cache-problem-of-ios
Future<File?> getFile(
  EnteFile file, {
  bool liveVideo = false,
  bool isOrigin = false,
  bool forGalleryDownload = false, // only relevant for live photos
  bool throwOnDecryptionFailure = false,
}) async {
  try {
    if (file.isRemoteOnlyFile) {
      return await getFileFromServer(
        file,
        liveVideo: liveVideo,
        forGalleryDownload: forGalleryDownload,
        throwOnDecryptionFailure: throwOnDecryptionFailure,
      );
    } else {
      final String key = file.tag + liveVideo.toString() + isOrigin.toString();
      final cachedFile = FileLruCache.get(key);
      if (cachedFile == null) {
        final diskFile = await _getLocalDiskFile(
          file,
          liveVideo: liveVideo,
          isOrigin: isOrigin,
        );
        // do not cache origin file for IOS as they are immediately deleted
        // after usage
        if (!(isOrigin && Platform.isIOS) && diskFile != null) {
          FileLruCache.put(key, diskFile);
        }
        return diskFile;
      }
      return cachedFile;
    }
  } catch (e, s) {
    _logger.warning("Failed to get file", e, s);
    if (forGalleryDownload || throwOnDecryptionFailure) {
      rethrow;
    }
    return null;
  }
}

Future<bool> doesLocalFileExist(EnteFile file) async {
  return await _getLocalDiskFile(file) != null;
}

Future<File?> _getLocalDiskFile(
  EnteFile file, {
  bool liveVideo = false,
  bool isOrigin = false,
}) async {
  // Return null because reading a device trash file by its file system path
  // fails with a permission-denied error.
  if (file.isDeviceTrash) {
    return null;
  }

  if (file.isSharedMediaToAppSandbox) {
    final localFile = File(getSharedMediaPathFromLocalID(file.localID!));
    return await localFile.exists() ? localFile : null;
  }

  if (file.fileType == FileType.livePhoto && liveVideo) {
    return await Motionphoto.getLivePhotoFile(file.localID!);
  }

  final asset = await file.getAsset;
  if (asset == null || !(await asset.exists)) {
    return null;
  }
  return isOrigin ? await asset.originFile : await asset.file;
}

String getSharedMediaFilePath(EnteFile file) {
  return getSharedMediaPathFromLocalID(file.localID!);
}

String getSharedMediaPathFromLocalID(String localID) {
  return Configuration.instance.getSharedMediaDirectory() +
      "/" +
      localID.replaceAll(sharedMediaIdentifier, '');
}

final Map<String, Future<File?>> _fileDownloadsInProgress =
    <String, Future<File?>>{};
final Map<String, ProgressCallback?> _progressCallbacks = {};

Future<T> _runOncePerKey<K, T>(
  Map<K, Future<T>> inProgress,
  K key,
  Future<T> Function() start, {
  void Function()? onComplete,
}) {
  final existing = inProgress[key];
  if (existing != null) {
    return existing;
  }
  final download = start();
  inProgress[key] = download;

  void removeIfCurrent() {
    if (identical(inProgress[key], download)) {
      inProgress.remove(key);
      onComplete?.call();
    }
  }

  unawaited(
    download.then<void>(
      (_) => removeIfCurrent(),
      onError: (_, _) => removeIfCurrent(),
    ),
  );
  return download;
}

void removeDownloadCallback(EnteFile file) {
  if (!file.isUploaded) {
    return;
  }
  _progressCallbacks.remove(file.uploadedFileID.toString());
}

Future<File?> getFileFromServer(
  EnteFile file, {
  ProgressCallback? progressCallback,
  bool liveVideo = false,
  bool forGalleryDownload = false,
  bool throwOnDecryptionFailure = false,
}) async {
  final cacheManager = file.fileType == FileType.video
      ? VideoCacheManager.instance
      : DefaultCacheManager();
  final fileFromCache = await cacheManager.getFileFromCache(file.downloadUrl);
  if (fileFromCache != null) {
    return fileFromCache.file;
  }
  final downloadID = file.uploadedFileID.toString();

  if (progressCallback != null) {
    _progressCallbacks[downloadID] = progressCallback;
  }

  return _runOncePerKey(
    _fileDownloadsInProgress,
    downloadID,
    () => _downloadAndCache(
      file,
      cacheManager,
      progressCallback: (count, total) {
        _progressCallbacks[downloadID]?.call(count, total);
      },
    ),
    onComplete: () => _progressCallbacks.remove(downloadID),
  );
}

Future<bool> isFileCached(EnteFile file, {bool liveVideo = false}) async {
  final cacheManager = file.fileType == FileType.video
      ? VideoCacheManager.instance
      : DefaultCacheManager();
  final fileInfo = await cacheManager.getFileFromCache(file.downloadUrl);
  return fileInfo != null;
}

Future<File?> _downloadAndCache(
  EnteFile file,
  BaseCacheManager cacheManager, {
  required ProgressCallback progressCallback,
}) async {
  if (!isFilenFile(file)) {
    throw StateError('${file.tag} is not stored on Filen');
  }
  // The Filen SDK downloads and decrypts the original.
  final decryptedFile = await filenDownloadOriginal(file);
  progressCallback(file.fileSize ?? 0, file.fileSize ?? 0);
  try {
    final decryptedFilePath = decryptedFile.path;
    String fileExtension = getExtension(file.title ?? '');
    File outputFile = decryptedFile;
    if (fileExtension == "unknown" && file.fileType == FileType.image) {
      final compressResult = await FlutterImageCompress.compressAndGetFile(
        decryptedFilePath,
        decryptedFilePath + ".jpg",
        keepExif: true,
      );
      if (compressResult == null) {
        throw Exception("Failed to convert heic to jpg");
      }
      outputFile = File(compressResult.path);
      fileExtension = "jpg";
      await decryptedFile.delete();
    }
    final cachedFile = await cacheManager.putFileStream(
      file.downloadUrl,
      outputFile.openRead(),
      eTag: file.downloadUrl,
      maxAge: const Duration(days: 365),
      fileExtension: fileExtension,
    );
    await outputFile.delete();
    return cachedFile;
  } catch (e) {
    _logger.warning("failed to download file : ${file.tag}", e);
    rethrow;
  }
}

Future<void> removeFromDownloadCache(EnteFile file) async {
  if (file.fileType == FileType.video) {
    await VideoCacheManager.instance.removeFile(file.downloadUrl);
  } else {
    await DefaultCacheManager().removeFile(file.downloadUrl);
    if (file.fileType == FileType.livePhoto) {
      await VideoCacheManager.instance.removeFile(file.downloadUrl);
    }
  }
}

String getExtension(String nameOrPath) {
  var fileExtension = "unknown";
  try {
    fileExtension = extension(nameOrPath).substring(1).toLowerCase();
  } catch (e) {
    _logger.severe("Could not capture file extension");
  }
  return fileExtension;
}

Future<void> clearCache(EnteFile file) async {
  await removeFromDownloadCache(file);
  final cachedThumbnail = File(
    Configuration.instance.getThumbnailCacheDirectory() +
        "/" +
        file.uploadedFileID.toString(),
  );
  if (cachedThumbnail.existsSync()) {
    await cachedThumbnail.delete();
  }
  ThumbnailInMemoryLruCache.clearCache(file);
}
