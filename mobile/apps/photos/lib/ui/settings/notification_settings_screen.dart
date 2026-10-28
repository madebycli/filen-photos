import "package:ente_components/ente_components.dart";
import "package:ente_strings/ente_strings.dart";
import "package:flutter/material.dart";
import "package:photos/service_locator.dart";
import "package:photos/services/notification_service.dart";

class NotificationSettingsScreen extends StatefulWidget {
  const NotificationSettingsScreen({super.key});

  @override
  State<NotificationSettingsScreen> createState() =>
      _NotificationSettingsScreenState();
}

class _NotificationSettingsScreenState
    extends State<NotificationSettingsScreen> {
  bool _hasPermission = false;

  @override
  void initState() {
    super.initState();
    NotificationService.instance.hasGrantedPermissions().then((granted) {
      if (mounted && _hasPermission != granted) {
        setState(() => _hasPermission = granted);
      }
    });
  }

  Future<void> _toggleWithPermission(
    bool Function() getValue,
    Future<void> Function(bool value) setValue,
  ) async {
    final oldValue = _hasPermission && getValue();

    if (_hasPermission) {
      await setValue(!oldValue);
      if (mounted) setState(() {});
      return;
    }

    final granted = await NotificationService.instance.requestPermissions(
      context,
    );

    if (!granted) {
      return;
    }

    _hasPermission = true;
    await setValue(true);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.strings;
    final showOnlyOnThisDay = isLocalGalleryMode;

    return SettingsPageScaffold(
      title: l10n.notifications,
      children: [
        SettingsItem(
          title: l10n.onThisDayMemories,
          subtitle: l10n.onThisDayNotificationExplanation,
          subtitleMaxLines: 2,
          showChevron: false,
          trailing: ToggleSwitchComponent.async(
            value: () =>
                _hasPermission && localSettings.isOnThisDayNotificationsEnabled,
            onChanged: () => _toggleWithPermission(
              () => localSettings.isOnThisDayNotificationsEnabled,
              memoriesCacheService.setOnThisDayNotifications,
            ).ignore(),
            showStateIcon: false,
          ),
        ),
        if (!showOnlyOnThisDay) ...[
          const SizedBox(height: 8),
          SettingsItem(
            title: l10n.birthdays,
            subtitle: l10n.receiveRemindersOnBirthdays,
            subtitleMaxLines: 2,
            showChevron: false,
            trailing: ToggleSwitchComponent.async(
              value: () =>
                  _hasPermission && localSettings.birthdayNotificationsEnabled,
              onChanged: () => _toggleWithPermission(
                () => localSettings.birthdayNotificationsEnabled,
                memoriesCacheService.setBirthdayNotifications,
              ).ignore(),
              showStateIcon: false,
            ),
          ),
        ],
      ],
    );
  }
}
