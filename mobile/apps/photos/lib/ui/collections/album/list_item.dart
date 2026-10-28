import "package:ente_components/ente_components.dart";
import "package:ente_icons/ente_icons.dart";
import "package:ente_strings/ente_strings.dart";
import "package:flutter/material.dart";
import "package:hugeicons/hugeicons.dart";
import "package:logging/logging.dart";
import "package:photos/models/collection/collection.dart";
import "package:photos/models/file/file.dart";
import "package:photos/models/selected_albums.dart";
import "package:photos/services/collections_service.dart";
import "package:photos/ui/components/collection_share_badge.dart";
import "package:photos/ui/components/thumbnail_list_item.dart";
import "package:photos/ui/viewer/file/no_thumbnail_widget.dart";
import "package:photos/ui/viewer/file/thumbnail_widget.dart";

class AlbumListItemWidget extends StatelessWidget {
  static const double _trailingSize = 24;

  final Collection collection;
  final String? tag;
  final void Function(Collection)? onTapCallback;
  final void Function(Collection)? onLongPressCallback;
  final SelectedAlbums? selectedAlbums;
  final bool isSelected;

  const AlbumListItemWidget(
    this.collection, {
    super.key,
    this.tag,
    this.onTapCallback,
    this.onLongPressCallback,
    this.selectedAlbums,
    this.isSelected = false,
  });

  @override
  Widget build(BuildContext context) {
    if (selectedAlbums == null) {
      return _buildItem(context, isSelected: isSelected);
    }
    return ListenableBuilder(
      listenable: selectedAlbums!,
      builder: (context, _) {
        return _buildItem(
          context,
          isSelected: selectedAlbums!.isAlbumSelected(collection),
        );
      },
    );
  }

  Widget _buildItem(BuildContext context, {required bool isSelected}) {
    final bool isFavoriteAlbum = collection.type == CollectionType.favorites;
    final bool showPin = collection.isPinned;
    final bool showArchive = collection.isArchived();

    final colors = context.componentColors;
    return ThumbnailListItem(
      backgroundColor: thumbnailListItemBackgroundColor(context),
      selectedBorderColor: colors.strokeDark,
      isSelected: isSelected,
      onTap: onTapCallback == null ? null : () => onTapCallback!(collection),
      onLongPress: onLongPressCallback == null
          ? null
          : () => onLongPressCallback!(collection),
      leading: AlbumListItemCover(
        collection: collection,
        heroTag: tag == null
            ? null
            : "collection" + tag! + "_" + collection.id.toString(),
      ),
      title: _buildTitle(context),
      subtitle: FutureBuilder<int>(
        future: CollectionsService.instance.getFileCount(collection),
        initialData: CollectionsService.instance.getCachedFileCount(collection),
        builder: (context, snapshot) {
          String countText = "";
          if (snapshot.hasData) {
            countText = context.strings.itemCount(count: snapshot.data!);
          } else if (snapshot.hasError) {
            Logger("AlbumListItemWidget").severe(
              "Failed to fetch file count of collection",
              snapshot.error,
            );
          } else {
            final cachedCount = CollectionsService.instance.getCachedFileCount(
              collection,
            );
            if (cachedCount != null) {
              countText = context.strings.itemCount(count: cachedCount);
            }
          }
          return _buildSubtitle(
            context,
            text: countText,
            showPin: showPin,
            showArchive: showArchive,
            isFavoriteAlbum: isFavoriteAlbum,
          );
        },
      ),
      trailing: Padding(
        padding: const EdgeInsets.only(right: 8),
        child: SizedBox(
          width: _trailingSize,
          height: _trailingSize,
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 300),
            switchInCurve: Curves.easeOut,
            switchOutCurve: Curves.easeIn,
            layoutBuilder: (currentChild, previousChildren) {
              return Stack(
                alignment: Alignment.centerRight,
                children: [...previousChildren, ?currentChild],
              );
            },
            child: _buildTrailingIndicator(isSelected: isSelected),
          ),
        ),
      ),
    );
  }

  Widget _buildTitle(BuildContext context) {
    final colors = context.componentColors;

    return Text(
      collection.displayName,
      style: TextStyles.body.copyWith(color: colors.textBase),
      maxLines: 1,
      softWrap: false,
      overflow: TextOverflow.ellipsis,
    );
  }

  Widget _buildSubtitle(
    BuildContext context, {
    required String text,
    required bool showPin,
    required bool showArchive,
    required bool isFavoriteAlbum,
  }) {
    final colors = context.componentColors;
    final textStyle = TextStyles.mini.copyWith(color: colors.textLight);
    final hasStatus = showPin || showArchive || isFavoriteAlbum;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Flexible(
          child: Text(
            text,
            style: textStyle,
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (hasStatus) ...[
          Text(" \u2022 ", style: textStyle),
          if (showPin)
            ImageIcon(
              const AssetImage("assets/collection_pin.png"),
              size: 12,
              color: colors.textBase,
            ),
          if (showArchive)
            HugeIcon(
              icon: HugeIcons.strokeRoundedArchive03,
              size: 12,
              color: colors.textBase,
              strokeWidth: 2.0,
            ),
          if (isFavoriteAlbum)
            Icon(EnteIcons.favoriteFilled, size: 12, color: colors.textBase),
        ],
      ],
    );
  }

  Widget _buildTrailingIndicator({required bool isSelected}) {
    if (isSelected) {
      return const CollectionSelectedBadge(key: ValueKey("selected"));
    }
    return const SizedBox.shrink(key: ValueKey("unselected"));
  }
}

class AlbumListItemCover extends StatelessWidget {
  const AlbumListItemCover({
    required this.collection,
    this.heroTag,
    this.borderRadius = ThumbnailListItem.defaultLeadingRadius,
    super.key,
  });

  final Collection collection;
  final String? heroTag;
  final double borderRadius;

  @override
  Widget build(BuildContext context) {
    final cover = ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: SizedBox.expand(
        child: FutureBuilder<EnteFile?>(
          future: CollectionsService.instance.getCover(collection),
          initialData: CollectionsService.instance.getCoverCache(collection),
          builder: (context, snapshot) {
            final thumbnail =
                snapshot.data ??
                CollectionsService.instance.getCoverCache(collection);
            if (thumbnail == null) {
              return NoThumbnailWidget(
                borderRadius: borderRadius,
                addBorder: false,
              );
            }
            return ThumbnailWidget(
              thumbnail,
              shouldShowFavoriteIcon: false,
              shouldShowSyncStatus: false,
              key: Key("album_list:${collection.id}:${thumbnail.tag}"),
            );
          },
        ),
      ),
    );
    if (heroTag == null) return cover;
    return Hero(
      tag: heroTag!,
      createRectTween: (begin, end) => RectTween(begin: begin, end: end),
      transitionOnUserGestures: true,
      child: cover,
    );
  }
}
