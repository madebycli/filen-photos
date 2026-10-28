import "dart:async";

import "package:ente_strings/ente_strings.dart";
import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import "package:photos/core/configuration.dart";
import "package:photos/core/constants.dart";
import 'package:photos/core/event_bus.dart';
import "package:photos/db/files_db.dart";
import 'package:photos/events/files_updated_event.dart';
import 'package:photos/events/local_photos_updated_event.dart';
import 'package:photos/models/collection/collection.dart';
import 'package:photos/models/file/file.dart';
import "package:photos/models/metadata/collection_magic.dart";
import "package:photos/models/metadata/common_keys.dart";
import 'package:photos/services/collections_service.dart';
import 'package:photos/ui/notification/toast.dart';
import 'package:photos/utils/dialog_util.dart';

class HiddenCleanupItem {
  final EnteFile file;
  final int nonHiddenCollectionID;
  final int hiddenCollectionID;

  HiddenCleanupItem({
    required this.file,
    required this.nonHiddenCollectionID,
    required this.hiddenCollectionID,
  });

  bool get isNonHiddenCollectionOwnedByUser {
    final userID = Configuration.instance.getUserID()!;
    final collection = CollectionsService.instance.getCollectionByID(
      nonHiddenCollectionID,
    );
    return collection?.isOwner(userID) ?? false;
  }

  bool get isHiddenCollectionOwnedByUser {
    final userID = Configuration.instance.getUserID()!;
    final collection = CollectionsService.instance.getCollectionByID(
      hiddenCollectionID,
    );
    return collection?.isOwner(userID) ?? false;
  }

  bool get isActionable => isNonHiddenCollectionOwnedByUser;

  int get fromCollectionID => nonHiddenCollectionID;

  int get toCollectionID {
    if (isHiddenCollectionOwnedByUser) {
      return hiddenCollectionID;
    }
    return CollectionsService.instance.cachedDefaultHiddenCollection!.id;
  }
}

extension HiddenService on CollectionsService {
  static final _logger = Logger("HiddenCollectionService");

  Future<Collection> getDefaultHiddenCollection() async {
    Collection? defaultHidden;
    if (cachedDefaultHiddenCollection != null) {
      return cachedDefaultHiddenCollection!;
    }
    final int userID = config.getUserID()!;
    final allDefaultHidden = collectionIDToCollections.values
        .where(
          (element) => element.isDefaultHidden() && element.owner.id == userID,
        )
        .toList();

    if (allDefaultHidden.length > 1) {
      defaultHidden = await clubAllDefaultHiddenToOne(allDefaultHidden);
    } else if (allDefaultHidden.length == 1) {
      defaultHidden = allDefaultHidden.first;
    }

    if (defaultHidden != null) {
      cachedDefaultHiddenCollection = defaultHidden;
      return cachedDefaultHiddenCollection!;
    }

    final Collection createdHiddenCollection =
        await _createDefaultHiddenAlbum();
    cachedDefaultHiddenCollection = createdHiddenCollection;
    return cachedDefaultHiddenCollection!;
  }

  Future<Collection> clubAllDefaultHiddenToOne(
    List<Collection> allDefaultHidden,
  ) async {
    final Collection defaultHidden = allDefaultHidden.first;
    for (Collection hidden in allDefaultHidden) {
      try {
        if (hidden.id == defaultHidden.id) {
          continue;
        }
        final filesInCollection = (await FilesDB.instance.getFilesInCollection(
          hidden.id,
          galleryLoadStartTime,
          galleryLoadEndTime,
        )).files;
        await move(
          filesInCollection,
          toCollectionID: defaultHidden.id,
          fromCollectionID: hidden.id,
        );
        await CollectionsService.instance.trashEmptyCollection(hidden);
      } catch (e, s) {
        _logger.severe(
          "One iteration of clubbing all default hidden failed",
          e,
          s,
        );
        continue;
      }
    }

    return defaultHidden;
  }

