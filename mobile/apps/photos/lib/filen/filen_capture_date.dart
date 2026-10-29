import 'dart:async';
import 'dart:io';

import 'package:ente_pure_utils/ente_pure_utils.dart' show areFromSameDay;
import 'package:logging/logging.dart';
import 'package:photos/core/event_bus.dart';
import 'package:photos/events/force_reload_home_gallery_event.dart';
import 'package:photos/models/file/file.dart';
import 'package:photos/models/file/file_type.dart';
import 'package:photos/models/metadata/file_magic.dart';
import 'package:photos/module/metadata/exif.dart';
import 'package:photos/services/file_magic_service.dart';

final _logger = Logger('FilenCaptureDate');
Timer? _reloadTimer;

/// Filen only knows the times of the uploader's file system, so a library copied from a computer
/// is first filed by those (see `captureTimeMicros`). Once the original of a photo is on the
/// device anyway (viewing, ML), its EXIF date is stored as the edited time, which also reaches the
/// other devices through the state folder. A date set by the user is never replaced.
Future<void> correctCaptureDateFromOriginal(
  EnteFile file,
  File original,
) async {
  try {
    if (file.fileType != FileType.image &&
        file.fileType != FileType.livePhoto) {
      return;
    }
    if (file.uploadedFileID == null ||
        file.pubMagicMetadata?.editedTime != null) {
      return;
    }
    final exif = await tryExifFromFile(original);
    if (exif == null) return;
    final parsed = await tryParseExifDateTime(null, exif);
    if (parsed == null) return;
    final taken = parsed.time.microsecondsSinceEpoch;
    final current = file.creationTime;
    if (current != null && areFromSameDay(current, taken)) return;
    await FileMagicService.instance.updatePublicMagicMetadata(
      [file],
      {
        editTimeKey: taken,
        if (parsed.dateTime != null) dateTimeKey: parsed.dateTime,
        if (parsed.offsetTime != null) offsetTimeKey: parsed.offsetTime,
      },
    );
    _logger.info('${file.tag}: capture date set from EXIF');
    // Many photos can be corrected in a row (ML pass): reload the gallery once afterwards.
    _reloadTimer?.cancel();
    _reloadTimer = Timer(const Duration(seconds: 8), () {
      Bus.instance.fire(ForceReloadHomeGalleryEvent('FilenCaptureDate'));
    });
  } catch (e, s) {
    _logger.warning('Could not read the capture date of ${file.tag}', e, s);
  }
}
