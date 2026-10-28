import 'package:ente_components/ente_components.dart';
import "package:ente_strings/ente_strings.dart";
import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import 'package:photos/db/files_db.dart';
import 'package:photos/models/button_result.dart';
import 'package:photos/models/collection/collection.dart';
import 'package:photos/models/file/file.dart';
import 'package:photos/services/collections_service.dart';
import 'package:photos/ui/components/buttons/button_widget.dart';
import 'package:photos/utils/dialog_util.dart';
import "package:styled_text/styled_text.dart";

class CollectionActions {
  final Logger logger = Logger((CollectionActions).toString());
  final CollectionsService collectionsService;

  CollectionActions(this.collectionsService);

  Future<bool> deleteMultipleCollectionSheet(
    BuildContext context,
    List<Collection> collections,
  ) async {
    return _showDeleteCollectionConfirmationSheet(
      context: context,
      title: context.strings.deleteMultipleAlbumsQuestion,
      message: context.strings.deleteMultipleAlbumDialog(
        count: collections.length,
      ),
      keepPhotos: () async {
        for (final collection in collections) {
          try {
            await trashCollectionKeepingPhotos(collection);
          } catch (e, s) {
            logger.severe("Failed to keep photos & delete collection", e, s);
            rethrow;
          }
        }
      },
      deletePhotos: () async {
        for (final collection in collections) {
          try {
            await collectionsService.trashNonEmptyCollection(collection);
          } catch (e) {
            logger.severe("Failed to delete collection", e);
            rethrow;
          }
        }
      },
    );
  }

  Future<bool> deleteCollectionSheet(
    BuildContext bContext,
    Collection collection,
  ) async {
    if (!bContext.mounted) return false;
    return _showDeleteCollectionConfirmationSheet(
      context: bContext,
      title: bContext.strings.deleteAlbumQuestion,
      message: bContext.strings.deleteAlbumDialog,
      keepPhotos: () async {
        try {
          await trashCollectionKeepingPhotos(collection);
        } catch (e, s) {
          logger.severe("Failed to keep photos & delete collection", e, s);
          rethrow;
        }
      },
      deletePhotos: () async {
        try {
          await collectionsService.trashNonEmptyCollection(collection);
        } catch (e) {
          logger.severe("Failed to delete collection", e);
          rethrow;
        }
      },
    );
  }

  Future<bool> _showDeleteCollectionConfirmationSheet({
    required BuildContext context,
    required String title,
    required String message,
    required Future<void> Function() keepPhotos,
    required Future<void> Function() deletePhotos,
  }) async {
    final l10n = context.strings;
    final actionResult = await showBottomSheetComponent<ButtonResult>(
      context: context,
      builder: (sheetContext) {
        final colors = sheetContext.componentColors;
        return BottomSheetComponent(
          title: title,
          illustration: Image.asset("assets/warning-grey.png"),
          closeTooltip: l10n.close,
          closeResult: ButtonResult(ButtonAction.third),
          content: StyledText(
            text: message,
            textAlign: TextAlign.center,
            style: TextStyles.body.copyWith(color: colors.textLight),
            tags: {
              'bold': StyledTextTag(
                style: TextStyles.body.copyWith(color: colors.textBase),
              ),
            },
          ),
          actions: [
            ButtonComponent(
              label: l10n.keepPhotos,
              variant: ButtonComponentVariant.neutral,
              onTap: () => _runCollectionAction(
                sheetContext,
                ButtonAction.first,
                keepPhotos,
              ),
            ),
            ButtonComponent(
              label: l10n.deletePhotos,
              variant: ButtonComponentVariant.critical,
              onTap: () => _runCollectionAction(
                sheetContext,
                ButtonAction.second,
                deletePhotos,
              ),
            ),
          ],
        );
      },
    );
    if (actionResult?.action != null &&
        actionResult!.action == ButtonAction.error) {
      if (!context.mounted) return false;
      await showGenericErrorDialog(
        context: context,
        error: actionResult.exception,
      );
      return false;
    }
    if ((actionResult?.action != null) &&
        (actionResult!.action == ButtonAction.first ||
            actionResult.action == ButtonAction.second)) {
      return true;
    }
    return false;
  }

  Future<void> _runCollectionAction(
    BuildContext context,
    ButtonAction action,
    Future<void> Function() callback,
  ) async {
    try {
      await callback();
      if (context.mounted) {
        Navigator.of(context).pop(ButtonResult(action));
      }
    } catch (error) {
      if (context.mounted) {
        Navigator.of(
          context,
        ).pop(ButtonResult(ButtonAction.error, _toException(error)));
      }
      rethrow;
    }
  }

  Exception _toException(Object error) {
    return error is Exception ? error : Exception(error.toString());
  }

  Future<void> trashCollectionKeepingPhotos(Collection collection) async {
    final List<EnteFile> files = await FilesDB.instance.getAllFilesCollection(
      collection.id,
    );
    await moveFilesFromCurrentCollection(
      null,
      collection,
      files,
      isHidden: collection.isHidden() && !collection.isDefaultHidden(),
    );
    await collectionsService.trashEmptyCollection(collection);
  }

