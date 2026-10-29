import 'package:ente_components/ente_components.dart';
import 'package:ente_pure_utils/ente_pure_utils.dart';
import 'package:filen_sdk/filen_sdk.dart';
import 'package:flutter/material.dart';
import 'package:hugeicons/hugeicons.dart';
import 'package:logging/logging.dart';
import 'package:photos/core/configuration.dart';
import 'package:photos/filen/filen_account.dart';
import 'package:photos/ui/settings/backup/free_space_options.dart';
import 'package:photos/ui/viewer/gallery/trash_page.dart';
import 'package:url_launcher/url_launcher_string.dart';

/// Account and storage page for a Filen account: where the space goes, and the Filen settings that
/// matter for a photo library (versions of changed files, login alerts, password). Everything goes
/// through Filen's SDK; plan, e-mail, two-factor setup and account deletion stay in Filen's web app.
class FilenAccountSettingsPage extends StatefulWidget {
  const FilenAccountSettingsPage({super.key});

  @override
  State<FilenAccountSettingsPage> createState() =>
      _FilenAccountSettingsPageState();
}

class _Overview {
  _Overview(this.info, this.photosBytes, this.photosFiles);
  final FilenUserInfo info;
  final int photosBytes;
  final int photosFiles;
}

class _FilenAccountSettingsPageState extends State<FilenAccountSettingsPage> {
  static final _logger = Logger('FilenAccountSettings');
  static const _filenApp = 'https://app.filen.io';

  late Future<_Overview> _overview = _load();

  Future<_Overview> _load() async {
    final sdk = FilenSdk.instance;
    final info = await sdk.userInfo();
    var bytes = 0;
    var files = 0;
    try {
      final root = await FilenAccount.instance.photosRootUuid();
      final size = await sdk.dirSize(root);
      bytes = size.size;
      files = size.files;
    } catch (e, s) {
      _logger.warning('Could not measure the photo library', e, s);
    }
    return _Overview(info, bytes, files);
  }

  void _reload() => setState(() => _overview = _load());

