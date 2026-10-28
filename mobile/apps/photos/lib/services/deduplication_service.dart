import 'package:logging/logging.dart';
import 'package:photos/models/duplicate_files.dart';
import "package:photos/models/file/extensions/file_props.dart";
import 'package:photos/models/file/file.dart';
import "package:photos/models/file/file_type.dart";
import "package:photos/services/collections_service.dart";
import "package:photos/services/search_service.dart";

class DeduplicationService {
  final _logger = Logger("DeduplicationService");

  DeduplicationService._privateConstructor();

  static final DeduplicationService instance =
      DeduplicationService._privateConstructor();

  Future<List<DuplicateFiles>> getDuplicateFiles() async {
    try {
      final List<DuplicateFiles> result = await _getDuplicateFiles();
      return result;
    } catch (e, s) {
      _logger.severe("failed to get dedupeFile", e, s);
      rethrow;
    }
  }

  Future<List<DuplicateFiles>> _getDuplicateFiles() async {
    final Set<int> allowedCollectionIDs = CollectionsService.instance
        .nonHiddenOwnedCollections();

    final List<EnteFile> allFiles = await SearchService.instance
        .getAllFilesForSearch();
    final List<EnteFile> filteredFiles = [];
    for (final file in allFiles) {
      if (!file.isUploaded ||
          (file.hash ?? '').isEmpty ||
          !file.isOwner ||
          (!allowedCollectionIDs.contains(file.collectionID!))) {
        continue;
      }
      if ((file.fileSize ?? 0) <= 0) {
        continue;
      }
      filteredFiles.add(file);
    }

    final Map<String, List<EnteFile>> sizeHashToFilesMap = {};
    final Map<String, Set<int>> sizeHashToCollectionsSet = {};
    final Map<String, List<EnteFile>> livePhotoHashToFilesMap = {};
    final Map<String, Set<int>> livePhotoHashToCollectionsSet = {};
    final Set<int> processedFileIds = <int>{};
    for (final file in filteredFiles) {
      // Equivalent live photos can have different archive sizes across devices.
      if (file.fileType == FileType.livePhoto) {
        final key = '${file.hash}';
        if (!livePhotoHashToFilesMap.containsKey(key)) {
          livePhotoHashToFilesMap[key] = <EnteFile>[];
          livePhotoHashToCollectionsSet[key] = <int>{};
        }
        livePhotoHashToCollectionsSet[key]!.add(file.collectionID!);
        if (!processedFileIds.contains(file.uploadedFileID)) {
          livePhotoHashToFilesMap[key]!.add(file);
          processedFileIds.add(file.uploadedFileID!);
        }
      } else {
        final key = '${file.fileSize}-${file.hash}';
        if (!sizeHashToFilesMap.containsKey(key)) {
          sizeHashToFilesMap[key] = <EnteFile>[];
          sizeHashToCollectionsSet[key] = <int>{};
        }
        sizeHashToCollectionsSet[key]!.add(file.collectionID!);
        if (!processedFileIds.contains(file.uploadedFileID)) {
          sizeHashToFilesMap[key]!.add(file);
          processedFileIds.add(file.uploadedFileID!);
        }
      }
    }
    final List<DuplicateFiles> dupesByHash = [];
    for (final key in sizeHashToFilesMap.keys) {
      final List<EnteFile> files = sizeHashToFilesMap[key]!;
      final Set<int> collectionIds = sizeHashToCollectionsSet[key]!;
      if (files.length > 1) {
        final size = files[0].fileSize!;
        dupesByHash.add(DuplicateFiles(files, size, collectionIds));
      }
    }
    for (final key in livePhotoHashToFilesMap.keys) {
      final List<EnteFile> files = livePhotoHashToFilesMap[key]!;
      final Set<int> collectionIds = livePhotoHashToCollectionsSet[key]!;
      if (files.length > 1 && (files.first.fileSize ?? 0) > 0) {
        dupesByHash.add(
          DuplicateFiles(files, files.first.fileSize!, collectionIds),
        );
      }
    }
    return dupesByHash;
  }
}
