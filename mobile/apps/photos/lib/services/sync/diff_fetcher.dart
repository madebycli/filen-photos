import 'package:photos/filen/filen_sync.dart';
import 'package:photos/models/file/file.dart';

/// Reads what changed in a collection. Filen has no "changes since" feed, so the diff is computed
/// against the current Filen listing, see `FilenSyncService.getDiff`.
class DiffFetcher {
  Future<Diff> getEncryptedFilesDiff(int collectionID, int sinceTime) {
    return FilenSyncService.instance.getDiff(collectionID);
  }
}

class Diff {
  final List<EnteFile> updatedFiles;
  final List<EnteFile> deletedFiles;
  final bool hasMore;
  final int latestUpdatedAtTime;

  Diff(
    this.updatedFiles,
    this.deletedFiles,
    this.hasMore,
    this.latestUpdatedAtTime,
  );
}
