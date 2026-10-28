import "dart:async";

import "package:logging/logging.dart";
import "package:photos/filen/filen_ml.dart";
import "package:photos/models/file/file.dart";
import "package:photos/services/filedata/model/file_data.dart";
import "package:photos/services/filedata/model/response.dart";
import "package:shared_preferences/shared_preferences.dart";

/// The results of the on-device machine learning (face and CLIP embeddings) per photo. They are
/// stored on Filen (see `FilenMl`), so a new device or a reinstall restores them instead of
/// running the models over every photo again.
class FileDataService {
  final _logger = Logger("FileDataService");
  // ignore: unused_field
  final SharedPreferences _prefs;
  Future<void>? _syncFDStatusFuture;

  FileDataService(this._prefs);

  Future<void> putFileData(EnteFile file, FileDataEntity data) async {
    data.validate();
    try {
      await FilenMl.put(file, data);
    } catch (e, s) {
      _logger.severe("putFileData failed", e, s);
      rethrow;
    }
  }

  Future<FileDataResponse> getFilesData(
    Set<int> fileIds, {
    DataType type = DataType.mlData,
  }) async {
    try {
      return await FilenMl.get(fileIds, type);
    } catch (e, s) {
      _logger.severe("Failed to get embeddings", e, s);
      rethrow;
    }
  }

  /// Refreshes the listing of stored ML results (other devices may have added some).
  Future<void> syncFDStatus() {
    final existing = _syncFDStatusFuture;
    if (existing != null) {
      _logger.info("syncFDStatus already running, joining existing run");
      return existing;
    }
    final future = _syncFDStatusInternal();
    _syncFDStatusFuture = future;
    return future.whenComplete(() {
      if (identical(_syncFDStatusFuture, future)) {
        _syncFDStatusFuture = null;
      }
    });
  }

  Future<void> _syncFDStatusInternal() async {
    try {
      await FilenMl.refreshIndex();
    } catch (e, s) {
      _logger.warning("Could not list ML data on Filen", e, s);
    }
  }
}
