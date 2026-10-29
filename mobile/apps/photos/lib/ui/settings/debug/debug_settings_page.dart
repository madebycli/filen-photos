import "package:flutter/material.dart";
import "package:hugeicons/hugeicons.dart";
import "package:photos/service_locator.dart";
import "package:photos/theme/ente_theme.dart";
import "package:photos/ui/components/menu_item_widget/menu_item_widget_new.dart";
import "package:photos/ui/components/settings/settings_grouped_card.dart";
import "package:photos/ui/components/toggle_switch_widget.dart";
import "package:photos/ui/notification/toast.dart";
import "package:photos/utils/background_tasks.dart";

class DebugSettingsPage extends StatefulWidget {
  const DebugSettingsPage({super.key});

  @override
  State<DebugSettingsPage> createState() => _DebugSettingsPageState();
}

class _DebugSettingsPageState extends State<DebugSettingsPage> {
  @override
  Widget build(BuildContext context) {
    final colorScheme = getEnteColorScheme(context);
    final textTheme = getEnteTextTheme(context);

    return Scaffold(
      backgroundColor: colorScheme.backgroundColour,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 24),
              GestureDetector(
                onTap: () => Navigator.of(context).pop(),
                child: Icon(
                  Icons.arrow_back,
                  color: colorScheme.strokeBase,
                  size: 24,
                ),
              ),
              const SizedBox(height: 24),
              Text("Debug", style: textTheme.h3Bold),
              const SizedBox(height: 24),
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    children: [
                      SettingsGroupedCard(
                        children: [
                          MenuItemWidgetNew(
                            title: "Disable internal user features",
                            leadingIconWidget: _buildIconWidget(
                              context,
                              HugeIcons.strokeRoundedUserBlock01,
                            ),
                            trailingWidget: ToggleSwitchWidget(
                              value: () => localSettings.isInternalUserDisabled,
                              onChanged: () async {
                                final newValue =
                                    !localSettings.isInternalUserDisabled;
                                await localSettings.setInternalUserDisabled(
                                  newValue,
                                );
                                await BackgroundTasks.configure().catchError(
                                  (Object _) {},
                                );
                                if (!mounted) return;
                                setState(() {});
                                if (!context.mounted) return;
                                showShortToast(
                                  context,
                                  newValue
                                      ? "Internal user disabled. Restart app."
                                      : "Internal user enabled. Restart app.",
                                );
                              },
                            ),
                          ),
                          if (flagService.internalUser)
                            MenuItemWidgetNew(
                              title: "Background sync notification",
                              leadingIconWidget: _buildIconWidget(
                                context,
                                HugeIcons.strokeRoundedNotification01,
                              ),
                              trailingWidget: ToggleSwitchWidget(
                                value: () =>
                                    localSettings.isBGDebugNotificationsEnabled,
                                onChanged: () async {
                                  final newValue = !localSettings
                                      .isBGDebugNotificationsEnabled;
                                  await localSettings
                                      .setBGDebugNotificationsEnabled(newValue);
                                  if (!mounted) return;
                                  setState(() {});
                                  if (!context.mounted) return;
                                  showShortToast(
                                    context,
                                    newValue
                                        ? "Background debug notifications enabled. Restart app."
                                        : "Background debug notifications disabled. Restart app.",
                                  );
                                },
                              ),
                            ),
                          MenuItemWidgetNew(
                            title: "Show local ID over thumbnails",
                            leadingIconWidget: _buildIconWidget(
                              context,
                              HugeIcons.strokeRoundedImage01,
                            ),
                            trailingWidget: ToggleSwitchWidget(
                              value: () =>
                                  localSettings.showLocalIDOverThumbnails,
                              onChanged: () async {
                                await localSettings
                                    .setShowLocalIDOverThumbnails(
                                      !localSettings.showLocalIDOverThumbnails,
                                    );
                                if (!mounted) return;
                                setState(() {});
                                if (!context.mounted) return;
                                showShortToast(
                                  context,
                                  localSettings.showLocalIDOverThumbnails
                                      ? "Local IDs will be shown. Restart app."
                                      : "Local IDs hidden. Restart app.",
                                );
                              },
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      const SettingsGroupedCard(children: []),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildIconWidget(BuildContext context, List<List<dynamic>> icon) {
    final colorScheme = getEnteColorScheme(context);
    return HugeIcon(
      icon: icon,
      color: colorScheme.menuItemIconStroke,
      size: 20,
    );
  }
}
