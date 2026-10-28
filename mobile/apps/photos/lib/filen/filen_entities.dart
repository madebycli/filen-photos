import 'dart:math';

import 'package:logging/logging.dart';
import 'package:photos/db/entities_db.dart';
import 'package:photos/db/files_db.dart';
import 'package:photos/filen/filen_state.dart';
import 'package:photos/gateways/entity/models/type.dart';
import 'package:photos/models/local_entity_data.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

/// Ente's "user entities" (people, saved places, smart albums, memories) on Filen. They are stored
/// as plain JSON in the end-to-end encrypted state folder instead of being encrypted for Ente's
/// server, see `state/entity_store.dart`.
class FilenEntities {
  FilenEntities._();

  static final _logger = Logger('FilenEntities');
  static const _pageSize = 500;

  static String _syncKey(EntityType type) =>
      'entity_last_sync_time_${type.name}';

  /// Creates or replaces an entity; returns what Ente's database should hold.
  static Future<LocalEntityData> put(
    EntityType type,
    String? id,
    String plainText,
    int ownerID,
  ) async {
    final state = FilenState.instance;
    await state.ensureInitialized();
    final record = await state.entities.put(
      type.name,
      id ?? const Uuid().v4(),
      plainText,
    );
    return LocalEntityData(
      id: record.id,
      type: type,
      data: plainText,
      ownerID: ownerID,
      updatedAt: record.updatedAt,
    );
  }

  /// Writes a tombstone for [id] in whichever type folder holds it.
  static Future<void> delete(String id) async {
    final state = FilenState.instance;
    await state.ensureInitialized();
    final type = await state.entities.typeOf(id, [
      for (final t in EntityType.values)
        if (t != EntityType.unknown) t.name,
    ]);
    if (type == null) {
      _logger.info(
        'Entity $id not found in the cloud state, nothing to delete',
      );
      return;
    }
    await state.entities.delete(type, id);
  }

  /// Applies everything that changed in the cloud state since the last pull. Returns the number of
  /// entities seen.
  static Future<int> pull(
    EntityType type,
    SharedPreferences prefs,
    FilesDB db,
  ) async {
    final state = FilenState.instance;
    await state.ensureInitialized();
    var since = prefs.getInt(_syncKey(type)) ?? 0;
    var seen = 0;
    while (true) {
      final batch = await state.entities.diff(
        type.name,
        since,
        limit: _pageSize,
      );
      if (batch.isEmpty) break;
      final gone = [
        for (final r in batch)
          if (r.isDeleted) r.id,
      ];
      if (gone.isNotEmpty) await db.deleteEntities(gone);
      final live = [
        for (final r in batch)
          if (!r.isDeleted)
            LocalEntityData(
              id: r.id,
              type: type,
              data: r.data,
              ownerID: r.ownerID,
              updatedAt: r.updatedAt,
            ),
      ];
      if (live.isNotEmpty) await db.upsertEntities(live);
      since = batch.map((r) => r.updatedAt).reduce(max);
      await prefs.setInt(_syncKey(type), since);
      seen += batch.length;
      if (batch.length < _pageSize) break;
    }
    if (seen > 0) _logger.info('$seen ${type.name} entities pulled from Filen');
    return seen;
  }
}
