import 'dart:async';
import 'dart:convert';

import 'package:logging/logging.dart';
import 'package:photos/filen/state/rev_doc.dart';

/// Minimal persistent string storage (SharedPreferences in the app, a map in tests).
abstract class StringStorage {
  String? read(String key);
  Future<void> write(String key, String? value);
}

class MapStringStorage implements StringStorage {
  final Map<String, String> values = {};
  @override
  String? read(String key) => values[key];
  @override
  Future<void> write(String key, String? value) async {
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
  }
}

/// Magic metadata of a collection, as Ente keeps it (visibility/pinning/sort, cover, ...).
class CollectionMeta {
  const CollectionMeta({this.mmd, this.mv = 0, this.pub, this.pv = 0});
  final String? mmd;
  final int mv;
  final String? pub;
  final int pv;

  CollectionMeta mergedWith(CollectionMeta o) => CollectionMeta(
    mmd: o.mv > mv ? o.mmd : mmd,
    mv: o.mv > mv ? o.mv : mv,
    pub: o.pv > pv ? o.pub : pub,
    pv: o.pv > pv ? o.pv : pv,
  );

  Map<String, dynamic> toJson() => {
    if (mmd != null) 'm': mmd,
    if (mv != 0) 'mv': mv,
    if (pub != null) 'p': pub,
    if (pv != 0) 'pv': pv,
  };

  static CollectionMeta fromJson(Map<String, dynamic> j) => CollectionMeta(
    mmd: j['m'] as String?,
    mv: (j['mv'] as num?)?.toInt() ?? 0,
    pub: j['p'] as String?,
    pv: (j['pv'] as num?)?.toInt() ?? 0,
  );
}

/// An album that exists only in the app's state (no Filen folder behind it): user albums and the
/// favorites collection. A photo can be in any number of them.
class VirtualCollection {
  VirtualCollection({
    required this.uuid,
    required this.name,
    required this.type,
    required this.createdAt,
    required this.updatedAt,
    this.deleted = false,
    this.meta = const CollectionMeta(),
  });

  final String uuid;
  String name;

  /// `album` or `favorites` (`uncategorized` is the library root and never virtual).
  final String type;
  final int createdAt;
  int updatedAt;
  bool deleted;
  CollectionMeta meta;

  Map<String, dynamic> toJson() => {
    'name': name,
    'type': type,
    'created': createdAt,
    'updated': updatedAt,
    if (deleted) 'deleted': true,
    ...meta.toJson(),
  };

  static VirtualCollection fromJson(String uuid, Map<String, dynamic> j) =>
      VirtualCollection(
        uuid: uuid,
        name: j['name'] as String? ?? 'Album',
        type: j['type'] as String? ?? 'album',
        createdAt: (j['created'] as num?)?.toInt() ?? 0,
        updatedAt: (j['updated'] as num?)?.toInt() ?? 0,
        deleted: j['deleted'] == true,
        meta: CollectionMeta.fromJson(j),
      );
}

/// Collections and album membership on Filen.
///
/// Filen folders hold a file in exactly one place, Ente albums overlap. So there are two kinds of
/// collection: the real folders under the photo library, and virtual collections kept in
/// `collections/index`. Besides the folder a photo physically lives in, it can be a *member* of any
/// collection through `members/<collection uuid>` documents (this is how favorites work).
class FilenCollectionStore {
  FilenCollectionStore(
    this._docs,
    this._storage, {
    this.flushDelay = const Duration(seconds: 3),
    int Function()? clock,
  }) : _now = clock ?? (() => DateTime.now().microsecondsSinceEpoch) {
    _loadPending();
  }

  static const String indexDir = 'collections';
  static const String indexBase = 'index';
  static const String membersDir = 'members';
  static const String _pendingKey = 'filen_pending_members';
  static final _logger = Logger('FilenCollectionStore');

  final RevDocs _docs;
  final StringStorage _storage;
  final Duration flushDelay;
  final int Function() _now;

  final Map<String, VirtualCollection> _collections = {};
  final Map<String, CollectionMeta> _folderMeta = {};
  final Map<String, Set<String>> _members = {};
  String? _indexTag;
  final Map<String, String> _memberTags = {};

  /// Not yet written membership changes: collection -> (added, removed).
  final Map<String, ({Set<String> add, Set<String> remove})> _pending = {};
  Timer? _timer;
  Future<void> _flushing = Future.value();

