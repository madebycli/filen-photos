import 'dart:io';

import "package:ente_strings/ente_strings.dart";
import "package:flutter/material.dart";
import "package:latlong2/latlong.dart";
import 'package:logging/logging.dart';
import 'package:photo_manager/photo_manager.dart' hide LatLng;
import 'package:photos/core/configuration.dart';
import "package:photos/db/device_files_db.dart";
import 'package:photos/db/files_db.dart';
import 'package:photos/models/file/file.dart';
import "package:photos/models/file_load_result.dart";
import "package:photos/models/freeable_space_info.dart";
import "package:photos/models/metadata/file_magic.dart";
import 'package:photos/services/file_magic_service.dart';
import "package:photos/services/ignored_files_service.dart";
import "package:photos/ui/components/action_sheet_widget.dart";
import "package:photos/ui/components/buttons/button_widget.dart";
import "package:photos/ui/components/models/button_type.dart";

class FilesService {
  late Logger _logger;
  late FilesDB _filesDB;
  late Configuration _config;

  FilesService._privateConstructor() {
    _logger = Logger("FilesService");
    _filesDB = FilesDB.instance;
    _config = Configuration.instance;
  }

  static final FilesService instance = FilesService._privateConstructor();

  Future<int> getFileSize(int uploadedFileID) async {
    final files = await _filesDB.getFilesFromIDs([uploadedFileID]);
    return files.isEmpty ? 0 : (files.first.fileSize ?? 0);
  }

  /// File sizes come with Filen's listing, so there is nothing to back fill.
  Future<bool> hasMigratedSizes() async => true;

  Future<FreeableSpaceInfo> getFreeableSpaceInfo({String? pathID}) async {
    // PhotoManager cannot delete iCloud shared-album assets.
    final excludeLocalIDs = await _getICloudSharedAlbumAssetIDs();
    FreeableFileIDs ids;
    final bool hasMigratedSize = await FilesService.instance.hasMigratedSizes();
    if (pathID == null) {
      ids = await FilesDB.instance.getFreeableFileIDs(
        ownerID: Configuration.instance.getUserID()!,
        excludeLocalIDs: excludeLocalIDs,
      );
    } else {
      ids = await FilesDB.instance.getFreeableFileIDsForDeviceCollection(
        pathID,
        Configuration.instance.getUserID()!,
        excludeLocalIDs: excludeLocalIDs,
      );
    }
    return FreeableSpaceInfo(ids.localIDs, ids.localSize);
  }

  Future<List<AssetPathEntity>> _getICloudSharedAlbumPaths() async {
    if (!Platform.isIOS) return [];
    return PhotoManager.getAssetPathList(
      hasAll: false,
      type: RequestType.common,
      pathFilterOption: const PMPathFilter(
        darwin: PMDarwinPathFilter(
          type: [PMDarwinAssetCollectionType.album],
          subType: [PMDarwinAssetCollectionSubtype.albumCloudShared],
        ),
      ),
    );
  }

  Future<Set<String>> _getICloudSharedAlbumAssetIDs() async {
    final paths = await _getICloudSharedAlbumPaths();
    final Set<String> sharedIDs = {};
    for (final path in paths) {
      final count = await path.assetCountAsync;
      final assets = await path.getAssetListRange(start: 0, end: count);
      for (final asset in assets) {
        sharedIDs.add(asset.id);
      }
    }
    _logger.info("Found ${sharedIDs.length} assets in iCloud shared albums");
    return sharedIDs;
  }

  Future<Set<String>> getICloudSharedAlbumPathIDs() async {
    final paths = await _getICloudSharedAlbumPaths();
    return paths.map((p) => p.id).toSet();
  }

  Future<void> bulkEditLocationData(
    List<EnteFile> files,
    LatLng location,
    BuildContext context,
  ) async {
    final List<EnteFile> uploadedFiles = files
        .where((element) => element.uploadedFileID != null)
        .toList();

    final List<EnteFile> remoteFilesToUpdate = [];
    final Map<int, Map<String, dynamic>> fileIDToUpdateMetadata = {};
    await showActionSheet(
      context: context,
      body: context.strings.changeLocationOfSelectedItems,
      buttons: [
        ButtonWidget(
          labelText: context.strings.yes,
          buttonType: ButtonType.neutral,
          buttonSize: ButtonSize.large,
          shouldStickToDarkTheme: true,
          buttonAction: ButtonAction.first,
          shouldSurfaceExecutionStates: true,
          isInAlert: true,
          onTap: () async {
            await _editLocationData(
              uploadedFiles,
              fileIDToUpdateMetadata,
              remoteFilesToUpdate,
              location,
            );
          },
        ),
        ButtonWidget(
          labelText: context.strings.cancel,
          buttonType: ButtonType.secondary,
          buttonSize: ButtonSize.large,
          shouldStickToDarkTheme: true,
          buttonAction: ButtonAction.cancel,
          isInAlert: true,
        ),
      ],
    );
  }

  Future<void> _editLocationData(
    List<EnteFile> uploadedFiles,
    Map<int, Map<String, dynamic>> fileIDToUpdateMetadata,
    List<EnteFile> remoteFilesToUpdate,
    LatLng location,
  ) async {
    for (EnteFile remoteFile in uploadedFiles) {
      if (remoteFile.ownerID != _config.getUserID()! ||
          fileIDToUpdateMetadata.containsKey(remoteFile.uploadedFileID!)) {
        continue;
      }

      remoteFilesToUpdate.add(remoteFile);
      fileIDToUpdateMetadata[remoteFile.uploadedFileID!] = {
        latKey: location.latitude,
        longKey: location.longitude,
      };
    }

    if (remoteFilesToUpdate.isNotEmpty) {
      await FileMagicService.instance.updatePublicMagicMetadata(
        remoteFilesToUpdate,
        null,
        metadataUpdateMap: fileIDToUpdateMetadata,
      );
    }
  }

  Future<void> removeIgnoredFiles(Future<FileLoadResult> result) async {
    final ignoredIDs = await IgnoredFilesService.instance.idToIgnoreReasonMap;
    (await result).files.removeWhere(
      (f) =>
          f.uploadedFileID == null &&
          IgnoredFilesService.instance.shouldSkipUpload(ignoredIDs, f),
    );
  }
}