  Future<void> _run(Future<void> Function() action, String failure) async {
    try {
      await action();
      _reload();
    } catch (e, s) {
      _logger.warning(failure, e, s);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('$failure ($e)')));
    }
  }

  Future<bool> _confirm(String title, String message, String yes) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(yes),
          ),
        ],
      ),
    );
    return result == true;
  }

  Future<void> _changePassword() async {
    final current = TextEditingController();
    final next = TextEditingController();
    final again = TextEditingController();
    String? error;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setLocal) => AlertDialog(
          title: const Text('Change password'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: current,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'Current password',
                ),
              ),
              TextField(
                controller: next,
                obscureText: true,
                decoration: const InputDecoration(labelText: 'New password'),
              ),
              TextField(
                controller: again,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'Repeat new password',
                ),
              ),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () {
                if (current.text.isEmpty || next.text.length < 8) {
                  setLocal(() => error = 'Use at least 8 characters.');
                } else if (next.text != again.text) {
                  setLocal(() => error = 'The new passwords differ.');
                } else {
                  Navigator.pop(context, true);
                }
              },
              child: const Text('Change'),
            ),
          ],
        ),
      ),
    );
    final currentPassword = current.text;
    final newPassword = next.text;
    current.dispose();
    next.dispose();
    again.dispose();
    if (ok != true || !mounted) return;
    try {
      await FilenSdk.instance.changePassword(
        current: currentPassword,
        newPassword: newPassword,
      );
    } on FilenException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            e.code == 'BAD_CREDENTIALS'
                ? 'The current password is wrong.'
                : 'Could not change the password (${e.code}).',
          ),
        ),
      );
      return;
    }
    if (!mounted) return;
    // The saved session was made with the old password: sign in again to keep it valid.
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('Password changed'),
        content: const Text(
          'Please sign in again with your new password. Your photos stay on Filen.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Sign in again'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    await FilenAccount.instance.logout(context);
  }

  @override
  Widget build(BuildContext context) {
    final email = Configuration.instance.getEmail() ?? '';
    return SettingsPageScaffold(
      title: 'Account',
      children: [
        SettingsItem(
          title: email,
          subtitle: 'Signed in with Filen',
          icon: HugeIcons.strokeRoundedUser,
        ),
        const SizedBox(height: 16),
        FutureBuilder<_Overview>(
          future: _overview,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return SettingsItem(
                title: 'Could not load storage details',
                subtitle: 'Tap to try again',
                icon: HugeIcons.strokeRoundedAlert02,
                onTap: () async => _reload(),
              );
            }
            final data = snapshot.data;
            if (data == null) {
              return const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              );
            }
            return _details(context, data);
          },
        ),
        const SizedBox(height: 16),
        SettingsItem(
          title: 'Free up space',
          subtitle: 'Device copies, duplicates, large files',
          icon: HugeIcons.strokeRoundedDelete02,
          onTap: () async {
            await routeToPage(context, const FreeUpSpaceOptionsScreen());
          },
        ),
        const SizedBox(height: 8),
        SettingsItem(
          title: 'Trash',
          subtitle: 'Restore or permanently delete removed photos',
          icon: HugeIcons.strokeRoundedRestoreBin,
          onTap: () async => showTrashPage(context),
        ),
        const SizedBox(height: 8),
        SettingsItem(
          title: 'Manage account on Filen',
          subtitle: 'Plan, e-mail, two-factor authentication, account deletion',
          icon: HugeIcons.strokeRoundedLinkSquare02,
          onTap: () async {
            await launchUrlString(
              _filenApp,
              mode: LaunchMode.externalApplication,
            );
          },
        ),
      ],
    );
  }

  Widget _details(BuildContext context, _Overview data) {
    final info = data.info;
    final used = info.storageUsed;
    final max = info.maxStorage;
    final otherBytes = (used - data.photosBytes - info.versionedStorage).clamp(
      0,
      used,
    );
    final fraction = max <= 0 ? 0.0 : (used / max).clamp(0.0, 1.0);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${formatBytes(used)} of ${formatBytes(max)} used',
          style: TextStyles.bodyBold,
        ),
        const SizedBox(height: 8),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(value: fraction, minHeight: 8),
        ),
        const SizedBox(height: 12),
        MenuGroupComponent(
          items: [
            SettingsItem(
              title: 'Photos and videos',
              subtitle:
                  '${formatBytes(data.photosBytes)} in ${data.photosFiles} files (Filen Photos folder)',
              icon: HugeIcons.strokeRoundedImage01,
            ),
            SettingsItem(
              title: 'Other files on Filen',
              subtitle: formatBytes(otherBytes),
              icon: HugeIcons.strokeRoundedFolder01,
            ),
            SettingsItem(
              title: 'Old versions of changed files',
              subtitle:
                  '${formatBytes(info.versionedStorage)} in ${info.versionedFiles} versions',
              icon: HugeIcons.strokeRoundedClock01,
            ),
            if (info.unfinishedStorage > 0)
              SettingsItem(
                title: 'Unfinished uploads',
                subtitle:
                    '${formatBytes(info.unfinishedStorage)} in ${info.unfinishedFiles} files',
                icon: HugeIcons.strokeRoundedUpload01,
              ),
          ],
        ),
        const SizedBox(height: 16),
        MenuGroupComponent(
          items: [
            MenuComponent(
              title: 'Keep old versions of changed files',
              trailing: ToggleSwitchComponent.async(
                value: () => info.versioningEnabled,
                onChanged: () => _run(
                  () =>
                      FilenSdk.instance.setVersioning(!info.versioningEnabled),
                  'Could not change versioning',
                ),
              ),
            ),
            MenuComponent(
              title: 'Email me about new logins',
              trailing: ToggleSwitchComponent.async(
                value: () => info.loginAlertsEnabled,
                onChanged: () => _run(
                  () => FilenSdk.instance.setLoginAlerts(
                    !info.loginAlertsEnabled,
                  ),
                  'Could not change login alerts',
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        SettingsItem(
          title: 'Delete old versions',
          subtitle: info.versionedStorage > 0
              ? 'Frees ${formatBytes(info.versionedStorage)}. The current files stay.'
              : 'There are no old versions.',
          icon: HugeIcons.strokeRoundedDelete01,
          onTap: info.versionedStorage > 0
              ? () async {
                  final yes = await _confirm(
                    'Delete old versions?',
                    'The ${info.versionedFiles} old versions on your whole Filen drive are removed for good. The current files are not touched.',
                    'Delete',
                  );
                  if (yes) {
                    await _run(
                      FilenSdk.instance.deleteAllVersions,
                      'Could not delete old versions',
                    );
                  }
                }
              : null,
        ),
        const SizedBox(height: 8),
        SettingsItem(
          title: 'Change password',
          subtitle: info.twoFactorEnabled
              ? 'Two-factor authentication is on'
              : 'Two-factor authentication is off',
          icon: HugeIcons.strokeRoundedLockPassword,
          onTap: () async => _changePassword(),
        ),
      ],
    );
  }
}
