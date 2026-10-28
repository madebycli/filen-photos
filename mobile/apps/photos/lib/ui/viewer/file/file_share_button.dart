import "dart:async";
import "dart:io";

import "package:ente_strings/ente_strings.dart";
import "package:flutter/cupertino.dart";
import "package:flutter/material.dart";
import "package:hugeicons/hugeicons.dart";

class FileShareButton extends StatefulWidget {
  const FileShareButton({required this.onSendFile, super.key});

  final FutureOr<void> Function() onSendFile;

  @override
  State<FileShareButton> createState() => _FileShareButtonState();
}

class _FileShareButtonState extends State<FileShareButton> {
  bool _sharing = false;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: context.strings.share,
      icon: Platform.isAndroid
          ? const HugeIcon(
              icon: HugeIcons.strokeRoundedShare08,
              color: Colors.white,
            )
          : const Icon(CupertinoIcons.share, color: Colors.white),
      onPressed: _share,
    );
  }

  Future<void> _share() async {
    if (_sharing) return;
    _sharing = true;
    try {
      await widget.onSendFile();
    } finally {
      _sharing = false;
    }
  }
}