  List<VirtualCollection> get virtualCollections => [
    for (final c in _collections.values)
      if (!c.deleted) c,
  ];

  VirtualCollection? virtualCollection(String uuid) => _collections[uuid];

  /// Metadata overlay of a physical folder (archive/hide/pin/cover...).
  CollectionMeta folderMeta(String folderUuid) =>
      _folderMeta[folderUuid] ?? const CollectionMeta();

  /// Files that were added to [collectionUuid] in addition to its own content.
  Set<String> membersOf(String collectionUuid) {
    final remote = _members[collectionUuid] ?? const <String>{};
    final p = _pending[collectionUuid];
    if (p == null) return remote;
    return {...remote, ...p.add}..removeAll(p.remove);
  }

  /// All collections that contain [fileUuid] through membership.
  Iterable<String> collectionsOfFile(String fileUuid) sync* {
    for (final id in {..._members.keys, ..._pending.keys}) {
      if (membersOf(id).contains(fileUuid)) yield id;
    }
  }

  /// Loads the index and every changed members document.
  Future<void> pull() async {
    final indexFiles = await _docs.store.list(indexDir);
    final rev = RevDocs.revisionsOf(indexBase, indexFiles);
    if (rev.isNotEmpty && rev.first.tag != _indexTag) {
      final doc = await _docs.read(indexDir, indexBase);
      if (doc != null) {
        _collections.clear();
        _folderMeta.clear();
        final cols = doc['collections'];
        if (cols is Map<String, dynamic>) {
          for (final e in cols.entries) {
            if (e.value is Map<String, dynamic>) {
              _collections[e.key] = VirtualCollection.fromJson(
                e.key,
                e.value as Map<String, dynamic>,
              );
            }
          }
        }
        final folders = doc['folders'];
        if (folders is Map<String, dynamic>) {
          for (final e in folders.entries) {
            if (e.value is Map<String, dynamic>) {
              _folderMeta[e.key] = CollectionMeta.fromJson(
                e.value as Map<String, dynamic>,
              );
            }
          }
        }
        _indexTag = rev.first.tag;
      }
    }
    final memberFiles = await _docs.store.list(membersDir);
    for (final base in RevDocs.basesOf(memberFiles)) {
      final latest = RevDocs.revisionsOf(base, memberFiles).first;
      if (_memberTags[base] == latest.tag) continue;
      final doc = await _docs.read(membersDir, base);
      if (doc == null) continue;
      final files = doc['files'];
      _members[base] = files is List
          ? {for (final f in files) f.toString()}
          : <String>{};
      _memberTags[base] = latest.tag;
    }
  }

  // ---- index (collections + folder metadata) ------------------------------------------------

  Future<VirtualCollection> create({
    required String uuid,
    required String name,
    required String type,
    CollectionMeta meta = const CollectionMeta(),
  }) async {
    final now = _now();
    final c = VirtualCollection(
      uuid: uuid,
      name: name,
      type: type,
      createdAt: now,
      updatedAt: now,
      meta: meta,
    );
    await _updateIndex((cols, _) => cols[uuid] = c);
    return c;
  }

  Future<void> rename(String uuid, String name) => _updateIndex((cols, _) {
    final c = cols[uuid];
    if (c == null) return;
    c.name = name;
    c.updatedAt = _now();
  });

  Future<void> delete(String uuid) => _updateIndex((cols, _) {
    final c = cols[uuid];
    if (c == null) return;
    c.deleted = true;
    c.updatedAt = _now();
  });

  /// Sets magic metadata of a virtual collection or, when [uuid] is a folder, of that folder.
  Future<void> updateMeta(String uuid, CollectionMeta meta) =>
      _updateIndex((cols, folders) {
        final c = cols[uuid];
        if (c != null) {
          c.meta = c.meta.mergedWith(meta);
          c.updatedAt = _now();
        } else {
          folders[uuid] = (folders[uuid] ?? const CollectionMeta()).mergedWith(
            meta,
          );
        }
      });

