import 'package:ente_components/ente_components.dart';
import 'package:flutter/material.dart';
import 'package:hugeicons/hugeicons.dart';
import 'package:photos/core/configuration.dart';
import 'package:url_launcher/url_launcher_string.dart';

/// Account page for Filen accounts. Plan, password, e-mail, 2FA and account deletion are managed
/// by Filen; the app does not reimplement them (yet), so it points to Filen's own web app
/// instead of showing Ente's screens, which would talk to Ente's servers.
class FilenAccountSettingsPage extends StatelessWidget {
  const FilenAccountSettingsPage({super.key});

  static const _filenApp = 'https://app.filen.io';

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
        const SizedBox(height: 8),
        SettingsItem(
          title: 'Manage account on Filen',
          subtitle:
              'Plan, password, e-mail, two-factor authentication, account deletion',
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
}
