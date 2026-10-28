import "package:ente_strings/ente_strings.dart";
import "package:flutter/material.dart";
import "package:hugeicons/hugeicons.dart";
import "package:logging/logging.dart";
import "package:photos/core/constants.dart";
import "package:photos/db/files_db.dart";
import "package:photos/models/collection/collection.dart";
import "package:photos/models/file/file.dart";
import "package:photos/models/metadata/common_keys.dart";
import "package:photos/models/selected_albums.dart";
import "package:photos/services/collections_service.dart";
import "package:photos/ui/actions/collection/collection_sharing_actions.dart";
import "package:photos/ui/collections/collection_list_page.dart";
import "package:photos/ui/components/bottom_action_bar/selection_action_sheet.dart";
import "package:photos/ui/notification/toast.dart";
import "package:photos/ui/viewer/album_slideshow/album_slideshow.dart";
import "package:photos/utils/dialog_util.dart";
import "package:photos/utils/magic_util.dart";

class AlbumSelectionActionWidget extends StatefulWidget {
  final SelectedAlbums selectedAlbums;
  final UISectionType sectionType;
  final Widget selectionControls;
  final Color? backgroundColor;
  final ScrollController? backgroundScrollController;

  const AlbumSelectionActionWidget(
    this.selectedAlbums,
    this.sectionType, {
    required this.selectionControls,
    this.backgroundColor,
    this.backgroundScrollController,
    super.key,
  });

  @override
  State<AlbumSelectionActionWidget> createState() =>
      _AlbumSelectionActionWidgetState();
}

