import 'dart:typed_data';

import 'package:photos/filen/state/blob_store.dart';

/// Small previews of the photos, kept on Filen so that a new device (or a reinstall) shows the
/// grid at once instead of downloading and decoding every original.
///
/// One immutable file per photo: `thumbs/<xx>/<uuid>.t1` (xx = first two hex digits of the uuid),
/// holding the image bytes as they were produced (JPEG or WebP). A better preview later gets a
/// new generation number in the name; readers use the highest one they know.
class FilenThumbStore {
  FilenThumbStore(
    this._store, {
    this.maxIndexAge = const Duration(minutes: 10),
  });

  final FilenBlobStore _store;
  final Duration maxIndexAge;

  /// uuid -> newest generation file, filled by [ensureIndexed].
  final Map<String, ({BlobInfo blob, int generation})> _index = {};
  DateTime? _indexedAt;
  Future<void>? _loading;

  static final RegExp _name = RegExp(r'^([0-9a-f-]{36})\.t(\d+)$');
  static const int currentGeneration = 1;

  static String shardOf(String uuid) =>
      uuid.replaceAll('-', '').substring(0, 2).toLowerCase();
  static String dirOf(String uuid) => 'thumbs/${shardOf(uuid)}';
  static String fileName(String uuid, int generation) => '$uuid.t$generation';

  bool get isIndexed => _indexedAt != null;

  /// Lists the whole `thumbs` folder with one request. Repeated calls within [maxIndexAge] cost
  /// nothing; pass [force] after a miss that another device may have filled meanwhile.
  Future<void> ensureIndexed({bool force = false}) {
    final at = _indexedAt;
    if (!force && at != null && DateTime.now().difference(at) < maxIndexAge) {
      return Future.value();
    }
    return _loading ??= _load().whenComplete(() => _loading = null);
  }

  Future<void> _load() async {
    final all = await _store.listRecursive('thumbs');
    final next = <String, ({BlobInfo blob, int generation})>{};
    for (final files in all.values) {
      for (final f in files) {
        final m = _name.firstMatch(f.name);
        if (m == null) continue;
        final uuid = m.group(1)!;
        final gen = int.parse(m.group(2)!);
        final known = next[uuid];
        if (known == null || gen > known.generation) {
          next[uuid] = (blob: f, generation: gen);
        }
      }
    }
    // Keep what this process wrote meanwhile.
    for (final e in _index.entries) {
      final known = next[e.key];
      if (known == null || e.value.generation > known.generation) {
        next[e.key] = e.value;
      }
    }
    _index
      ..clear()
      ..addAll(next);
    _indexedAt = DateTime.now();
  }

  bool has(String uuid) => _index.containsKey(uuid);

  /// The stored preview, or null when there is none (or it cannot be read).
  Future<Uint8List?> get(String uuid) async {
    final entry = _index[uuid];
    if (entry == null) return null;
    try {
      return await _store.readById(entry.blob.id);
    } catch (_) {
      return null;
    }
  }

  /// Stores [bytes] unless a preview of the same or a newer generation exists.
  Future<void> put(
    String uuid,
    Uint8List bytes, {
    int generation = currentGeneration,
  }) async {
    final known = _index[uuid];
    if (known != null && known.generation >= generation) return;
    try {
      final info = await _store.write(
        dirOf(uuid),
        fileName(uuid, generation),
        bytes,
      );
      _index[uuid] = (blob: info, generation: generation);
    } on StateError {
      // Another device wrote the same generation first: fine.
    }
  }
}
