import 'package:ente_components/ente_components.dart';
import 'package:ente_pure_utils/ente_pure_utils.dart';
import 'package:filen_sdk/filen_sdk.dart';
import 'package:flutter/material.dart';
import 'package:hugeicons/hugeicons.dart';
import 'package:logging/logging.dart';
import 'package:photos/core/configuration.dart';
import 'package:photos/filen/filen_account.dart';
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
    final otherBytes = (used - data.photosBytes).clamp(0, used);
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
            if (info.unfinishedStorage > 0)
              SettingsItem(
                title: 'Unfinished uploads',
                subtitle:
                    '${formatBytes(info.unfinishedStorage)} in ${info.unfinishedFiles} files',
                icon: HugeIcons.strokeRoundedUpload01,
              ),
          ],
        ),
      ],
    );
  }
}
