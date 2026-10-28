import "dart:async";

import "package:flutter/foundation.dart";
import "package:flutter/material.dart";
import "package:flutter/services.dart";
import "package:fluttertoast/fluttertoast.dart";
import "package:logging/logging.dart";
import "package:photos/core/event_bus.dart";
import "package:photos/events/use_media_kit_for_video.dart";
import "package:photos/models/file/extensions/file_props.dart";
import "package:photos/models/file/file.dart";
import "package:photos/states/detail_page_state.dart";
import "package:photos/ui/notification/toast.dart";
import "package:photos/ui/viewer/file/video_widget_media_kit.dart";
import "package:photos/ui/viewer/file/video_widget_native.dart";

class VideoWidget extends StatefulWidget {
  final EnteFile file;
  final String? tagPrefix;
  final FullScreenRequestCallback? playbackCallback;
  final Function(bool)? shouldDisableScroll;
  final Function({required int memoryDuration})? onFinalFileLoad;
  final bool isFromMemories;
  final bool isActive;
  final int? itemIndex;
  final ValueListenable<int>? activeItemIndexListenable;
  final bool? isAudioMutedOverride;
  final ValueNotifier<double>? playbackSpeed;

  const VideoWidget(
    this.file, {
    this.tagPrefix,
    this.playbackCallback,
    this.shouldDisableScroll,
    this.onFinalFileLoad,
    this.isFromMemories = false,
    required this.isActive,
    this.itemIndex,
    this.activeItemIndexListenable,
    this.isAudioMutedOverride,
    this.playbackSpeed,
    super.key,
  });

  @override
  State<VideoWidget> createState() => _VideoWidgetState();
}

class _VideoWidgetState extends State<VideoWidget> {
  final _logger = Logger("VideoWidget");
  bool useNativeVideoPlayer = true;
  late final StreamSubscription<UseMediaKitForVideo>
  useMediaKitForVideoSubscription;
  final nativePlayerKey = GlobalKey();
  final mediaKitKey = GlobalKey();
  late final ValueNotifier<double> _playbackSpeed =
      widget.playbackSpeed ?? ValueNotifier<double>(1.0);

  bool get _isActive =>
      widget.isActive &&
      (widget.activeItemIndexListenable == null ||
          widget.activeItemIndexListenable!.value == widget.itemIndex);

  @override
  void initState() {
    super.initState();
    widget.activeItemIndexListenable?.addListener(_onActiveItemChanged);
    useMediaKitForVideoSubscription = Bus.instance
        .on<UseMediaKitForVideo>()
        .listen((event) {
          _logger.info(
            "Automatically switching to MediaKit due to native player error",
          );
          setState(() {
            useNativeVideoPlayer = false;
          });
        });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _maybeShowTransformToast();
    });
  }

  @override
  void dispose() {
    widget.activeItemIndexListenable?.removeListener(_onActiveItemChanged);
    useMediaKitForVideoSubscription.cancel();
    if (widget.playbackSpeed == null) {
      _playbackSpeed.dispose();
    }
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant VideoWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(
      oldWidget.activeItemIndexListenable,
      widget.activeItemIndexListenable,
    )) {
      oldWidget.activeItemIndexListenable?.removeListener(_onActiveItemChanged);
      widget.activeItemIndexListenable?.addListener(_onActiveItemChanged);
    }
  }

  void _onActiveItemChanged() => setState(() {});

  @override
  Widget build(BuildContext context) {
    final shouldUseNativeVideoPlayer =
        useNativeVideoPlayer && !widget.file.isDeviceTrash;

    final Widget child = shouldUseNativeVideoPlayer
        ? VideoWidgetNative(
            widget.file,
            key: nativePlayerKey,
            tagPrefix: widget.tagPrefix,
            playbackCallback: widget.playbackCallback,
            shouldDisableScroll: widget.shouldDisableScroll,
            playbackSpeed: _playbackSpeed,
            isFromMemories: widget.isFromMemories,
            isActive: _isActive,
            isAudioMutedOverride: widget.isAudioMutedOverride,
            onFinalFileLoad: widget.onFinalFileLoad,
          )
        : VideoWidgetMediaKit(
            widget.file,
            key: mediaKitKey,
            tagPrefix: widget.tagPrefix,
            playbackCallback: widget.playbackCallback,
            shouldDisableScroll: widget.shouldDisableScroll,
            playbackSpeed: _playbackSpeed,
            isFromMemories: widget.isFromMemories,
            isActive: _isActive,
            isAudioMutedOverride: widget.isAudioMutedOverride,
            onFinalFileLoad: widget.onFinalFileLoad,
          );

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: child,
    );
  }

  void _maybeShowTransformToast() {
    if (!kDebugMode) return;
    final name = widget.file.title ?? widget.file.displayName;
    final editedIndex = name.indexOf('_edited');
    if (editedIndex == -1) return;
    final prefix = name.substring(0, editedIndex);

    final hasTrim = prefix.contains('_t');
    final cropMatch = RegExp(r'_c_([0-9]+(?:[:_-][0-9]+)?)').firstMatch(prefix);
    final rotateMatch = RegExp(r'_r_([^_]+)').firstMatch(prefix);

    if (!hasTrim && cropMatch == null && rotateMatch == null) return;

    final parts = <String>[];
    if (hasTrim) {
      parts.add('Trim applied');
    }
    if (cropMatch != null) {
      final raw = cropMatch.group(1) ?? '';
      final formatted = raw.replaceAll(RegExp('[:_-]'), ':');
      parts.add('Crop: $formatted');
    }
    if (rotateMatch != null) {
      parts.add('Rotate: ${rotateMatch.group(1)}°');
    }

    if (parts.isEmpty) return;
    showToast(
      context,
      parts.join(' • '),
      toastLength: Toast.LENGTH_SHORT,
      gravity: ToastGravity.TOP,
    );
  }
}