  Future<void> _updateIndex(
    void Function(
      Map<String, VirtualCollection> cols,
      Map<String, CollectionMeta> folders,
    )
    change,
  ) async {
    await _docs.update(indexDir, indexBase, (current) {
      final cols = <String, VirtualCollection>{};
      final folders = <String, CollectionMeta>{};
      final rawCols = current['collections'];
      if (rawCols is Map<String, dynamic>) {
        for (final e in rawCols.entries) {
          if (e.value is Map<String, dynamic>) {
            cols[e.key] = VirtualCollection.fromJson(
              e.key,
              e.value as Map<String, dynamic>,
            );
          }
        }
      }
      final rawFolders = current['folders'];
      if (rawFolders is Map<String, dynamic>) {
        for (final e in rawFolders.entries) {
          if (e.value is Map<String, dynamic>) {
            folders[e.key] = CollectionMeta.fromJson(
              e.value as Map<String, dynamic>,
            );
          }
        }
      }
      change(cols, folders);
      _collections
        ..clear()
        ..addAll(cols);
      _folderMeta
        ..clear()
        ..addAll(folders);
      return {
        'v': 1,
        'collections': {for (final e in cols.entries) e.key: e.value.toJson()},
        'folders': {for (final e in folders.entries) e.key: e.value.toJson()},
      };
    });
    _indexTag = null; // re-read on the next pull to learn the new revision tag
  }

  // ---- membership (write-behind) ------------------------------------------------------------

  void addMembers(String collectionUuid, Iterable<String> fileUuids) =>
      _queue(collectionUuid, add: fileUuids);

  void removeMembers(String collectionUuid, Iterable<String> fileUuids) =>
      _queue(collectionUuid, remove: fileUuids);

  void _queue(
    String collectionUuid, {
    Iterable<String> add = const [],
    Iterable<String> remove = const [],
  }) {
    final p = _pending[collectionUuid] ?? (add: <String>{}, remove: <String>{});
    for (final f in add) {
      p.remove.remove(f);
      p.add.add(f);
    }
    for (final f in remove) {
      p.add.remove(f);
      p.remove.add(f);
    }
    _pending[collectionUuid] = p;
    _persistPending();
    _timer?.cancel();
    _timer = Timer(flushDelay, () => unawaited(flush()));
  }

  bool get hasPending => _pending.isNotEmpty;

  Future<void> flush() {
    _timer?.cancel();
    return _flushing = _flushing.then((_) => _flushNow()).catchError((
      Object e,
      StackTrace s,
    ) {
      _logger.warning(
        'Could not write album membership to Filen, will retry',
        e,
        s,
      );
      _timer = Timer(flushDelay * 5, () => unawaited(flush()));
    });
  }

  Future<void> _flushNow() async {
    for (final id in _pending.keys.toList()) {
      final p = _pending[id]!;
      final add = Set<String>.of(p.add);
      final remove = Set<String>.of(p.remove);
      final written = await _docs.update(membersDir, id, (current) {
        final files =
            <String>{
                if (current['files'] is List)
                  for (final f in current['files'] as List) f.toString(),
              }
              ..addAll(add)
              ..removeAll(remove);
        return {'files': files.toList()..sort()};
      });
      final stored = <String>{
        if (written != null && written['files'] is List)
          for (final f in written['files'] as List) f.toString(),
      };
      _members[id] = stored;
      _memberTags.remove(id);
      // Drop what was written; anything queued meanwhile stays.
      final now = _pending[id];
      if (now != null) {
        now.add.removeAll(add);
        now.remove.removeAll(remove);
        if (now.add.isEmpty && now.remove.isEmpty) _pending.remove(id);
      }
      _persistPending();
    }
  }

  void _persistPending() {
    if (_pending.isEmpty) {
      unawaited(_storage.write(_pendingKey, null));
      return;
    }
    unawaited(
      _storage.write(
        _pendingKey,
        jsonEncode({
          for (final e in _pending.entries)
            e.key: {'a': e.value.add.toList(), 'r': e.value.remove.toList()},
        }),
      ),
    );
  }

  void _loadPending() {
    final raw = _storage.read(_pendingKey);
    if (raw == null) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return;
      for (final e in decoded.entries) {
        final v = e.value;
        if (v is! Map<String, dynamic>) continue;
        _pending[e.key] = (
          add: {for (final f in (v['a'] as List? ?? const [])) f.toString()},
          remove: {for (final f in (v['r'] as List? ?? const [])) f.toString()},
        );
      }
    } on FormatException {
      // A damaged journal is dropped; the next sync re-derives memberships from the cloud.
    }
  }
}
