import "dart:io";

import "package:ente_strings/ente_strings.dart";
import "package:ente_ui/models/settings_search_item.dart";
import "package:flutter/foundation.dart";
import "package:flutter/material.dart";
import "package:hugeicons/hugeicons.dart";
import "package:photos/core/configuration.dart";
import "package:photos/filen/ui/filen_account_settings_page.dart";
import "package:photos/service_locator.dart";
import "package:photos/ui/settings/about/about_us_page.dart";
import "package:photos/ui/settings/appearance/appearance_settings_page.dart";
import "package:photos/ui/settings/backup/backup_settings_page.dart";
import "package:photos/ui/settings/backup/free_space_options.dart";
import "package:photos/ui/settings/gallery_settings_screen.dart";
import "package:photos/ui/settings/memories_settings_screen.dart";
import "package:photos/ui/settings/ml/machine_learning_settings_page.dart";
import "package:photos/ui/settings/notification_settings_screen.dart";
import "package:photos/ui/settings/widget_settings_screen.dart";

class SettingsSearchRegistry {
  static List<SettingsSearchItem> getSearchableItems(BuildContext context) {
    final l10n = context.strings;
    final hasLoggedIn = Configuration.instance.hasConfiguredAccount();
    final isLocalGallery = isLocalGalleryMode;
    final showThemeControls = Platform.isAndroid || kDebugMode;
    final items = <SettingsSearchItem>[];

    if (hasLoggedIn && !isLocalGallery) {
      items.add(
        SettingsSearchItem(
          title: l10n.account,
          sectionPath: l10n.account,
          icon: HugeIcons.strokeRoundedUser,
          routeBuilder: (_) => const FilenAccountSettingsPage(),
          keywords: ["email", "filen", "plan", "storage"],
        ),
      );
    }

    if (hasLoggedIn && !isLocalGallery) {
      items.add(
        SettingsSearchItem(
          title: l10n.backup,
          sectionPath: l10n.backup,
          icon: HugeIcons.strokeRoundedCloudUpload,
          routeBuilder: (_) => const BackupSettingsPage(),
          keywords: ["sync", "upload", "photos", "videos"],
        ),
      );

      items.addAll([
        SettingsSearchItem(
          title: l10n.backedUpFolders,
          subtitle: l10n.backup,
          sectionPath: l10n.backup,
          icon: HugeIcons.strokeRoundedFolder01,
          routeBuilder: (_) => const BackupSettingsPage(),
          isSubPage: true,
          keywords: ["folders", "albums", "camera", "backup folders"],
        ),
        SettingsSearchItem(
          title: l10n.backupStatus,
          subtitle: l10n.backup,
          sectionPath: l10n.backup,
          icon: HugeIcons.strokeRoundedCloudSavingDone01,
          routeBuilder: (_) => const BackupSettingsPage(),
          isSubPage: true,
          keywords: ["status", "progress", "queue", "sync status"],
        ),
        SettingsSearchItem(
          title: l10n.backupSettings,
          subtitle: l10n.backup,
          sectionPath: l10n.backup,
          icon: HugeIcons.strokeRoundedSettings01,
          routeBuilder: (_) => const BackupSettingsPage(),
          isSubPage: true,
          keywords: ["mobile data", "videos", "only new"],
        ),
        SettingsSearchItem(
          title: l10n.backupOverMobileData,
          subtitle: l10n.backupSettings,
          sectionPath: "${l10n.backup} > ${l10n.backupSettings}",
          icon: HugeIcons.strokeRoundedSettings01,
          routeBuilder: (_) => const BackupSettingsPage(),
          isSubPage: true,
          keywords: ["mobile data", "cellular", "network"],
        ),
        SettingsSearchItem(
          title: l10n.backupVideos,
          subtitle: l10n.backupSettings,
          sectionPath: "${l10n.backup} > ${l10n.backupSettings}",
          icon: HugeIcons.strokeRoundedVideoCameraAi,
          routeBuilder: (_) => const BackupSettingsPage(),
          isSubPage: true,
          keywords: ["videos", "movies", "backup video"],
        ),
        SettingsSearchItem(
          title: l10n.backupOnlyNewPhotos,
          subtitle: l10n.backupSettings,
          sectionPath: "${l10n.backup} > ${l10n.backupSettings}",
          icon: HugeIcons.strokeRoundedSettings01,
          routeBuilder: (_) => const BackupSettingsPage(),
          isSubPage: true,
          keywords: ["only new", "new photos", "since now"],
        ),
      ]);
    }

    items.add(
      SettingsSearchItem(
        title: l10n.appearance,
        sectionPath: l10n.appearance,
        icon: HugeIcons.strokeRoundedPaintBoard,
        routeBuilder: (_) => const AppearanceSettingsPage(),
        keywords: showThemeControls
            ? ["theme", "dark mode", "light mode", "app icon"]
            : ["app icon"],
      ),
    );

    if (showThemeControls) {
      items.add(
        SettingsSearchItem(
          title: l10n.theme,
          subtitle: l10n.appearance,
          sectionPath: l10n.appearance,
          icon: HugeIcons.strokeRoundedMoon02,
          routeBuilder: (_) => const AppearanceSettingsPage(),
          isSubPage: true,
          keywords: ["theme", "dark mode", "light mode", "system"],
        ),
      );
    }

    items.addAll([
      SettingsSearchItem(
        title: l10n.appIcon,
        subtitle: l10n.appearance,
        sectionPath: l10n.appearance,
        icon: HugeIcons.strokeRoundedImage02,
        routeBuilder: (_) => const AppearanceSettingsPage(),
        isSubPage: true,
        keywords: ["icon", "app icon"],
      ),
      SettingsSearchItem(
        title: l10n.language,
        subtitle: l10n.appearance,
        sectionPath: l10n.appearance,
        icon: HugeIcons.strokeRoundedTranslation,
        routeBuilder: (_) => const AppearanceSettingsPage(),
        isSubPage: true,
        keywords: ["language", "locale", "translation"],
      ),
    ]);

    items.add(
      SettingsSearchItem(
        title: l10n.gallery,
        subtitle: l10n.appearance,
        sectionPath: "${l10n.appearance} > ${l10n.gallery}",
        icon: HugeIcons.strokeRoundedDashboardSquare02,
        routeBuilder: (_) =>
            const GallerySettingsScreen(fromGalleryLayoutSettingsCTA: false),
        isSubPage: true,
        keywords: ["grid size", "group by", "layout", "justified"],
      ),
    );

    items.add(
      SettingsSearchItem(
        title: l10n.layout,
        subtitle: l10n.gallery,
        sectionPath: "${l10n.appearance} > ${l10n.gallery}",
        icon: HugeIcons.strokeRoundedDashboardSquare02,
        routeBuilder: (_) =>
            const GallerySettingsScreen(fromGalleryLayoutSettingsCTA: false),
        isSubPage: true,
        keywords: ["layout", "grid", "justified"],
      ),
    );

    items.add(
      SettingsSearchItem(
        title: l10n.photosPerRow,
        subtitle: l10n.gallery,
        sectionPath: "${l10n.appearance} > ${l10n.gallery}",
        icon: HugeIcons.strokeRoundedDashboardSquare02,
        routeBuilder: (_) =>
            const GallerySettingsScreen(fromGalleryLayoutSettingsCTA: false),
        isSubPage: true,
        keywords: ["grid", "size", "columns", "thumbnail"],
      ),
    );

    items.add(
      SettingsSearchItem(
        title: l10n.groupBy,
        subtitle: l10n.gallery,
        sectionPath: "${l10n.appearance} > ${l10n.gallery}",
        icon: HugeIcons.strokeRoundedDashboardSquare02,
        routeBuilder: (_) =>
            const GallerySettingsScreen(fromGalleryLayoutSettingsCTA: false),
        isSubPage: true,
        keywords: ["group", "day", "month", "year"],
      ),
    );

    if (hasLoggedIn || isLocalGallery) {
      items.add(
        SettingsSearchItem(
          title: l10n.machineLearning,
          sectionPath: l10n.machineLearning,
          icon: HugeIcons.strokeRoundedMagicWand01,
          routeBuilder: (_) => const MachineLearningSettingsPage(),
          keywords: [
            "ml",
            "ai",
            "faces",
            "people",
            "magic search",
            "similar images",
            "duplicates",
          ],
        ),
      );

      items.add(
        SettingsSearchItem(
          title: l10n.localIndexing,
          subtitle: l10n.machineLearning,
          sectionPath: l10n.machineLearning,
          icon: HugeIcons.strokeRoundedDatabase01,
          routeBuilder: (_) => const MachineLearningSettingsPage(),
          isSubPage: true,
          keywords: ["indexing", "local", "on-device"],
        ),
      );
    }

    if (hasLoggedIn || isLocalGallery) {
      items.addAll([
        SettingsSearchItem(
          title: l10n.memories,
          sectionPath: l10n.memories,
          icon: HugeIcons.strokeRoundedSparkles,
          routeBuilder: (_) => const MemoriesSettingsScreen(),
          keywords: ["flashback", "reminder", "highlights"],
        ),
        SettingsSearchItem(
          title: l10n.showMemories,
          subtitle: l10n.memories,
          sectionPath: l10n.memories,
          icon: HugeIcons.strokeRoundedSparkles,
          routeBuilder: (_) => const MemoriesSettingsScreen(),
          isSubPage: true,
          keywords: ["show", "memories", "highlights"],
        ),
        if (memoriesCacheService.curatedMemoriesOption)
          SettingsSearchItem(
            title: l10n.curatedMemories,
            subtitle: l10n.memories,
            sectionPath: l10n.memories,
            icon: HugeIcons.strokeRoundedSparkles,
            routeBuilder: (_) => const MemoriesSettingsScreen(),
            isSubPage: true,
            keywords: ["curated", "smart", "memories"],
          ),
      ]);
    }

    if (hasLoggedIn || isLocalGallery) {
      items.addAll([
        SettingsSearchItem(
          title: l10n.notifications,
          sectionPath: l10n.notifications,
          icon: HugeIcons.strokeRoundedNotification01,
          routeBuilder: (_) => const NotificationSettingsScreen(),
          keywords: ["alerts", "push", "reminders"],
        ),
        SettingsSearchItem(
          title: l10n.onThisDayMemories,
          subtitle: l10n.notifications,
          sectionPath: l10n.notifications,
          icon: HugeIcons.strokeRoundedNotification01,
          routeBuilder: (_) => const NotificationSettingsScreen(),
          isSubPage: true,
          keywords: ["on this day", "memories", "reminders"],
        ),
        SettingsSearchItem(
          title: l10n.birthdays,
          subtitle: l10n.notifications,
          sectionPath: l10n.notifications,
          icon: HugeIcons.strokeRoundedNotification01,
          routeBuilder: (_) => const NotificationSettingsScreen(),
          isSubPage: true,
          keywords: ["birthday", "birthdays", "reminders"],
        ),
      ]);

      items.addAll([
        SettingsSearchItem(
          title: l10n.widgets,
          sectionPath: l10n.widgets,
          icon: HugeIcons.strokeRoundedAlignBoxBottomRight,
          routeBuilder: (_) => const WidgetSettingsScreen(),
          keywords: ["home screen", "homescreen"],
        ),
        SettingsSearchItem(
          title: l10n.people,
          subtitle: l10n.widgets,
          sectionPath: l10n.widgets,
          icon: HugeIcons.strokeRoundedUserMultiple,
          routeBuilder: (_) => const WidgetSettingsScreen(),
          isSubPage: true,
          keywords: ["people", "faces", "widget"],
        ),
        SettingsSearchItem(
          title: l10n.albums,
          subtitle: l10n.widgets,
          sectionPath: l10n.widgets,
          icon: HugeIcons.strokeRoundedFolder01,
          routeBuilder: (_) => const WidgetSettingsScreen(),
          isSubPage: true,
          keywords: ["albums", "collections", "widget"],
        ),
        SettingsSearchItem(
          title: l10n.memories,
          subtitle: l10n.widgets,
          sectionPath: l10n.widgets,
          icon: HugeIcons.strokeRoundedSparkles,
          routeBuilder: (_) => const WidgetSettingsScreen(),
          isSubPage: true,
          keywords: ["memories", "widget"],
        ),
      ]);
    }

    if (hasLoggedIn && !isLocalGallery) {
      items.add(
        SettingsSearchItem(
          title: l10n.freeUpSpace,
          sectionPath: l10n.freeUpSpace,
          icon: HugeIcons.strokeRoundedRocket01,
          routeBuilder: (_) => const FreeUpSpaceOptionsScreen(),
          keywords: ["storage", "space", "clean", "delete", "local", "device"],
        ),
      );

      items.addAll([
        SettingsSearchItem(
          title: l10n.trash,
          subtitle: l10n.freeUpSpace,
          sectionPath: l10n.freeUpSpace,
          icon: HugeIcons.strokeRoundedDelete01,
          routeBuilder: (_) => const FreeUpSpaceOptionsScreen(),
          isSubPage: true,
          keywords: [
            "trash",
            "recently deleted",
            "restore",
            "permanently delete",
          ],
        ),
        SettingsSearchItem(
          title: l10n.freeUpDeviceSpace,
          subtitle: l10n.freeUpSpace,
          sectionPath: l10n.freeUpSpace,
          icon: HugeIcons.strokeRoundedRocket01,
          routeBuilder: (_) => const FreeUpSpaceOptionsScreen(),
          isSubPage: true,
          sectionItemPriority: 1,
          keywords: ["device space", "storage", "delete"],
        ),
        SettingsSearchItem(
          title: l10n.removeDuplicates,
          subtitle: l10n.freeUpSpace,
          sectionPath: l10n.freeUpSpace,
          icon: HugeIcons.strokeRoundedRocket01,
          routeBuilder: (_) => const FreeUpSpaceOptionsScreen(),
          isSubPage: true,
          keywords: [
            "duplicate",
            "duplicates",
            "same",
            "identical",
            "copy",
            "copies",
          ],
        ),
        if (flagService.enableVectorDb)
          SettingsSearchItem(
            title: l10n.similarImages,
            subtitle: l10n.freeUpSpace,
            sectionPath: l10n.freeUpSpace,
            icon: HugeIcons.strokeRoundedRocket01,
            routeBuilder: (_) => const FreeUpSpaceOptionsScreen(),
            isSubPage: true,
            keywords: ["similar", "alike", "resembling", "cleanup"],
          ),
        SettingsSearchItem(
          title: l10n.viewLargeFiles,
          subtitle: l10n.freeUpSpace,
          sectionPath: l10n.freeUpSpace,
          icon: HugeIcons.strokeRoundedFile01,
          routeBuilder: (_) => const FreeUpSpaceOptionsScreen(),
          isSubPage: true,
          keywords: ["large files", "big", "size", "storage"],
        ),
        SettingsSearchItem(
          title: l10n.manageDeviceStorage,
          subtitle: l10n.freeUpSpace,
          sectionPath: l10n.freeUpSpace,
          icon: HugeIcons.strokeRoundedSettings01,
          routeBuilder: (_) => const FreeUpSpaceOptionsScreen(),
          isSubPage: true,
          keywords: ["storage", "device", "cache"],
        ),
      ]);
    }

    items.add(
      SettingsSearchItem(
        title: l10n.about,
        sectionPath: l10n.about,
        icon: HugeIcons.strokeRoundedInformationCircle,
        routeBuilder: (_) => const AboutUsPage(),
        keywords: ["version"],
      ),
    );

    return items;
  }

  static List<SettingsSearchSuggestion> getSuggestions(BuildContext context) {
    final l10n = context.strings;
    final hasLoggedIn = Configuration.instance.hasConfiguredAccount();
    final isLocalGallery = isLocalGalleryMode;

    return [
      SettingsSearchSuggestion(
        title: l10n.gallery,
        routeBuilder: (_) =>
            const GallerySettingsScreen(fromGalleryLayoutSettingsCTA: false),
      ),
      if (hasLoggedIn && !isLocalGallery)
        SettingsSearchSuggestion(
          title: l10n.freeUpDeviceSpace,
          routeBuilder: (_) => const FreeUpSpaceOptionsScreen(),
        ),
      if (hasLoggedIn && !isLocalGallery)
        SettingsSearchSuggestion(
          title: l10n.backupSettings,
          routeBuilder: (_) => const BackupSettingsPage(),
        ),
    ];
  }
}
