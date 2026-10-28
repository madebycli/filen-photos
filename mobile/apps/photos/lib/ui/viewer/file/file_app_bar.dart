import "dart:async";
import 'dart:io';

import "package:ente_components/ente_components.dart";
import "package:ente_lock_screen/local_authentication_service.dart";
import "package:ente_strings/ente_strings.dart";
import 'package:flutter/material.dart';
import "package:flutter_svg/flutter_svg.dart";
import "package:hugeicons/hugeicons.dart";
import "package:local_auth/local_auth.dart";
import 'package:logging/logging.dart';
import 'package:media_extension/media_extension.dart';
import "package:photos/core/event_bus.dart";
import "package:photos/events/guest_view_event.dart";
import "package:photos/models/collection/collection.dart";
import "package:photos/models/file/extensions/file_props.dart";
import 'package:photos/models/file/file.dart';
import 'package:photos/models/file/file_type.dart';
import "package:photos/models/metadata/common_keys.dart";
import 'package:photos/models/selected_files.dart';
import 'package:photos/module/download/file.dart';
import 'package:photos/module/download/gallery.dart';
import "package:photos/service_locator.dart";
import 'package:photos/services/collections_service.dart';
import 'package:photos/services/hidden_service.dart';
import "package:photos/states/detail_page_state.dart";
import "package:photos/theme/colors.dart";
import "package:photos/ui/actions/file/file_actions.dart";
import 'package:photos/ui/collections/collection_action_sheet.dart';
import "package:photos/ui/common/photo_library_add_permission.dart";
import 'package:photos/ui/notification/toast.dart';
import "package:photos/ui/viewer/file/detail_page.dart";
import "package:photos/ui/viewer/file/video_control/video_speed_bottom_sheet.dart";
import "package:photos/ui/viewer/file/viewer_app_bar.dart";
import "package:photos/ui/viewer/file_details/favorite_widget.dart";
import "package:photos/ui/viewer/file_details/upload_icon_widget.dart";
import 'package:photos/utils/dialog_util.dart';
import "package:photos/utils/magic_util.dart";

String _formatPlaybackSpeed(double speed) {
  return speed == 1.0 ? "1x" : "${speed}x";
}

class FileAppBar extends StatefulWidget {
  final EnteFile file;
  final Function(EnteFile) onFileRemoved;
  final Function(EnteFile) onEditRequested;
  final ValueNotifier<bool> enableFullScreenNotifier;
  final DetailPageMode mode;
  final bool showEditAction;
  final FutureOr<void> Function(BuildContext context)? onBackPressed;
  final ValueNotifier<double> playbackSpeed;

  const FileAppBar(
    this.file,
    this.onFileRemoved,
    this.onEditRequested, {
    required this.enableFullScreenNotifier,
    this.mode = DetailPageMode.full,
    this.showEditAction = true,
    this.onBackPressed,
    required this.playbackSpeed,
    super.key,
  });

  @override
  FileAppBarState createState() => FileAppBarState();
}

class FileAppBarState extends State<FileAppBar> {
  final _logger = Logger("FadingAppBar");
  final List<Widget> _actions = [];
  late final StreamSubscription<GuestViewEvent> _guestViewEventSubscription;
  bool isGuestView = false;
  bool shouldLoopVideo = localSettings.shouldLoopVideo();
  bool _reloadActions = false;
  ValueNotifier<String?>? _showingThumbnailFallbackNotifier;

  @override
  void didUpdateWidget(FileAppBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (detailPageFileIdentifier(oldWidget.file) !=
            detailPageFileIdentifier(widget.file) ||
        oldWidget.showEditAction != widget.showEditAction) {
      _getActions();
    }
  }

