import "package:ente_components/ente_components.dart";
import "package:ente_lock_screen/auth_util.dart";
import "package:ente_lock_screen/ui/lock_screen_options.dart";
import "package:ente_pure_utils/ente_pure_utils.dart";
import "package:ente_strings/ente_strings.dart";
import "package:ente_ui/pages/settings_search_page.dart";
import "package:flutter/foundation.dart";
import "package:flutter/material.dart";
import "package:hugeicons/hugeicons.dart";
import "package:local_auth/local_auth.dart";
import "package:photos/core/configuration.dart";
import 'package:photos/filen/filen_account.dart';
import 'package:photos/filen/ui/filen_account_settings_page.dart';
import 'package:photos/filen/ui/filen_login_page.dart';
import "package:photos/service_locator.dart";
import "package:photos/ui/notification/toast.dart";
import "package:photos/ui/settings/about/about_us_page.dart";
import "package:photos/ui/settings/appearance/appearance_settings_page.dart";
import "package:photos/ui/settings/backup/backup_settings_page.dart";
import "package:photos/ui/settings/backup/free_space_options.dart";
import "package:photos/ui/settings/debug/debug_settings_page.dart";
import "package:photos/ui/settings/debug/ml_debug_settings_page.dart";
import "package:photos/ui/settings/inherited_settings_state.dart";
import "package:photos/ui/settings/memories_settings_screen.dart";
import "package:photos/ui/settings/ml/machine_learning_settings_page.dart";
import "package:photos/ui/settings/notification_settings_screen.dart";
import "package:photos/ui/settings/search/settings_search_registry.dart";
import "package:photos/ui/settings/storage_card_widget.dart";
import "package:photos/ui/settings/widget_settings_screen.dart";
import "package:photos/utils/dialog_util.dart";

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const SettingsStateContainer(child: _SettingsBody());
  }
}

class _SettingsBody extends StatelessWidget {
  const _SettingsBody();

  @override
  Widget build(BuildContext context) {
    final colors = context.componentColors;
    final hasConfiguredAccount = Configuration.instance.hasConfiguredAccount();
    final showLoginEntry = isLocalGalleryMode && !hasConfiguredAccount;
    final hasFilenAccount = hasConfiguredAccount && !isLocalGalleryMode;
    final email = hasFilenAccount
        ? Configuration.instance.getEmail() ?? ""
        : "";
    final title = email.isEmpty ? context.strings.settings : email;

    return SettingsPageScaffold(
      title: title,
      actions: _buildHeaderActions(context),
      children: [
        if (showLoginEntry) ...[
          _buildOfflineLoginCard(context, colors),
          const SizedBox(height: 8),
        ],
        if (hasFilenAccount) ...[
          const StorageCardWidget(),
          const SizedBox(height: 16),
          _buildMenuItem(
            title: context.strings.account,
            icon: HugeIcons.strokeRoundedUser,
            onTap: () async {
              await routeToPage(context, const FilenAccountSettingsPage());
            },
          ),
          const SizedBox(height: 8),
          _buildMenuItem(
            title: context.strings.backup,
            icon: HugeIcons.strokeRoundedCloudUpload,
            onTap: () async {
              await routeToPage(context, const BackupSettingsPage());
            },
          ),
          const SizedBox(height: 8),
          _buildMenuItem(
            title: context.strings.freeUpSpace,
            icon: HugeIcons.strokeRoundedDelete02,
            onTap: () async {
              await routeToPage(context, const FreeUpSpaceOptionsScreen());
            },
          ),
          const SizedBox(height: 8),
        ],
        _buildMenuItem(
          title: context.strings.appLock,
          icon: HugeIcons.strokeRoundedSquareLock02,
          onTap: () async => _onAppLockTap(context),
        ),
        const SizedBox(height: 8),
        _buildMenuItem(
          title: context.strings.appearance,
          icon: HugeIcons.strokeRoundedPaintBoard,
          onTap: () async {
            await routeToPage(context, const AppearanceSettingsPage());
          },
        ),
        const SizedBox(height: 8),
        _buildFeaturesCard(context),
        const SizedBox(height: 8),
        _buildMenuItem(
          title: context.strings.about,
          icon: HugeIcons.strokeRoundedInformationCircle,
          onTap: () async {
            await routeToPage(context, const AboutUsPage());
          },
        ),
        if (hasFilenAccount) ...[
          const SizedBox(height: 8),
          _buildLogoutCard(context),
        ],
        if (hasFilenAccount && (flagService.internalUser || kDebugMode)) ...[
          const SizedBox(height: 8),
          _buildMenuItem(
            title: "Debug",
            icon: HugeIcons.strokeRoundedBug02,
            onTap: () async {
              await routeToPage(context, const DebugSettingsPage());
            },
          ),
          const SizedBox(height: 8),
          _buildMenuItem(
            title: "ML Debug",
            icon: HugeIcons.strokeRoundedAiBrain01,
            onTap: () async {
              await routeToPage(context, const MLDebugSettingsPage());
            },
          ),
          const SizedBox(height: 16),
        ],
        const SizedBox(height: 60),
      ],
    );
  }