  Future<bool> hideFiles(
    BuildContext context,
    List<EnteFile> filesToHide, {
    bool forceHide = false,
  }) async {
    final int userID = config.getUserID()!;
    final List<int> uploadedIDs = <int>[];
    final dialog = createProgressDialog(context, "Hiding...");
    await dialog.show();
    try {
      for (EnteFile file in filesToHide) {
        if (file.uploadedFileID == null) {
          throw AssertionError("Can only hide uploaded files");
        }
        if (file.ownerID != userID) {
          throw AssertionError("Can only hide files owned by user");
        }
        uploadedIDs.add(file.uploadedFileID!);
      }

      final defaultHiddenCollection = await getDefaultHiddenCollection();
      final Map<int, List<EnteFile>> collectionToFilesMap = await filesDB
          .getAllFilesGroupByCollectionID(uploadedIDs);
      for (MapEntry<int, List<EnteFile>> entry
          in collectionToFilesMap.entries) {
        if (entry.key == defaultHiddenCollection.id) {
          _logger.info('file already part of hidden collection');
          continue;
        }
        final Collection? c = getCollectionByID(entry.key);
        if (c != null && !c.isOwner(userID)) {
          await removeFromCollection(entry.key, entry.value);
        } else {
          await move(
            entry.value,
            toCollectionID: defaultHiddenCollection.id,
            fromCollectionID: entry.key,
          );
        }
      }
      Bus.instance.fire(
        LocalPhotosUpdatedEvent(
          filesToHide,
          type: EventType.hide,
          source: "hideFiles",
        ),
      );

      await dialog.hide();
    } on AssertionError catch (e) {
      await dialog.hide();
      if (!context.mounted) return false;
      unawaited(
        showErrorDialog(context, context.strings.oops, e.message as String),
      );
      return false;
    } catch (e, s) {
      _logger.severe("Could not hide", e, s);
      await dialog.hide();
      if (!context.mounted) return false;
      await showGenericErrorDialog(context: context, error: e);
      return false;
    } finally {
      await dialog.hide();
    }
    return true;
  }

  Future<Collection> createHiddenAlbum(String name) async {
    _logger.info("Creating Hidden Collection");
    final collection = await createCollection(
      name: name,
      magicMetadata: CollectionMagicMetadata(
        visibility: hiddenVisibility,
        subType: 0,
      ).toJson(),
    );
    _logger.info("Hidden Collection created");
    return collection;
  }

  Future<Collection> _createDefaultHiddenAlbum() async {
    _logger.info("Creating Default Hidden Collection");
    final collection = await createCollection(
      name: ".Hidden",
      magicMetadata: CollectionMagicMetadata(
        visibility: hiddenVisibility,
        subType: subTypeDefaultHidden,
      ).toJson(),
    );
    _logger.info("Default Hidden Collection created");
    return collection;
  }

  Future<bool> hasHiddenFilesOnDevice() async {
    final userID = config.getUserID();
    if (userID == null) {
      return false;
    }
    final hiddenCollectionIds = getHiddenCollectionIds();
    if (hiddenCollectionIds.isEmpty) {
      return false;
    }
    return filesDB.hasHiddenFilesWithLocalCopy(hiddenCollectionIds, userID);
  }

  Future<List<EnteFile>> getHiddenFilesOnDevice() async {
    final userID = config.getUserID();
    if (userID == null) {
      return [];
    }
    final hiddenCollectionIds = getHiddenCollectionIds();
    if (hiddenCollectionIds.isEmpty) {
      return [];
    }
    return filesDB.getHiddenFilesWithLocalCopy(hiddenCollectionIds, userID);
  }

  Future<bool> hasFilesNeedingHiddenCleanup() async {
    final int userID = config.getUserID()!;
    final hiddenCollectionIds = getHiddenCollectionIds();
    if (hiddenCollectionIds.isEmpty) {
      return false;
    }

    final uploadedHiddenFileIds = await filesDB.getUploadedFileIDsInCollections(
      hiddenCollectionIds,
      ownerID: userID,
    );
    if (uploadedHiddenFileIds.isEmpty) {
      return false;
    }

    final allCollectionIdsHiddenFilesExistsIn = await filesDB
        .getCollectionIDsForUploadedFileIDs(uploadedHiddenFileIds);

    for (final collectionId in allCollectionIdsHiddenFilesExistsIn) {
      if (hiddenCollectionIds.contains(collectionId)) {
        continue;
      }

      final collection = getCollectionByID(collectionId);
      if (collection != null && collection.isOwner(userID)) {
        return true;
      }
    }

    return false;
  }

