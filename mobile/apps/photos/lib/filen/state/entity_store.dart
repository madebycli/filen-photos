import 'dart:convert';
import 'dart:typed_data';

import 'package:photos/filen/state/rev_doc.dart';

/// One entity of Ente's "user entity" service (people/face groups, saved location tags, smart
/// album rules, memories...), as stored in the state folder. The payload is Ente's own plain JSON;
/// Filen already encrypts the whole file end to end, so no second layer is added.
class EntityRecord {
  const EntityRecord({
    required this.id,
    required this.data,
    required this.updatedAt,
    required this.ownerID,
    this.isDeleted = false,
  });

  final String id;

  /// Ente's JSON for this entity, as a string. Empty for deleted entities.
  final String data;

  /// Microseconds since epoch, taken from Filen's own file timestamp so every device sees the
  /// same value and "changes since" queries are consistent.
  final int updatedAt;
  final int ownerID;
  final bool isDeleted;
}

/// Entities of one type live in `entities/<type>/` as revisioned documents named after the entity.
class FilenEntityStore {
  FilenEntityStore(this._docs, {required this.ownerID});

  final RevDocs _docs;
  final int Function() ownerID;

  static String dirFor(String type) => 'entities/$type';

  static String baseFor(String id) => Uri.encodeComponent(id);

  /// Entities of [type] changed after [sinceMicros], oldest first, at most [limit].
  Future<List<EntityRecord>> diff(
    String type,
    int sinceMicros, {
    int limit = 500,
  }) async {
    final files = await _docs.store.list(dirFor(type));
    final changed = <({String base, DocRevision rev})>[];
    for (final base in RevDocs.basesOf(files)) {
      final rev = RevDocs.revisionsOf(base, files).first;
      if (rev.file.modifiedMs * 1000 > sinceMicros) {
        changed.add((base: base, rev: rev));
      }
    }
    changed.sort(
      (a, b) => a.rev.file.modifiedMs.compareTo(b.rev.file.modifiedMs),
    );
    final records = <EntityRecord>[];
    for (final c in changed.take(limit)) {
      final doc = jsonDecode(
        utf8.decode(await _docs.store.readById(c.rev.file.id)),
      );
      if (doc is! Map<String, dynamic>) continue;
      records.add(
        EntityRecord(
          id: doc['id'] as String? ?? Uri.decodeComponent(c.base),
          data: (doc['data'] as String?) ?? '',
          updatedAt: c.rev.file.modifiedMs * 1000,
          ownerID: (doc['owner'] as num?)?.toInt() ?? ownerID(),
          isDeleted: doc['deleted'] == true,
        ),
      );
    }
    return records;
  }

  /// Creates or replaces entity [id].
  Future<EntityRecord> put(String type, String id, String data) async {
    final rev = await _docs.write(dirFor(type), baseFor(id), {
      'id': id,
      'data': data,
      'owner': ownerID(),
    });
    return EntityRecord(
      id: id,
      data: data,
      updatedAt: rev.file.modifiedMs * 1000,
      ownerID: ownerID(),
    );
  }

  /// Writes a tombstone so other devices drop the entity too.
  Future<void> delete(String type, String id) async {
    await _docs.write(dirFor(type), baseFor(id), {
      'id': id,
      'deleted': true,
      'owner': ownerID(),
    });
  }

  /// Finds which type directory holds [id] (Ente's delete call carries no type).
  Future<String?> typeOf(String id, Iterable<String> types) async {
    for (final t in types) {
      final files = await _docs.store.list(dirFor(t));
      if (RevDocs.revisionsOf(baseFor(id), files).isNotEmpty) return t;
    }
    return null;
  }
}

/// Convenience for tests.
Uint8List utf8Bytes(String s) => Uint8List.fromList(utf8.encode(s));
