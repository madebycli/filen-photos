import 'package:logging/logging.dart';
import 'package:photos/db/files_db.dart';
import 'package:photos/filen/filen_ids.dart';
import 'package:photos/filen/filen_state.dart';
import 'package:photos/models/file/file.dart';
import 'package:photos/services/filedata/model/file_data.dart';
import 'package:photos/services/filedata/model/response.dart';

/// On-device ML results (faces, CLIP embeddings) kept on Filen so that a reinstall or a second
/// device restores them instead of recomputing, see `state/ml_store.dart`.
class FilenMl {
  FilenMl._();

  static final _logger = Logger('FilenMl');
  static const _type = 'mldata';

  /// One number that grows whenever either model version grows: the cloud copy is only replaced
  /// by a newer one.
  static int versionOf(Map<String, dynamic> raw) {
    int v(String key) {
      final part = raw[key];
      return part is Map<String, dynamic>
          ? (part['version'] as num?)?.toInt() ?? 0
          : 0;
    }

    return v('face') * 1000 + v('clip');
  }

  static Future<void> put(EnteFile file, FileDataEntity data) async {
    if (!isFilenFile(file)) return;
    final state = FilenState.instance;
    await state.ensureInitialized();
    await state.ml.ensureIndexed();
    await state.ml.put(
      filenUuidOf(file),
      _type,
      versionOf(data.remoteRawData),
      data.remoteRawData,
    );
  }

  /// Cloud ML data for [ids] (Ente file ids). Photos without data are simply absent.
  static Future<FileDataResponse> get(Set<int> ids, DataType type) async {
    final state = FilenState.instance;
    await state.ensureInitialized();
    await state.ml.ensureIndexed();
    final files = await FilesDB.instance.getFileIDToFileFromIDs(ids.toList());
    final found = <int, FileDataEntity>{};
    final failed = <int>{};
    final todo = <(int, String)>[
      for (final e in files.entries)
        if (isFilenFile(e.value) &&
            state.ml.has(filenUuidOf(e.value), type.value))
          (e.key, filenUuidOf(e.value)),
    ];
    for (var i = 0; i < todo.length; i += 16) {
      await Future.wait([
        for (final (id, uuid) in todo.skip(i).take(16))
          () async {
            try {
              final json = await state.ml.get(uuid, type.value);
              if (json != null) {
                found[id] = FileDataEntity.fromRemote(id, type.value, json);
              }
            } catch (e, s) {
              failed.add(id);
              _logger.warning('Could not read ML data of a photo', e, s);
            }
          }(),
      ]);
    }
    return FileDataResponse(
      found,
      fetchErrorFileIDs: failed,
      pendingIndexFileIDs: {},
    );
  }

  /// Re-reads the cloud listing (after other devices may have added data).
  static Future<void> refreshIndex() async {
    final state = FilenState.instance;
    await state.ensureInitialized();
    await state.ml.refresh();
  }
}
