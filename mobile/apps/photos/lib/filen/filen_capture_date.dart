import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ente_pure_utils/ente_pure_utils.dart' show areFromSameDay;
import 'package:exif_reader/exif_reader.dart';
import 'package:logging/logging.dart';
import 'package:path_provider/path_provider.dart';
import 'package:photos/core/event_bus.dart';
import 'package:photos/db/files_db.dart';
import 'package:photos/events/force_reload_home_gallery_event.dart';
import 'package:photos/filen/filen_file_access.dart';
import 'package:photos/filen/filen_ids.dart';
import 'package:photos/models/file/file.dart';
import 'package:photos/models/file/file_type.dart';
import 'package:photos/models/metadata/file_magic.dart';
import 'package:photos/module/metadata/exif.dart';
import 'package:photos/services/file_magic_service.dart';
import 'package:photos/utils/network_util.dart';

final _logger = Logger('FilenCaptureDate');
Timer? _reloadTimer;

/// Filen only knows the times of the uploader's file system, so a library copied from a computer
/// is first filed by those (see `captureTimeMicros`). The photo's own EXIF date is the truth; it
/// is stored as the edited time in the Filen state folder (the files on Filen are not touched),
/// which also reaches the other devices. A date set by the user is never replaced.
Future<Map<String, dynamic>?> captureDateUpdate(
  EnteFile file,
  Map<String, IfdTag> exif,
) async {
  if (file.pubMagicMetadata?.editedTime != null) return null;
  final parsed = await tryParseExifDateTime(null, exif);
  if (parsed == null) return null;
  final taken = parsed.time.microsecondsSinceEpoch;
  final current = file.creationTime;
  if (current != null && areFromSameDay(current, taken)) return null;
  return {
    editTimeKey: taken,
    if (parsed.dateTime != null) dateTimeKey: parsed.dateTime,
    if (parsed.offsetTime != null) offsetTimeKey: parsed.offsetTime,
  };
}

void _reloadGallerySoon() {
  // Many photos can be corrected in a row: reload the gallery once afterwards.
  _reloadTimer?.cancel();
  _reloadTimer = Timer(const Duration(seconds: 8), () {
    Bus.instance.fire(ForceReloadHomeGalleryEvent('FilenCaptureDate'));
  });
}

bool _isPhoto(EnteFile f) =>
    f.fileType == FileType.image || f.fileType == FileType.livePhoto;

/// For a photo whose original was just downloaded (viewing, ML): the EXIF date, if it differs.
Future<void> correctCaptureDateFromOriginal(
  EnteFile file,
  File original,
) async {
  try {
    if (!_isPhoto(file) || file.uploadedFileID == null) return;
    final exif = await tryExifFromFile(original);
    if (exif == null) return;
    final update = await captureDateUpdate(file, exif);
    if (update == null) return;
    await FileMagicService.instance.updatePublicMagicMetadata([file], update);
    _logger.info('${file.tag}: capture date set from EXIF');
    _reloadGallerySoon();
  } catch (e, s) {
    _logger.warning('Could not read the capture date of ${file.tag}', e, s);
  }
}

/// Reads the capture date of every photo from the start of its file (where EXIF lives) through the
/// SDK's stream URL: about 96 KB per photo instead of the whole original, nothing is stored but
/// the date. Photos that were looked at once are remembered and not asked again.
class FilenCaptureDateScan {
  FilenCaptureDateScan._();
  static final instance = FilenCaptureDateScan._();

  static const _headBytes = 96 * 1024;
  static const _workers = 3;
  static const _batch = 100;

  bool _running = false;

  Future<File> _doneFile() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/filen_capture_scan.txt');
  }

  Future<Set<int>> _loadDone() async {
    try {
      final f = await _doneFile();
      if (!await f.exists()) return {};
      return (await f.readAsLines()).map(int.tryParse).whereType<int>().toSet();
    } catch (e) {
      _logger.warning('Could not read the scan state', e);
      return {};
    }
  }

  Future<void> run() async {
    if (_running) return;
    _running = true;
    try {
      if (!await canUseHighBandwidth()) return;
      final done = await _loadDone();
      final all = await FilesDB.instance.getAllFilesFromDB(const {});
      final todo = <EnteFile>[
        for (final f in all)
          if (_isPhoto(f) &&
              f.uploadedFileID != null &&
              isFilenFile(f) &&
              f.pubMagicMetadata?.editedTime == null &&
              !done.contains(f.uploadedFileID))
            f,
      ];
      if (todo.isEmpty) return;
      _logger.info('Reading the capture date of ${todo.length} photos');
      final log = (await _doneFile()).openWrite(mode: FileMode.append);
      var next = 0;
      var fixed = 0;
      final pending = <EnteFile, Map<String, dynamic>>{};
      Future<void> flush() async {
        if (pending.isEmpty) return;
        final batch = Map.of(pending);
        pending.clear();
        await FileMagicService.instance.updatePublicMagicMetadata(
          batch.keys.toList(),
          null,
          metadataUpdateMap: {
            for (final e in batch.entries) e.key.uploadedFileID!: e.value,
          },
        );
        fixed += batch.length;
        _reloadGallerySoon();
      }

      Future<void> worker() async {
        while (next < todo.length) {
          final file = todo[next++];
          try {
            final exif = await _readHead(file);
            if (exif != null) {
              final update = await captureDateUpdate(file, exif);
              if (update != null) {
                pending[file] = update;
                if (pending.length >= _batch) await flush();
              }
            }
            log.writeln(file.uploadedFileID);
          } catch (e) {
            // Left out of the done list: the next run tries it again.
            _logger.fine('No capture date for ${file.tag}: $e');
          }
        }
      }

      await Future.wait([for (var i = 0; i < _workers; i++) worker()]);
      await flush();
      await log.close();
      _logger.info('Capture dates: $fixed of ${todo.length} photos corrected');
    } catch (e, s) {
      _logger.warning('Capture date scan stopped', e, s);
    } finally {
      _running = false;
    }
  }

  Future<Map<String, IfdTag>?> _readHead(EnteFile file) async {
    final url = await filenStreamUrl(file);
    final client = HttpClient();
    try {
      final request = await client.getUrl(Uri.parse(url));
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-${_headBytes - 1}');
      final response = await request.close();
      final bytes = <int>[];
      await for (final chunk in response) {
        bytes.addAll(chunk);
        if (bytes.length >= _headBytes) break;
      }
      final exif = await readExifFromBytes(
        Uint8List.fromList(
          bytes.sublist(0, math.min(bytes.length, _headBytes)),
        ),
      );
      return exif.tags.isEmpty ? null : exif.tags;
    } finally {
      client.close(force: true);
    }
  }
}