  Future<List<HiddenCleanupItem>> getFilesNeedingHiddenCleanup() async {
    final int userID = config.getUserID()!;
    final hiddenCollectionIds = getHiddenCollectionIds();
    if (hiddenCollectionIds.isEmpty) {
      return [];
    }

    final uploadedHiddenFileIds = await filesDB.getUploadedFileIDsInCollections(
      hiddenCollectionIds,
      ownerID: userID,
    );
    if (uploadedHiddenFileIds.isEmpty) {
      return [];
    }

    final filesByCollectionID = await filesDB.getAllFilesGroupByCollectionID(
      uploadedHiddenFileIds,
    );

    final Map<int, int> fileToHiddenCollection = {};
    for (final entry in filesByCollectionID.entries) {
      final collectionID = entry.key;
      if (hiddenCollectionIds.contains(collectionID)) {
        for (final file in entry.value) {
          if (file.uploadedFileID != null) {
            fileToHiddenCollection.putIfAbsent(
              file.uploadedFileID!,
              () => collectionID,
            );
          }
        }
      }
    }

    final cleanupItems = <HiddenCleanupItem>[];
    for (final entry in filesByCollectionID.entries) {
      final collectionID = entry.key;

      if (hiddenCollectionIds.contains(collectionID)) {
        continue;
      }

      final collection = getCollectionByID(collectionID);
      if (collection == null) {
        continue;
      }

      for (final file in entry.value) {
        if (file.ownerID != userID) {
          continue;
        }

        final hiddenCollectionID = fileToHiddenCollection[file.uploadedFileID];
        if (hiddenCollectionID == null) {
          continue;
        }

        cleanupItems.add(
          HiddenCleanupItem(
            file: file,
            nonHiddenCollectionID: collectionID,
            hiddenCollectionID: hiddenCollectionID,
          ),
        );
      }
    }

    return cleanupItems;
  }

  Future<void> cleanupHiddenFiles(BuildContext context) async {
    final dialog = createProgressDialog(context, context.strings.pleaseWait);
    await dialog.show();

    try {
      final cleanupItems = await getFilesNeedingHiddenCleanup();

      if (cleanupItems.isEmpty) {
        await dialog.hide();
        return;
      }

      final actionableItems = cleanupItems
          .where((item) => item.isActionable)
          .toList();
      final nonActionableItems = cleanupItems
          .where((item) => !item.isActionable)
          .toList();

      for (final item in nonActionableItems) {
        _logger.info(
          "Should not clean up file ${item.file.uploadedFileID} from collection "
          "${item.nonHiddenCollectionID} - user doesn't own the collection",
        );
      }

      final Map<(int, int), List<EnteFile>> moveGroups = {};
      for (final item in actionableItems) {
        final key = (item.fromCollectionID, item.toCollectionID);
        moveGroups.putIfAbsent(key, () => []).add(item.file);
      }

      for (final entry in moveGroups.entries) {
        final (fromCollectionID, toCollectionID) = entry.key;
        final files = entry.value;

        await move(
          files,
          toCollectionID: toCollectionID,
          fromCollectionID: fromCollectionID,
        );
      }

      final allMovedFiles = actionableItems.map((e) => e.file).toList();
      if (allMovedFiles.isNotEmpty) {
        Bus.instance.fire(
          FilesUpdatedEvent(allMovedFiles, source: "hiddenCleanup"),
        );
      }

      await dialog.hide();
      if (!context.mounted) return;
      showShortToast(context, context.strings.cleanupComplete);
    } catch (e, s) {
      _logger.severe("Failed to cleanup hidden files", e, s);
      await dialog.hide();
      if (!context.mounted) return;
      await showGenericErrorDialog(context: context, error: e);
    }
  }
}