  Future<int> removeFromUncatIfPresentInOtherAlbum(
    Collection collection,
    BuildContext bContext,
  ) async {
    try {
      final List<EnteFile> files = await FilesDB.instance.getAllFilesCollection(
        collection.id,
      );
      if (!bContext.mounted) {
        return 0;
      }
      return await moveFilesFromCurrentCollection(bContext, collection, files);
    } catch (e, s) {
      logger.severe("Failed to remove files from uncategorized", e, s);
      rethrow;
    }
  }

  // Moving a file must call the move API even if it is already in another
  // collection, because move also removes it from this one.
  Future<int> moveFilesFromCurrentCollection(
    BuildContext? context,
    Collection collection,
    Iterable<EnteFile> files, {
    bool isHidden = false,
  }) async {
    var movedFilesCount = 0;
    final Map<int, EnteFile> pendingAssignMap = {};
    final Map<int, List<EnteFile>> destCollectionToFilesMap = {};
    final List<int> uploadedIDs = [];
    for (EnteFile f in files) {
      if (f.uploadedFileID != null) {
        pendingAssignMap[f.uploadedFileID!] = f;
        uploadedIDs.add(f.uploadedFileID!);
      }
    }

    final Map<int, List<EnteFile>> collectionToFilesMap = await FilesDB.instance
        .getAllFilesGroupByCollectionID(uploadedIDs);

    // Fix files in pendingAssignMap with correct collectionID entries.
    // This is needed when files are selected after filtering by another album,
    // as the file's collectionID might point to the filtered album instead of
    // the current collection.
    final filesInCurrentCollection = collectionToFilesMap[collection.id];
    if (filesInCurrentCollection != null) {
      for (final file in filesInCurrentCollection) {
        if (file.uploadedFileID != null &&
            pendingAssignMap.containsKey(file.uploadedFileID)) {
          pendingAssignMap[file.uploadedFileID!] = file;
        }
      }
    }

    // Preserve another album membership instead of moving to Uncategorized.
    for (MapEntry<int, List<EnteFile>> entry in collectionToFilesMap.entries) {
      if (!_isAutoMoveCandidate(collection.id, entry.key)) {
        continue;
      }
      final targetCollection = collectionsService.getCollectionByID(entry.key)!;
      for (EnteFile file in entry.value) {
        if (pendingAssignMap.containsKey(file.uploadedFileID)) {
          if (!destCollectionToFilesMap.containsKey(targetCollection.id)) {
            destCollectionToFilesMap[targetCollection.id] = <EnteFile>[];
          }
          destCollectionToFilesMap[targetCollection.id]!.add(
            pendingAssignMap[file.uploadedFileID!]!,
          );
          pendingAssignMap.remove(file.uploadedFileID);
        }
      }
    }
    if (pendingAssignMap.isNotEmpty) {
      late final int toCollectionID;
      if (isHidden) {
        toCollectionID = collectionsService.cachedDefaultHiddenCollection!.id;
      } else {
        final Collection uncategorizedCollection = await collectionsService
            .getUncategorizedCollection();
        toCollectionID = uncategorizedCollection.id;
      }

      for (MapEntry<int, EnteFile> entry in pendingAssignMap.entries) {
        final file = entry.value;
        if (pendingAssignMap.containsKey(file.uploadedFileID)) {
          if (!destCollectionToFilesMap.containsKey(toCollectionID)) {
            destCollectionToFilesMap[toCollectionID] = <EnteFile>[];
          }
          destCollectionToFilesMap[toCollectionID]!.add(
            pendingAssignMap[file.uploadedFileID!]!,
          );
        }
      }
    }

    int mappedFilesCount = 0;
    destCollectionToFilesMap.forEach((key, value) {
      mappedFilesCount += value.length;
    });
    if (mappedFilesCount != uploadedIDs.length) {
      throw AssertionError(
        "Failed to map all files toMap: ${uploadedIDs.length} and mapped "
        "$mappedFilesCount",
      );
    }

    for (MapEntry<int, List<EnteFile>> entry
        in destCollectionToFilesMap.entries) {
      if (collection.type == CollectionType.uncategorized &&
          entry.key == collection.id) {
        logger.info(
          'skipping moving ${entry.value.length} files to uncategorized collection',
        );
      } else {
        final movedFilesInCollection = entry.value.length;
        await collectionsService.move(
          entry.value,
          toCollectionID: entry.key,
          fromCollectionID: collection.id,
        );
        movedFilesCount += movedFilesInCollection;
      }
    }
    return movedFilesCount;
  }

  bool _isAutoMoveCandidate(int fromCollectionID, toCollectionID) {
    if (fromCollectionID == toCollectionID) {
      return false;
    }
    final Collection? targetCollection = collectionsService.getCollectionByID(
      toCollectionID,
    );
    if (targetCollection == null ||
        targetCollection.isDeleted ||
        (CollectionType.uncategorized == targetCollection.type ||
            targetCollection.type == CollectionType.favorites)) {
      return false;
    }
    return true;
  }
}
