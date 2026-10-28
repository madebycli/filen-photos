import "package:ente_components/ente_components.dart";
import 'package:ente_pure_utils/ente_pure_utils.dart';
import "package:ente_strings/ente_strings.dart";
import "package:figma_squircle/figma_squircle.dart";
import 'package:flutter/material.dart';
import 'package:photos/models/collection/collection.dart';
import 'package:photos/models/collection/collection_items.dart';
import 'package:photos/models/file/file.dart';
import "package:photos/models/selected_albums.dart";
import "package:photos/services/collections_service.dart";
import "package:photos/ui/components/collection_share_badge.dart";
import 'package:photos/ui/viewer/file/no_thumbnail_widget.dart';
import 'package:photos/ui/viewer/file/thumbnail_widget.dart';
import 'package:photos/ui/viewer/gallery/collection_page.dart';

class AlbumRowItemWidget extends StatelessWidget {
  final Collection c;
  final double sideOfThumbnail;
  final bool showFileCount;
  final String tag;
  final bool? hasVerifiedLock;
  final void Function(Collection)? onTapCallback;
  final void Function(Collection)? onLongPressCallback;
  final SelectedAlbums? selectedAlbums;
  final bool? isSelected;
  final Widget? Function(BuildContext, Collection)? topLeftOverlayBuilder;
  final double titleToSubtitleSpacing;
  static const _cornerRadius = 20.0;
  static const _cornerSmoothing = 0.6;
  static const _overlayPadding = 8.0;
  static const _thumbnailToTextSpacing = 8.0;

  const AlbumRowItemWidget(
    this.c,
    this.sideOfThumbnail, {
    super.key,
    this.showFileCount = true,
    this.tag = "",
    this.hasVerifiedLock,
    this.onTapCallback,
    this.onLongPressCallback,
    this.selectedAlbums,
    this.isSelected,
    this.topLeftOverlayBuilder,
    this.titleToSubtitleSpacing = 2,
  });