class _AlbumSelectionActionWidgetState
    extends State<AlbumSelectionActionWidget> {
  final _logger = Logger("AlbumSelectionActionWidgetState");
  late CollectionActions collectionActions;
  bool hasFavorites = false;

  @override
  initState() {
    collectionActions = CollectionActions(CollectionsService.instance);
    widget.selectedAlbums.addListener(_selectionChangedListener);
    super.initState();
  }

  @override
  void dispose() {
    widget.selectedAlbums.removeListener(_selectionChangedListener);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.selectedAlbums.albums.isEmpty) {
      return const SizedBox.shrink();
    }
    final List<SelectionSheetAction> items = [];
    final hasPinnedAlbum = widget.selectedAlbums.albums.any(
      (album) => album.isPinned,
    );
    final hasUnpinnedAlbum = widget.selectedAlbums.albums.any(
      (album) => !album.isPinned,
    );
    final showOwnerActions =
        widget.sectionType == UISectionType.homeCollections;

    items.add(
      SelectionSheetAction(
        labelText: context.strings.slideshow,
        hugeIcon: HugeIcons.strokeRoundedPresentation03,
        onTap: _startAlbumSlideshow,
      ),
    );

    if (showOwnerActions) {
      items.add(
        SelectionSheetAction(
          labelText: context.strings.pin,
          hugeIcon: HugeIcons.strokeRoundedPin,
          onTap: _onPinClick,
          shouldShow: hasUnpinnedAlbum,
        ),
      );

      items.add(
        SelectionSheetAction(
          labelText: context.strings.unpin,
          hugeIcon: HugeIcons.strokeRoundedPinOff,
          onTap: _onUnpinClick,
          shouldShow: hasPinnedAlbum,
        ),
      );

      items.add(
        SelectionSheetAction(
          labelText: context.strings.delete,
          hugeIcon: HugeIcons.strokeRoundedDelete01,
          onTap: _trashCollection,
          isCritical: true,
        ),
      );
      items.add(
        SelectionSheetAction(
          labelText: context.strings.hide,
          hugeIcon: HugeIcons.strokeRoundedViewOffSlash,
          onTap: _onHideOrUnHideClick,
        ),
      );
    }

    if (widget.sectionType == UISectionType.archivedCollections) {
      items.add(
        SelectionSheetAction(
          labelText: context.strings.unarchive,
          hugeIcon: HugeIcons.strokeRoundedUnarchive03,
          onTap: _archiveClick,
        ),
      );
      items.add(
        SelectionSheetAction(
          labelText: context.strings.delete,
          hugeIcon: HugeIcons.strokeRoundedDelete01,
          onTap: _trashCollection,
          isCritical: true,
        ),
      );
    } else if (widget.sectionType == UISectionType.hiddenCollections) {
      items.add(
        SelectionSheetAction(
          labelText: context.strings.unhide,
          hugeIcon: HugeIcons.strokeRoundedView,
          onTap: _onHideOrUnHideClick,
        ),
      );
      items.add(
        SelectionSheetAction(
          labelText: context.strings.delete,
          hugeIcon: HugeIcons.strokeRoundedDelete01,
          onTap: _trashCollection,
          isCritical: true,
        ),
      );
    } else {
      items.add(
        SelectionSheetAction(
          labelText: context.strings.archive,
          hugeIcon: HugeIcons.strokeRoundedArchive03,
          onTap: _archiveClick,
        ),
      );
    }

    return SelectionActionSheet(
      actions: items,
      selectionControls: widget.selectionControls,
      backgroundColor: widget.backgroundColor,
      backgroundScrollController: widget.backgroundScrollController,
    );
  }

  Future<void> _startAlbumSlideshow() async {
    final albums = widget.selectedAlbums.albums.toList(growable: false);
    final dialog = createProgressDialog(context, context.strings.pleaseWait);
    await dialog.show();

    final files = <EnteFile>[];
    try {
      for (final album in albums) {
        final fileResult = await FilesDB.instance.getFilesInCollection(
          album.id,
          galleryLoadStartTime,
          galleryLoadEndTime,
          asc: album.pubMagicMetadata.asc ?? false,
        );
        files.addAll(fileResult.files);
      }
    } finally {
      await dialog.hide();
    }
    if (!mounted) return;

    final opened = await showAlbumSlideshow(
      context,
      files: files,
      title: albums.length == 1
          ? albums.single.displayName
          : context.strings.slideshow,
    );
    if (opened && mounted) {
      widget.selectedAlbums.clearAll();
    }
  }

  Future<void> _trashCollection() async {
    int count = 0;
    final List<Collection> nonEmptyCollection = [];

    final List errors = [];
    final List<Collection> selectedAlbums = widget.selectedAlbums.albums.toList(
      growable: false,
    );
    for (final collection in selectedAlbums) {
      if (collection.type == CollectionType.favorites) {
        continue;
      }
      count = await FilesDB.instance.collectionFileCount(collection.id);
      if (!mounted) return;
      final bool isEmptyCollection = count == 0;
      if (isEmptyCollection) {
        try {
          await CollectionsService.instance.trashEmptyCollection(collection);
          if (!mounted) return;
        } catch (e, s) {
          _logger.warning("failed to trash collection", e, s);
          if (!mounted) return;
          errors.add(e);
        }
      } else {
        nonEmptyCollection.add(collection);
      }
    }
    if (errors.isNotEmpty) {
      await showGenericErrorDialog(context: context, error: errors.first);
      if (!mounted) return;
    }

    if (nonEmptyCollection.isNotEmpty) {
      final bool result = await collectionActions.deleteMultipleCollectionSheet(
        context,
        nonEmptyCollection,
      );
      if (result == false) {
        debugPrint("Failed to delete collection");
      }
    }
    if (!mounted) return;
    if (hasFavorites) {
      _showFavToast();
    }
    widget.selectedAlbums.clearAll();
  }

  Future<void> _onPinClick() async {
    for (final collection in widget.selectedAlbums.albums) {
      if (collection.type == CollectionType.favorites || collection.isPinned) {
        continue;
      }

      await updateOrder(context, collection, collection.isPinned ? 1 : 1);
    }
    if (hasFavorites) {
      _showFavToast();
    }
    widget.selectedAlbums.clearAll();
  }

  Future<void> _onUnpinClick() async {
    for (final collection in widget.selectedAlbums.albums) {
      if (collection.type == CollectionType.favorites || !collection.isPinned) {
        continue;
      }

      await updateOrder(context, collection, collection.isPinned ? 0 : 0);
    }
    if (hasFavorites) {
      _showFavToast();
    }
    widget.selectedAlbums.clearAll();
  }

  Future<void> _onHideOrUnHideClick() async {
    final hasOwnedFavorites = widget.selectedAlbums.albums.any(_isFavorite);
    final collections = widget.selectedAlbums.albums
        .where((collection) => !_isFavorite(collection))
        .toList();

    if (collections.isEmpty) {
      if (hasOwnedFavorites) {
        _showFavToast();
      }
      widget.selectedAlbums.clearAll();
      return;
    }

    final isUnhiding = collections.first.isHidden();
    if (!mounted) return;
    final dialog = createProgressDialog(
      context,
      isUnhiding ? context.strings.unhiding : context.strings.hiding,
    );
    await dialog.show();

    try {
      for (final collection in collections) {
        final isHidden = collection.isHidden();
        final int prevVisiblity = isHidden
            ? hiddenVisibility
            : visibleVisibility;
        final int newVisiblity = isHidden
            ? visibleVisibility
            : hiddenVisibility;

        if (!mounted) return;
        await changeCollectionVisibility(
          context,
          collection: collection,
          newVisibility: newVisiblity,
          prevVisibility: prevVisiblity,
          showProgressDialog: false,
        );
      }
      if (!mounted) return;
      showShortToast(
        context,
        isUnhiding
            ? context.strings.successfullyUnhid
            : context.strings.successfullyHid,
      );
    } catch (e, s) {
      _logger.warning("failed to change visibility", e, s);
      if (!mounted) return;
      await showGenericErrorDialog(context: context, error: e);
    } finally {
      await dialog.hide();
    }

    if (hasOwnedFavorites) {
      _showFavToast();
    }
    widget.selectedAlbums.clearAll();
  }

  Future<void> _archiveClick() async {
    final hasOwnedFavorites = widget.selectedAlbums.albums.any(_isFavorite);
    final collections = widget.selectedAlbums.albums
        .where((collection) => !_isFavorite(collection))
        .toList();

    if (collections.isEmpty) {
      if (hasOwnedFavorites) {
        _showFavToast();
      }
      widget.selectedAlbums.clearAll();
      return;
    }

    final isUnarchiving = collections.first.isArchived();
    final dialog = createProgressDialog(
      context,
      isUnarchiving ? context.strings.unarchiving : context.strings.archiving,
    );
    await dialog.show();

    try {
      for (final collection in collections) {
        final isArchived = collection.isArchived();
        final int prevVisiblity = isArchived
            ? archiveVisibility
            : visibleVisibility;
        final int newVisiblity = isArchived
            ? visibleVisibility
            : archiveVisibility;

        if (!mounted) return;
        await changeCollectionVisibility(
          context,
          collection: collection,
          newVisibility: newVisiblity,
          prevVisibility: prevVisiblity,
          showProgressDialog: false,
        );
      }
      if (!mounted) return;
      showShortToast(
        context,
        isUnarchiving
            ? context.strings.successfullyUnarchived
            : context.strings.successfullyArchived,
      );
    } catch (e, s) {
      _logger.warning("failed to change archive state", e, s);
      if (!mounted) return;
      await showGenericErrorDialog(context: context, error: e);
    } finally {
      await dialog.hide();
    }

    if (hasOwnedFavorites) {
      _showFavToast();
    }
    if (mounted) {
      setState(() {});
    }
    widget.selectedAlbums.clearAll();
  }

  bool _isFavorite(Collection collection) {
    return collection.type == CollectionType.favorites;
  }

  void _selectionChangedListener() {
    if (mounted) {
      hasFavorites = widget.selectedAlbums.albums.any(
        (album) => album.type == CollectionType.favorites,
      );
      setState(() {});
    }
  }

  void _showFavToast() {
    showShortToast(
      context,
      context.strings.actionNotSupportedOnFavouritesAlbum,
    );
  }
}
