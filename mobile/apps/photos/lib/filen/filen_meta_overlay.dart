import 'package:photos/filen/state/meta_store.dart';
import 'package:photos/models/file/file.dart';
import 'package:photos/models/location/location.dart';
import 'package:photos/models/metadata/file_magic.dart';

/// Ente stores "no position" as 0/0.
bool _hasPosition(Location? l) =>
    l != null &&
    l.latitude != null &&
    l.longitude != null &&
    !(l.latitude == 0 && l.longitude == 0);

/// The values of a local file that Filen cannot hold (see [FileMetaEntry.base]). Only meaningful
/// values are included, so a plain Filen listing never produces noise.
Map<String, dynamic>? baseMetaOf(EnteFile f) {
  final base = <String, dynamic>{
    if (f.localID != null &&
        !f.localID!.startsWith('ente-') &&
        f.localID!.isNotEmpty)
      'lid': f.localID,
    if (f.deviceFolder != null && f.deviceFolder!.isNotEmpty)
      'df': f.deviceFolder,
    if (f.hash != null && f.hash!.isNotEmpty) 'h': f.hash,
    if (_hasPosition(f.location)) ...{
      'la': f.location!.latitude,
      'lo': f.location!.longitude,
    },
    if ((f.duration ?? 0) > 0) 'd': f.duration,
    if (f.fileSubType != null && f.fileSubType! > 0) 'st': f.fileSubType,
  };
  return base.isEmpty ? null : base;
}

/// The metadata fields of a file row as a store entry.
FileMetaEntry metaEntryOf(EnteFile f) => FileMetaEntry(
  mmd: f.mMdEncodedJson,
  mv: f.mMdVersion,
  pub: f.pubMmdEncodedJson,
  pv: f.pubMmdVersion,
  base: baseMetaOf(f),
);

/// Writes [e] into the row: magic metadata only when its version is higher than the row's own, and
/// [FileMetaEntry.base] values only where the row has none yet.
void applyMetaEntry(EnteFile f, FileMetaEntry e) {
  if (e.mv > f.mMdVersion && e.mmd != null) {
    f.mMdEncodedJson = e.mmd;
    f.mMdVersion = e.mv;
    f.magicMetadata = MagicMetadata.fromEncodedJson(e.mmd!);
  }
  if (e.pv > f.pubMmdVersion && e.pub != null) {
    f.pubMmdEncodedJson = e.pub;
    f.pubMmdVersion = e.pv;
    f.pubMagicMetadata = PubMagicMetadata.fromEncodedJson(e.pub!);
  }
  final b = e.base;
  if (b == null) return;
  if (f.localID == null && b['lid'] is String) f.localID = b['lid'] as String;
  if ((f.deviceFolder ?? '').isEmpty && b['df'] is String) {
    f.deviceFolder = b['df'] as String;
  }
  if ((f.hash ?? '').isEmpty && b['h'] is String) f.hash = b['h'] as String;
  if (!_hasPosition(f.location) && b['la'] is num && b['lo'] is num) {
    f.location = Location(
      latitude: (b['la'] as num).toDouble(),
      longitude: (b['lo'] as num).toDouble(),
    );
  }
  if ((f.duration ?? 0) == 0 && b['d'] is num) {
    f.duration = (b['d'] as num).toInt();
  }
  if ((f.fileSubType ?? -1) <= 0 && b['st'] is num) {
    f.fileSubType = (b['st'] as num).toInt();
  }
}

/// Result of reconciling a freshly listed file with what the device and the cloud know.
class MetaReconciliation {
  const MetaReconciliation({required this.entry, required this.uploadNeeded});

  /// The winning values.
  final FileMetaEntry entry;

  /// The device has newer values than the cloud: queue them for upload.
  final bool uploadNeeded;
}

/// [local] is what the database row of this file holds (empty for a new file), [cloud] what the
/// state folder says. Used for every row of a sync.
MetaReconciliation reconcileMeta({
  required FileMetaEntry local,
  FileMetaEntry? cloud,
}) {
  if (cloud == null) {
    return MetaReconciliation(entry: local, uploadNeeded: !local.isEmpty);
  }
  final merged = local.mergedWith(cloud);
  return MetaReconciliation(
    entry: merged,
    uploadNeeded: merged != cloud && !local.isEmpty,
  );
}

/// Whether [mapped] (built from a fresh Filen listing) would change anything in the stored [row].
bool filenRowUnchanged(EnteFile row, EnteFile mapped) {
  return row.title == mapped.title &&
      row.fileSize == mapped.fileSize &&
      row.creationTime == mapped.creationTime &&
      row.modificationTime == mapped.modificationTime &&
      row.updationTime == mapped.updationTime &&
      row.mMdVersion == mapped.mMdVersion &&
      row.pubMmdVersion == mapped.pubMmdVersion &&
      row.hash == mapped.hash &&
      (row.duration ?? 0) == (mapped.duration ?? 0) &&
      row.deviceFolder == mapped.deviceFolder &&
      row.location?.latitude == mapped.location?.latitude &&
      row.location?.longitude == mapped.location?.longitude &&
      row.encryptedKey == mapped.encryptedKey &&
      row.collectionID == mapped.collectionID;
}
