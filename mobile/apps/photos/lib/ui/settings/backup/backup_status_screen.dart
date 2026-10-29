// ignore_for_file: public_member_api_docs, sort_constructors_first
import "dart:async";
import "dart:collection";

import "package:collection/collection.dart";
import "package:ente_components/ente_components.dart";
import "package:ente_pure_utils/ente_pure_utils.dart";
import "package:ente_strings/ente_strings.dart";
import 'package:flutter/material.dart';
import "package:hugeicons/hugeicons.dart";
import "package:photos/core/event_bus.dart";
import "package:photos/events/backup_updated_event.dart";
import "package:photos/events/file_uploaded_event.dart";
import "package:photos/filen/filen_upload_progress.dart";
import "package:photos/models/backup/backup_item.dart";
import "package:photos/models/backup/backup_item_status.dart";
import "package:photos/models/file/extensions/file_props.dart";
import "package:photos/module/upload/service/file_uploader.dart";
import "package:photos/services/search_service.dart";
import "package:photos/ui/settings/backup/backup_item_card.dart";

class BackupStatusScreen extends StatefulWidget {
  const BackupStatusScreen({super.key});

  @override
  State<BackupStatusScreen> createState() => _BackupStatusScreenState();
}

class _BackupStatusScreenState extends State<BackupStatusScreen> {
  final LinkedHashMap<String, BackupItem> _items = LinkedHashMap();
  List<BackupItem>? result;
  StreamSubscription? _fileUploadedSubscription;
  StreamSubscription? _backupUpdatedSubscription;

  @override
  void initState() {
    super.initState();

    _items.addAll(FileUploader.instance.allBackups);
    checkBackupUpdatedEvent();
    getAllFiles();
  }

  Future<void> getAllFiles() async {
    result = (await SearchService.instance.getAllFilesForSearch())
        .where((e) => e.uploadedFileID != null && e.isOwner)
        .map((e) {
          return BackupItem(
            status: BackupItemStatus.uploaded,
            file: e,
            collectionID: e.collectionID ?? 0,
          );
        })
        .sorted(
          (a, b) => (b.file.uploadedFileID!).compareTo(a.file.uploadedFileID!),
        )
        .toList();
    _fileUploadedSubscription = Bus.instance.on<FileUploadedEvent>().listen((
      event,
    ) {
      result!.insert(
        0,
        BackupItem(
          status: BackupItemStatus.uploaded,
          file: event.file,
          collectionID: event.file.collectionID ?? 0,
        ),
      );
      safeSetState();
    });
    safeSetState();
  }

  void checkBackupUpdatedEvent() {
    _backupUpdatedSubscription = Bus.instance.on<BackupUpdatedEvent>().listen((
      event,
    ) {
      for (final localID in event.removedLocalIDs) {
        _items.remove(localID);
      }
      _items.addAll(event.upserts);
      safeSetState();
    });
  }

  void safeSetState() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  void dispose() {
    _fileUploadedSubscription?.cancel();
    _backupUpdatedSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final List<BackupItem> items = _items.values.toList().sorted(
      (a, b) => a.status.index.compareTo(b.status.index),
    );

    final allItems = <BackupItem>[
      ...items.where((element) => element.status != BackupItemStatus.uploaded),
      ...?result,
    ];

    return Scaffold(
      backgroundColor: context.componentColors.backgroundBase,
      body: AppBarComponent(
        title: context.strings.backupStatus,
        slivers: [
          const SliverToBoxAdapter(child: _UploadSummary()),
          if (allItems.isEmpty)
            const SliverFillRemaining(
              hasScrollBody: false,
              child: _EmptyBackupStatus(),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: Spacing.lg),
              sliver: SliverList.builder(
                itemBuilder: (context, index) {
                  final file = allItems[index].file;
                  return BackupItemCard(
                    item: allItems[index],
                    key: ValueKey(
                      file.uploadedFileID != null
                          ? ("uploaded", file.uploadedFileID)
                          : file.localID != null
                          ? ("local", file.localID)
                          : ("generated", file.generatedID),
                    ),
                  );
                },
                itemCount: allItems.length,
              ),
            ),
        ],
      ),
    );
  }
}

class _EmptyBackupStatus extends StatelessWidget {
  const _EmptyBackupStatus();

  @override
  Widget build(BuildContext context) {
    final colors = context.componentColors;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 60, vertical: Spacing.md),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          HugeIcon(
            icon: HugeIcons.strokeRoundedCloudUpload,
            color: colors.textLight,
            size: IconSizes.medium,
          ),
          const SizedBox(height: Spacing.lg),
          Text(
            context.strings.backupStatusDescription,
            textAlign: TextAlign.center,
            style: TextStyles.large.copyWith(color: colors.textLight),
          ),
          const SizedBox(height: 48),
        ],
      ),
    );
  }
}

/// Progress of the running backup as the Filen SDK reports it: a bar, the percent, how many of
/// the files are done and the upload speed.
class _UploadSummary extends StatefulWidget {
  const _UploadSummary();

  @override
  State<_UploadSummary> createState() => _UploadSummaryState();
}

class _UploadSummaryState extends State<_UploadSummary> {
  StreamSubscription<void>? _subscription;
  Timer? _speedTimer;

  @override
  void initState() {
    super.initState();
    _subscription = FilenUploadProgress.instance.changes.listen((_) {
      if (mounted) setState(() {});
    });
    // The speed falls to zero when nothing arrives, which no event announces.
    _speedTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && FilenUploadProgress.instance.active) setState(() {});
    });
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _speedTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final progress = FilenUploadProgress.instance;
    final percent = progress.percent;
    if (!progress.active || percent == null) return const SizedBox.shrink();
    final colors = context.componentColors;
    final speed = progress.bytesPerSecond;
    final details = [
      '$percent %',
      '${progress.completed}/${progress.total}',
      if (speed != null) '${formatBytes(speed.round())}/s',
    ].join('  ·  ');
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        Spacing.lg,
        Spacing.md,
        Spacing.lg,
        Spacing.lg,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: percent / 100,
              minHeight: 8,
              backgroundColor: colors.fillDark,
              color: colors.primary,
            ),
          ),
          const SizedBox(height: Spacing.sm),
          Text(
            details,
            style: TextStyles.body.copyWith(color: colors.textLight),
          ),
        ],
      ),
    );
  }
}