  @override
  void initState() {
    super.initState();
    _guestViewEventSubscription = Bus.instance.on<GuestViewEvent>().listen((
      event,
    ) {
      setState(() {
        isGuestView = event.isGuestView;
      });
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final detailPageState = InheritedDetailPageState.maybeOf(context);
    _updateShowingThumbnailFallbackNotifier(
      detailPageState?.showingThumbnailFallbackNotifier,
    );
  }

  void _onThumbnailFallbackChanged() {
    _requestActionsReload();
  }

  void _updateShowingThumbnailFallbackNotifier(
    ValueNotifier<String?>? notifier,
  ) {
    if (_showingThumbnailFallbackNotifier == notifier) {
      return;
    }
    _showingThumbnailFallbackNotifier?.removeListener(
      _onThumbnailFallbackChanged,
    );
    _showingThumbnailFallbackNotifier = notifier;
    _showingThumbnailFallbackNotifier?.addListener(_onThumbnailFallbackChanged);
  }

  @override
  void dispose() {
    _showingThumbnailFallbackNotifier?.removeListener(
      _onThumbnailFallbackChanged,
    );
    _guestViewEventSubscription.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _logger.info("building app bar ${widget.file.generatedID?.toString()}");

    // _getActions reads inherited state, so it cannot run in initState.
    if (_actions.isEmpty || _reloadActions) {
      _getActions();
      _reloadActions = false;
    }
    final shouldShowActions = !isGuestView;
    return ValueListenableBuilder<bool>(
      valueListenable: widget.enableFullScreenNotifier,
      builder: (context, isFullScreen, _) => ViewerAppBar(
        visible: !isFullScreen,
        toolbarKey: ValueKey(isGuestView),
        onBackPressed: () {
          final onBackPressed = widget.onBackPressed;
          if (onBackPressed != null && !isGuestView) {
            unawaited(Future.sync(() => onBackPressed(context)));
            return;
          }
          isGuestView ? _requestAuthentication() : Navigator.of(context).pop();
        },
        actions: shouldShowActions ? _actions : [],
      ),
    );
  }

  void _requestActionsReload() {
    if (mounted) {
      setState(() {
        _reloadActions = true;
      });
    }
  }

  List<Widget> _getActions() {
    _actions.clear();

    final fallbackFileId = InheritedDetailPageState.maybeOf(
      context,
    )?.showingThumbnailFallbackNotifier.value;
    final currentFileId = detailPageFileIdentifier(widget.file);
    final showingFallback =
        fallbackFileId != null && fallbackFileId == currentFileId;
    if (showingFallback) {
      _actions.add(
        Tooltip(
          message:
              "Your device doesn't support this image format. Showing a preview instead.",
          triggerMode: TooltipTriggerMode.tap,
          showDuration: const Duration(seconds: 4),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          margin: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(
            color: backgroundElevated2Dark,
            borderRadius: BorderRadius.circular(8),
          ),
          textStyle: const TextStyle(color: Colors.white, fontSize: 14),
          preferBelow: true,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            child: const Padding(
              padding: EdgeInsets.all(12.0),
              child: HugeIcon(
                icon: HugeIcons.strokeRoundedInformationCircle,
                color: Colors.white,
              ),
            ),
          ),
        ),
      );
    }

    final bool isFileUploaded = widget.file.isUploaded;
    final int? collectionID = widget.file.collectionID;
    final Collection? collection = collectionID != null
        ? CollectionsService.instance.getCollectionByID(collectionID)
        : null;
    bool isFileHidden = false;
    if (isFileUploaded) {
      isFileHidden = collection?.isHidden() ?? false;
    }
    if (widget.file.isLiveOrMotionPhoto) {
      _actions.add(
        IconButton(
          icon: SvgPicture.asset(
            "assets/icons/live-photo.svg",
            width: 24,
            height: 24,
            colorFilter: const ColorFilter.mode(Colors.white, BlendMode.srcIn),
          ),
          onPressed: () {
            showShortToast(
              context,
              context.strings.pressAndHoldToPlayVideoDetailed,
            );
          },
        ),
      );
    }
    if (!isFileHidden && isFileUploaded && !widget.file.isTrash) {
      _actions.add(
        Center(
          child: FavoriteWidget(widget.file, iconSize: 24, tapTargetSize: 48),
        ),
      );
    }

    if (!isFileUploaded && !widget.file.isTrash && !isLocalGalleryMode) {
      _actions.add(
        UploadIconWidget(file: widget.file, key: ValueKey(widget.file.tag)),
      );
    }

    final List<EntePopupMenuOption<int>> items = [];
    final bool restrictFileActions =
        widget.mode == DetailPageMode.minimalistic || widget.file.isTrash;

    if (restrictFileActions) {
      items.add(
        _fileMenuOption(
          context.strings.info,
          value: 12,
          hugeIcon: HugeIcons.strokeRoundedInformationCircle,
        ),
      );
    } else {
      if (isFileUploaded) {
        items.add(
          _fileMenuOption(
            context.strings.download,
            value: 1,
            hugeIcon: HugeIcons.strokeRoundedDownload01,
          ),
        );
      }
      if (widget.showEditAction &&
          (widget.file.fileType == FileType.image ||
              widget.file.fileType == FileType.livePhoto ||
              widget.file.fileType == FileType.video)) {
        items.add(
          _fileMenuOption(
            context.strings.edit,
            value: 11,
            hugeIcon: HugeIcons.strokeRoundedSlidersHorizontal,
          ),
        );
      }
      if (!isFileHidden && isFileUploaded) {
        final bool isArchived =
            widget.file.magicMetadata.visibility == archiveVisibility;
        items.add(
          _fileMenuOption(
            isArchived ? context.strings.unarchive : context.strings.archive,
            value: 2,
            hugeIcon: isArchived
                ? HugeIcons.strokeRoundedUnarchive03
                : HugeIcons.strokeRoundedArchive03,
          ),
        );
      }

      if ((widget.file.fileType == FileType.image ||
              widget.file.fileType == FileType.livePhoto) &&
          Platform.isAndroid) {
        items.add(
          _fileMenuOption(
            context.strings.setAs,
            value: 3,
            hugeIcon: HugeIcons.strokeRoundedImage01,
          ),
        );
      }
      if (widget.file.isUploaded) {
        if (!isFileHidden) {
          items.add(
            _fileMenuOption(
              context.strings.hide,
              value: 4,
              hugeIcon: HugeIcons.strokeRoundedViewOffSlash,
            ),
          );
        } else {
          items.add(
            _fileMenuOption(
              context.strings.unhide,
              value: 5,
              hugeIcon: HugeIcons.strokeRoundedView,
            ),
          );
        }
      }

      items.add(
        _fileMenuOption(
          context.strings.guestView,
          value: 6,
          hugeIcon: HugeIcons.strokeRoundedIncognito,
        ),
      );

      items.add(
        _fileMenuOption(
          context.strings.info,
          value: 12,
          hugeIcon: HugeIcons.strokeRoundedInformationCircle,
        ),
      );
    }

    if (widget.file.isVideo && !restrictFileActions) {
      items.add(
        _fileMenuOption(
          context.strings.playbackSpeed,
          value: 10,
          hugeIcon: HugeIcons.strokeRoundedDashboardSpeed02,
          trailing: ValueListenableBuilder<double>(
            valueListenable: widget.playbackSpeed,
            builder: (context, speed, _) =>
                Text(_formatPlaybackSpeed(speed), style: TextStyles.tiny),
          ),
        ),
      );

      items.add(
        _fileMenuOption(
          shouldLoopVideo
              ? context.strings.loopVideoOn
              : context.strings.loopVideoOff,
          value: 7,
          hugeIcon: shouldLoopVideo
              ? HugeIcons.strokeRoundedRepeatOff
              : HugeIcons.strokeRoundedRepeat,
        ),
      );
    }

    if (items.isNotEmpty) {
      _actions.add(
        EntePopupMenuButton<int>(
          optionsBuilder: () => items,
          onSelected: (selected) async {
            if (!mounted) {
              return;
            }
            await _handleFileMenuSelection(selected);
          },
          child: Tooltip(
            message: MaterialLocalizations.of(context).moreButtonTooltip,
            child: const SizedBox.square(
              dimension: kMinInteractiveDimension,
              child: Center(
                child: HugeIcon(
                  icon: HugeIcons.strokeRoundedMoreVertical,
                  color: Colors.white,
                ),
              ),
            ),
          ),
        ),
      );
    }

    return _actions;
  }

  EntePopupMenuOption<int> _fileMenuOption(
    String label, {
    required int value,
    required List<List<dynamic>> hugeIcon,
    Widget? trailing,
    bool enabled = true,
  }) {
    return EntePopupMenuOption<int>(
      value: value,
      label: label,
      leadingWidget: HugeIcon(icon: hugeIcon, size: IconSizes.small),
      trailingWidget: trailing,
      enabled: enabled,
    );
  }

  Future<void> _handleFileMenuSelection(int value) async {
    if (value == 1) {
      await _download(widget.file);
    } else if (value == 2) {
      await _toggleFileArchiveStatus(widget.file);
    } else if (value == 3) {
      await _setAs(widget.file);
    } else if (value == 4) {
      await _handleHideRequest(context);
    } else if (value == 5) {
      await _handleUnHideRequest(context);
    } else if (value == 6) {
      await _onTapGuestView();
    } else if (value == 7) {
      _onToggleLoopVideo();
    } else if (value == 10) {
      await showVideoSpeedBottomSheet(
        context,
        currentSpeed: widget.playbackSpeed.value,
        onSpeedSelected: (speed) => widget.playbackSpeed.value = speed,
      );
    } else if (value == 11) {
      widget.onEditRequested(widget.file);
    } else if (value == 12) {
      await showDetailsSheet(context, widget.file);
    }
  }

  void _onToggleLoopVideo() {
    localSettings.setShouldLoopVideo(!shouldLoopVideo);
    setState(() {
      _reloadActions = true;
      shouldLoopVideo = !shouldLoopVideo;
    });
  }

  Future<void> _handleHideRequest(BuildContext context) async {
    try {
      final hideResult = await CollectionsService.instance.hideFiles(context, [
        widget.file,
      ]);
      if (hideResult) {
        widget.onFileRemoved(widget.file);
      }
    } catch (e, s) {
      _logger.severe("failed to update file visibility", e, s);
      if (!context.mounted) return;
      await showGenericErrorDialog(context: context, error: e);
    }
  }

  Future<void> _handleUnHideRequest(BuildContext context) async {
    final selectedFiles = SelectedFiles();
    selectedFiles.files.add(widget.file);
    await showCollectionActionSheet(
      context,
      selectedFiles: selectedFiles,
      actionType: CollectionActionType.unHide,
    );
  }

  Future<void> _toggleFileArchiveStatus(EnteFile file) async {
    final bool isArchived =
        widget.file.magicMetadata.visibility == archiveVisibility;
    await changeVisibility(context, [
      widget.file,
    ], isArchived ? visibleVisibility : archiveVisibility);
    if (mounted) {
      setState(() {
        _reloadActions = true;
      });
    }
  }

  Future<void> _download(EnteFile file) async {
    final existingFolderName =
        await getExistingLocalFolderNameForDownloadSkipToast(file);
    if (existingFolderName != null) {
      if (mounted) {
        final l10n = context.strings;
        showToast(
          context,
          l10n.downloadSkippedAlreadyAvailableOnDevice(
            fileName: getDownloadSkipToastFileName(file),
            albumName: existingFolderName,
          ),
          iosLongToastLengthInSec: 4,
        );
      }
      return;
    }

    if (!mounted) return;
    if (!await ensurePhotoLibraryAddPermission(context)) return;
    if (!mounted) return;

    final fileToDownload = !file.isRemoteOnlyFile
        ? (file.copyWith()..localID = null)
        : file;
    if (!mounted) return;
    final dialog = createProgressDialog(
      context,
      context.strings.downloading,
      isDismissible: true,
    );
    await dialog.show();
    try {
      await downloadToGallery(fileToDownload);
      if (!mounted) {
        await dialog.hide();
        return;
      }
      showToast(context, context.strings.fileSavedToGallery);
      await dialog.hide();
    } catch (e) {
      _logger.warning("Failed to save file", e);
      await dialog.hide();
      if (mounted) {
        await showGenericErrorDialog(context: context, error: e);
      }
    }
  }

  Future<void> _setAs(EnteFile file) async {
    final dialog = createProgressDialog(context, context.strings.pleaseWait);
    await dialog.show();
    try {
      final File? fileToSave = await (getFile(file));
      if (fileToSave == null) {
        throw Exception("Fail to get file for setAs operation");
      }
      final m = MediaExtension();
      final bool result = await m.setAs("file://${fileToSave.path}", "image/*");
      if (result == false) {
        if (!mounted) {
          await dialog.hide();
          return;
        }
        showShortToast(context, context.strings.somethingWentWrong);
      }
      await dialog.hide();
    } catch (e) {
      await dialog.hide();
      _logger.severe("Failed to use as", e);
      if (!mounted) return;
      await showGenericErrorDialog(context: context, error: e);
    }
  }

  Future<void> _onTapGuestView() async {
    if (await LocalAuthentication().isDeviceSupported()) {
      if (!mounted) return;
      Bus.instance.fire(GuestViewEvent(true, true));
      await localSettings.setOnGuestView(true);
    } else {
      if (!mounted) return;
      await showErrorDialog(
        context,
        context.strings.noSystemLockFound,
        context.strings.guestViewEnablePreSteps,
      );
    }
  }

  Future<void> _requestAuthentication() async {
    final hasAuthenticated = await LocalAuthenticationService.instance
        .requestLocalAuthentication(
          context,
          "Please authenticate to view more photos and videos.",
        );
    if (hasAuthenticated) {
      Bus.instance.fire(GuestViewEvent(false, false));
      await localSettings.setOnGuestView(false);
    }
  }
}
