import 'dart:async';
import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:logging/logging.dart';
import 'package:photos/filen/state/rev_doc.dart';

/// Ente's per-file metadata as stored for a Filen file. Filen's own file metadata has no room for
/// it, so it lives in small shard documents in the state folder:
///
///  * private magic metadata (archive/hidden visibility...) and public magic metadata (edited
///    date, caption, location override, dimensions...), each with Ente's version counter;
///  * the [base] values only the uploading device knows (hash, GPS position, video duration, the
///    device folder and gallery id the file came from).
class FileMetaEntry {
  const FileMetaEntry({
    this.mmd,
    this.mv = 0,
    this.pub,
    this.pv = 0,
    this.base,
  });

  /// Private magic metadata JSON and its version (Ente's optimistic-concurrency counter).
  final String? mmd;
  final int mv;

  /// Public magic metadata JSON and version.
  final String? pub;
  final int pv;

  /// Values recorded when the file was uploaded; keys: `lid`, `df`, `h`, `la`, `lo`, `d`, `st`.
  final Map<String, dynamic>? base;

  bool get isEmpty => mv == 0 && pv == 0 && (base == null || base!.isEmpty);

  Map<String, dynamic> toJson() => {
    if (mmd != null) 'm': mmd,
    if (mv != 0) 'mv': mv,
    if (pub != null) 'p': pub,
    if (pv != 0) 'pv': pv,
    if (base != null && base!.isNotEmpty) 'b': base,
  };

  static FileMetaEntry fromJson(Map<String, dynamic> j) => FileMetaEntry(
    mmd: j['m'] as String?,
    mv: (j['mv'] as num?)?.toInt() ?? 0,
    pub: j['p'] as String?,
    pv: (j['pv'] as num?)?.toInt() ?? 0,
    base: j['b'] is Map<String, dynamic>
        ? Map<String, dynamic>.of(j['b'] as Map<String, dynamic>)
        : null,
  );

  /// Field-wise "higher version wins" for the magic metadata; [base] values are written once, so
  /// the existing ones win and the other side only adds missing keys.
  FileMetaEntry mergedWith(FileMetaEntry other) {
    final takeMmd = other.mv > mv;
    final takePub = other.pv > pv;
    final mergedBase = (base == null && other.base == null)
        ? null
        : <String, dynamic>{...?other.base, ...?base};
    return FileMetaEntry(
      mmd: takeMmd ? other.mmd : mmd,
      mv: takeMmd ? other.mv : mv,
      pub: takePub ? other.pub : pub,
      pv: takePub ? other.pv : pv,
      base: mergedBase,
    );
  }

  static const _eq = DeepCollectionEquality();

  @override
  bool operator ==(Object other) =>
      other is FileMetaEntry &&
      other.mmd == mmd &&
      other.mv == mv &&
      other.pub == pub &&
      other.pv == pv &&
      _eq.equals(other.base ?? const {}, base ?? const {});

  @override
  int get hashCode => Object.hash(mmd, mv, pub, pv, _eq.hash(base ?? const {}));
}

/// Cloud copy of the per-file magic metadata, sharded by the first two hex digits of the Filen file
/// uuid (at most 256 small documents), with a debounced write-behind queue.
class FilenMetaStore {
  FilenMetaStore(this._docs, {this.flushDelay = const Duration(seconds: 4)});

  static const String dir = 'meta';
  static final _logger = Logger('FilenMetaStore');

  final RevDocs _docs;
  final Duration flushDelay;

  final Map<String, FileMetaEntry> _remote = {};
  final Map<String, String> _mergedTags = {};
  final Map<String, FileMetaEntry> _dirty = {};
  Timer? _timer;
  Future<void> _flushing = Future.value();

  static String shardOf(String uuid) {
    final hex = uuid.replaceAll('-', '').toLowerCase();
    return hex.substring(0, 2);
  }

  /// What the cloud knows about [uuid] (as of the last [pull]).
  FileMetaEntry? remote(String uuid) => _remote[uuid];

  /// What the cloud has plus what is queued to be written: the view every device would see soon.
  FileMetaEntry? effective(String uuid) {
    final cloud = _remote[uuid];
    final queued = _dirty[uuid];
    if (queued == null) return cloud;
    return cloud == null ? queued : cloud.mergedWith(queued);
  }

  /// Downloads the shards that changed since the last call. One listing plus one read per changed
  /// shard, so calling it on every sync is cheap.
  Future<void> pull() async {
    final files = await _docs.store.list(dir);
    for (final base in RevDocs.basesOf(files)) {
      final rev = RevDocs.revisionsOf(base, files).first;
      if (_mergedTags[base] == rev.tag) continue;
      final doc = await _docs.read(dir, base);
      if (doc == null) continue;
      for (final e in doc.entries) {
        final value = e.value;
        if (value is! Map<String, dynamic>) continue;
        final incoming = FileMetaEntry.fromJson(value);
        final known = _remote[e.key];
        _remote[e.key] = known == null ? incoming : known.mergedWith(incoming);
      }
      _mergedTags[base] = rev.tag;
    }
  }

  /// Queue [entry] for [uuid] to be written to the cloud shortly.
  void queue(String uuid, FileMetaEntry entry) {
    if (entry.isEmpty) return;
    final known = _remote[uuid];
    if (known != null && known.mergedWith(entry) == known) return;
    final pending = _dirty[uuid];
    _dirty[uuid] = pending == null ? entry : pending.mergedWith(entry);
    _timer?.cancel();
    _timer = Timer(flushDelay, () => unawaited(flush()));
  }

  bool get hasPending => _dirty.isNotEmpty;

  /// Writes everything queued so far. Safe to call concurrently; calls run one after another.
  Future<void> flush() {
    _timer?.cancel();
    return _flushing = _flushing.then((_) => _flushNow()).catchError((
      Object e,
      StackTrace s,
    ) {
      _logger.warning(
        'Could not write file metadata to Filen, will retry',
        e,
        s,
      );
    });
  }

  Future<void> _flushNow() async {
    if (_dirty.isEmpty) return;
    final batch = Map<String, FileMetaEntry>.of(_dirty);
    final byShard = <String, Map<String, FileMetaEntry>>{};
    for (final e in batch.entries) {
      byShard.putIfAbsent(shardOf(e.key), () => {})[e.key] = e.value;
    }
    try {
      for (final shard in byShard.entries) {
        final written = await _docs.update(dir, shard.key, (current) {
          final next = Map<String, dynamic>.of(current);
          var changed = false;
          for (final e in shard.value.entries) {
            final existing = current[e.key] is Map<String, dynamic>
                ? FileMetaEntry.fromJson(current[e.key] as Map<String, dynamic>)
                : const FileMetaEntry();
            final merged = existing.mergedWith(e.value);
            if (merged != existing) {
              next[e.key] = merged.toJson();
              changed = true;
            }
          }
          return changed ? next : null;
        });
        for (final e in shard.value.entries) {
          _remote[e.key] = (_remote[e.key] ?? const FileMetaEntry()).mergedWith(
            e.value,
          );
          if (_dirty[e.key] == e.value) {
            _dirty.remove(e.key);
          }
        }
        if (written != null) {
          _mergedTags.remove(shard.key); // re-read on next pull
        }
      }
    } catch (_) {
      // Entries stay in _dirty; the next flush retries them.
      _timer = Timer(flushDelay * 4, () => unawaited(flush()));
      rethrow;
    }
  }

  /// Visible for tests.
  static String encode(Map<String, dynamic> json) => jsonEncode(json);
}