  List<Widget> _buildHeaderActions(BuildContext context) {
    return [
      IconButtonComponent(
        variant: IconButtonComponentVariant.primary,
        shouldSurfaceExecutionStates: false,
        icon: const HugeIcon(icon: HugeIcons.strokeRoundedSearch01),
        onTap: () {
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (context) => SettingsSearchPage(
                items: SettingsSearchRegistry.getSearchableItems(context),
                suggestions: SettingsSearchRegistry.getSuggestions(context),
                onNavigate: (context, routeBuilder) {
                  Navigator.of(context).pop();
                  routeToPage(context, routeBuilder(context));
                },
              ),
            ),
          );
        },
      ),
    ];
  }

  SettingsItem _buildMenuItem({
    required String title,
    required List<List<dynamic>> icon,
    String? subtitle,
    Widget? trailing,
    Future<void> Function()? onTap,
    bool isDestructive = false,
  }) {
    return SettingsItem(
      title: title,
      subtitle: subtitle,
      icon: icon,
      trailing: trailing,
      isDestructive: isDestructive,
      onTap: onTap,
    );
  }

  void _openFilenLogin(BuildContext context) {
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const FilenLoginPage()));
  }

  // Filen fork: the only login is Filen's.
  Widget _buildOfflineLoginCard(BuildContext context, ColorTokens colors) {
    return _buildMenuItem(
      title: "Already have a Filen account?",
      icon: HugeIcons.strokeRoundedLogin01,
      subtitle: "Log in to Filen",
      trailing: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: colors.primary,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Icon(
          Icons.arrow_forward_rounded,
          color: colors.specialWhite,
          size: 20,
        ),
      ),
      onTap: () async => _openFilenLogin(context),
    );
  }

  Widget _buildFeaturesCard(BuildContext context) {
    return MenuGroupComponent(
      items: [
        _buildMenuItem(
          title: context.strings.machineLearning,
          icon: HugeIcons.strokeRoundedMagicWand01,
          onTap: () async {
            await routeToPage(context, const MachineLearningSettingsPage());
          },
        ),
        _buildMenuItem(
          title: context.strings.memories,
          icon: HugeIcons.strokeRoundedSparkles,
          onTap: () async {
            await routeToPage(context, const MemoriesSettingsScreen());
          },
        ),
        _buildMenuItem(
          title: context.strings.notifications,
          icon: HugeIcons.strokeRoundedNotification01,
          onTap: () async {
            await routeToPage(context, const NotificationSettingsScreen());
          },
        ),
        _buildMenuItem(
          title: context.strings.widgets,
          icon: HugeIcons.strokeRoundedAlignBoxBottomRight,
          onTap: () async {
            await routeToPage(context, const WidgetSettingsScreen());
          },
        ),
        _buildMapsMenuItem(context),
      ],
    );
  }

  SettingsItem _buildMapsMenuItem(BuildContext context) {
    return _buildMenuItem(
      title: context.strings.maps,
      icon: HugeIcons.strokeRoundedMaping,
      trailing: ToggleSwitchComponent.async(
        value: () => mapEnabled,
        onChanged: () async {
          final isEnabled = mapEnabled;
          try {
            await setMapEnabled(!isEnabled);
          } catch (e) {
            if (context.mounted) {
              showShortToast(context, context.strings.somethingWentWrong);
            }
            rethrow;
          }
        },
      ),
    );
  }

  Future<void> _onAppLockTap(BuildContext context) async {
    if (await LocalAuthentication().isDeviceSupported()) {
      if (!context.mounted) return;
      final bool result = await requestAuthentication(
        context,
        context.strings.authToChangeLockscreenSetting,
      );
      if (result) {
        if (!context.mounted) return;
        await Navigator.of(context).push(
          MaterialPageRoute(
            builder: (BuildContext context) {
              return const LockScreenOptions();
            },
          ),
        );
      }
    } else {
      if (!context.mounted) return;
      await showErrorDialog(
        context,
        context.strings.noSystemLockFound,
        context.strings.toEnableAppLockPleaseSetupDevicePasscodeOrScreen,
      );
    }
  }

  Widget _buildLogoutCard(BuildContext context) {
    return _buildMenuItem(
      title: context.strings.logout,
      icon: HugeIcons.strokeRoundedLogout05,
      isDestructive: true,
      onTap: () async {
        _onLogoutTapped(context);
      },
    );
  }

  void _onLogoutTapped(BuildContext context) {
    showChoiceActionSheet(
      context,
      title: context.strings.warning,
      body: context.strings.areYouSureYouWantToLogout,
      illustration: Image.asset("assets/warning-grey.png"),
      firstButtonLabel: context.strings.yes,
      isCritical: true,
      firstButtonOnTap: () async {
        await FilenAccount.instance.logout(context);
      },
    );
  }
}
