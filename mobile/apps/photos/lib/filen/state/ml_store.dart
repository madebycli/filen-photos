import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:photos/filen/state/blob_store.dart';

/// On-device ML results (face embeddings, CLIP embeddings...) per photo, so that a reinstall or a
/// second device restores them instead of recomputing for hours.
///
/// One gzip-compressed JSON file per photo and data type, immutable once written:
///   `ml/<xx>/<uuid>.<type>.v<version>.json.gz`   with xx = first two hex digits of the uuid.
/// A newer ML version writes a new file; readers use the highest version they understand.
class FilenMlStore {
  FilenMlStore(this._store);

  final FilenBlobStore _store;

  /// Per shard: file name -> blob. Filled by [refresh], kept for the process lifetime.
  final Map<String, Map<String, BlobInfo>> _index = {};
  bool _complete = false;

  static final RegExp _name = RegExp(
    r'^([0-9a-f-]{36})\.([A-Za-z]+)\.v(\d+)\.json\.gz$',
  );

  static String shardOf(String uuid) =>
      uuid.replaceAll('-', '').substring(0, 2).toLowerCase();
  static String dirOf(String uuid) => 'ml/${shardOf(uuid)}';
  static String fileName(String uuid, String type, int version) =>
      '$uuid.$type.v$version.json.gz';

  Future<void>? _refreshing;

  /// Lists the whole `ml` folder with one request, so later lookups know which photos have data
  /// without a request per photo. Concurrent callers share one run.
  Future<void> refresh() {
    return _refreshing ??= _refresh().whenComplete(() => _refreshing = null);
  }

  Future<void> _refresh() async {
    final all = await _store.listRecursive('ml');
    _index
      ..clear()
      ..addAll({
        for (final e in all.entries)
          if (e.key.isNotEmpty) e.key: {for (final f in e.value) f.name: f},
      });
    _complete = true;
  }

  /// Refreshes the listing once per process; later calls return immediately.
  Future<void> ensureIndexed() => _complete ? Future.value() : refresh();

  bool get isIndexed => _complete;

  /// Whether the cloud has [type] data for [uuid] (any version). Only meaningful after [refresh].
  bool has(String uuid, String type) => _best(uuid, type) != null;

  ({BlobInfo blob, int version})? _best(
    String uuid,
    String type, {
    int? atMost,
  }) {
    final shard = _index[shardOf(uuid)];
    if (shard == null) return null;
    ({BlobInfo blob, int version})? best;
    final prefix = '$uuid.$type.v';
    for (final e in shard.entries) {
      if (!e.key.startsWith(prefix)) continue;
      final m = _name.firstMatch(e.key);
      if (m == null) continue;
      final v = int.parse(m.group(3)!);
      if (atMost != null && v > atMost) continue;
      if (best == null || v > best.version) best = (blob: e.value, version: v);
    }
    return best;
  }

  /// The decoded JSON map for [uuid]/[type], or null when absent or unreadable.
  Future<Map<String, dynamic>?> get(
    String uuid,
    String type, {
    int? maxVersion,
  }) async {
    final best = _best(uuid, type, atMost: maxVersion);
    if (best == null) return null;
    try {
      final bytes = await _store.readById(best.blob.id);
      final decoded = jsonDecode(utf8.decode(gzip.decode(bytes)));
      return decoded is Map<String, dynamic> ? decoded : null;
    } on FormatException {
      return null;
    } on FileSystemException {
      return null;
    }
  }

  /// Stores [data]; does nothing when this exact version is already there.
  Future<void> put(
    String uuid,
    String type,
    int version,
    Map<String, dynamic> data,
  ) async {
    final name = fileName(uuid, type, version);
    final shard = shardOf(uuid);
    final known = _index[shard]?[name];
    if (known != null) return;
    final bytes = Uint8List.fromList(
      gzip.encode(utf8.encode(jsonEncode(data))),
    );
    try {
      final info = await _store.write('ml/$shard', name, bytes);
      (_index[shard] ??= {})[name] = info;
    } on StateError {
      // Already present (written by another device meanwhile): nothing to do.
    }
  }
}
