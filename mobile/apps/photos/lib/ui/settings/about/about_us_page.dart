import "package:ente_components/ente_components.dart";
import "package:ente_strings/ente_strings.dart";
import "package:flutter/material.dart";
import "package:hugeicons/hugeicons.dart";
import "package:package_info_plus/package_info_plus.dart";

class AboutUsPage extends StatelessWidget {
  const AboutUsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return SettingsPageScaffold(
      title: context.strings.about,
      children: [
        FutureBuilder<PackageInfo>(
          future: PackageInfo.fromPlatform(),
          builder: (context, snapshot) {
            final info = snapshot.data;
            return SettingsItem(
              title: "Filen Photos",
              subtitle: info == null
                  ? null
                  : "${info.version} (${info.buildNumber})",
              icon: HugeIcons.strokeRoundedInformationCircle,
            );
          },
        ),
      ],
    );
  }
}