  @override
  Widget build(BuildContext context) {
    final String tagPrefix = "collection" + tag + "_" + c.id.toString();
    final componentColors = context.componentColors;
    final externalSelection = isSelected;
    final topLeftOverlay = topLeftOverlayBuilder?.call(context, c);

    final row = GestureDetector(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            height: sideOfThumbnail,
            width: sideOfThumbnail,
            child: Stack(
              clipBehavior: Clip.none,
              alignment: Alignment.center,
              children: [
                ClipSmoothRect(
                  radius: SmoothBorderRadius(
                    cornerRadius: _cornerRadius,
                    cornerSmoothing: _cornerSmoothing,
                  ),
                  child: SizedBox(
                    height: sideOfThumbnail,
                    width: sideOfThumbnail,
                    child: Stack(
                      children: [
                        FutureBuilder<EnteFile?>(
                          future: CollectionsService.instance.getCover(c),
                          builder: (context, snapshot) {
                            EnteFile? thumbnail;
                            if (snapshot.hasData) {
                              thumbnail = snapshot.data!;
                            } else {
                              // Reuse the cached thumbnail for a stable Hero.
                              thumbnail = CollectionsService.instance
                                  .getCoverCache(c);
                            }
                            if (thumbnail != null) {
                              final bool isAlbumSelected =
                                  externalSelection ??
                                  selectedAlbums?.isAlbumSelected(c) ??
                                  false;
                              final thumbnailWidget = ThumbnailWidget(
                                thumbnail,
                                shouldShowFavoriteIcon: false,
                                shouldShowSyncStatus: false,
                                key: Key(tagPrefix + thumbnail.tag),
                              );
                              return Hero(
                                tag: tagPrefix,
                                createRectTween: (begin, end) =>
                                    RectTween(begin: begin, end: end),
                                transitionOnUserGestures: true,
                                child: ClipSmoothRect(
                                  radius: SmoothBorderRadius(
                                    cornerRadius: _cornerRadius,
                                    cornerSmoothing: _cornerSmoothing,
                                  ),
                                  child: Stack(
                                    fit: StackFit.expand,
                                    children: [
                                      thumbnailWidget,
                                      if (isAlbumSelected)
                                        Container(
                                          decoration: BoxDecoration(
                                            color: componentColors.specialScrim
                                                .withValues(alpha: 0.4),
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                              );
                            } else {
                              return Container(
                                color: componentColors.fillDark,
                                child: const NoThumbnailWidget(
                                  borderRadius: _cornerRadius,
                                  addBorder: false,
                                ),
                              );
                            }
                          },
                        ),
                        if (topLeftOverlay != null)
                          Positioned(
                            top: _overlayPadding,
                            left: _overlayPadding,
                            child: topLeftOverlay,
                          ),
                        Positioned(
                          top: _overlayPadding,
                          right: _overlayPadding,
                          child: externalSelection != null
                              ? _selectionBadge(externalSelection)
                              : selectedAlbums != null
                              ? Hero(
                                  tag: tagPrefix + "_album_selection",
                                  transitionOnUserGestures: true,
                                  child: ListenableBuilder(
                                    listenable: selectedAlbums!,
                                    builder: (context, _) {
                                      final isAlbumSelected = selectedAlbums!
                                          .isAlbumSelected(c);
                                      return _selectionBadge(isAlbumSelected);
                                    },
                                  ),
                                )
                              : const SizedBox.shrink(),
                        ),
                        Positioned(
                          left: _overlayPadding,
                          bottom: _overlayPadding,
                          child: _buildAlbumStatusChips(),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: _thumbnailToTextSpacing),
          Hero(
            tag: tagPrefix + "_title",
            transitionOnUserGestures: true,
            child: SizedBox(
              width: sideOfThumbnail,
              child: showFileCount
                  ? FutureBuilder<int>(
                      future: CollectionsService.instance.getFileCount(c),
                      initialData: CollectionsService.instance
                          .getCachedFileCount(c),
                      builder: (context, snapshot) {
                        int? cachedCount;
                        if (snapshot.hasData) {
                          cachedCount = snapshot.data;
                        } else {
                          // Reuse the cached count to prevent Hero flicker.
                          cachedCount = CollectionsService.instance
                              .getCachedFileCount(c);
                        }
                        if (cachedCount != null && cachedCount > 0) {
                          final String textCount = context.strings.itemCount(
                            count: cachedCount,
                          );
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                c.displayName,
                                style: TextStyles.body.copyWith(
                                  color: componentColors.textBase,
                                ),
                                maxLines: 1,
                                softWrap: false,
                                overflow: TextOverflow.ellipsis,
                              ),
                              SizedBox(height: titleToSubtitleSpacing),
                              Text(
                                textCount,
                                style: TextStyles.mini.copyWith(
                                  color: componentColors.textLight,
                                ),
                                maxLines: 1,
                                softWrap: false,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          );
                        } else {
                          return Text(
                            c.displayName,
                            style: TextStyles.body.copyWith(
                              color: componentColors.textBase,
                            ),
                            maxLines: 1,
                            softWrap: false,
                            overflow: TextOverflow.ellipsis,
                          );
                        }
                      },
                    )
                  : Text(
                      c.displayName,
                      style: TextStyles.body.copyWith(
                        color: componentColors.textBase,
                      ),
                      maxLines: 1,
                      softWrap: false,
                      overflow: TextOverflow.ellipsis,
                    ),
            ),
          ),
        ],
      ),
      onTap: () async {
        if (onTapCallback != null) {
          onTapCallback!(c);
          return;
        }
        final thumbnail = await CollectionsService.instance.getCover(c);
        if (!context.mounted) return;
        // ignore: unawaited_futures
        routeToPage(
          context,
          CollectionPage(
            CollectionWithThumbnail(c, thumbnail),
            tagPrefix: tagPrefix,
            coverHeroTag: tagPrefix,
            hasVerifiedLock: hasVerifiedLock,
          ),
          useFadeTransition: true,
        );
      },
      onLongPress: () {
        if (onLongPressCallback != null) {
          onLongPressCallback!(c);
        }
      },
    );
    return externalSelection == null
        ? row
        : Semantics(button: true, selected: externalSelection, child: row);
  }

  Widget _selectionBadge(bool isSelected) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 200),
      switchInCurve: Curves.easeOut,
      switchOutCurve: Curves.easeIn,
      child: isSelected ? const CollectionSelectedBadge() : null,
    );
  }

  Widget _buildAlbumStatusChips() {
    final bool isFavoriteAlbum = c.type == CollectionType.favorites;
    final bool showPin = c.isPinned;
    final bool showArchive = c.isArchived();

    final chips = <Widget>[
      if (isFavoriteAlbum) const CollectionFavoriteBadge(),
      if (showPin) const PinnedBadge(),
      if (showArchive) const CollectionArchivedBadge(),
    ];

    if (chips.isEmpty) return const SizedBox.shrink();

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (int i = 0; i < chips.length; i++) ...[
          if (i > 0) const SizedBox(width: 2),
          chips[i],
        ],
      ],
    );
  }
}
