import 'dart:async';
import 'dart:convert';

import "package:crypto/crypto.dart";
import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';
import "package:photos/core/configuration.dart";
import "package:photos/db/entities_db.dart";
import "package:photos/db/files_db.dart";
import "package:photos/filen/filen_entities.dart";
import "package:photos/gateways/entity/models/type.dart";
import "package:photos/models/local_entity_data.dart";
import 'package:shared_preferences/shared_preferences.dart';

/// People, saved places, smart albums and other small records that belong to the user rather
/// than to a photo. They are kept in the local database and mirrored to the app's state folder on
/// Filen (see `FilenEntities`), so a new device or a reinstall gets them back.
class EntityService {
  final _logger = Logger((EntityService).toString());
  final SharedPreferences _prefs;
  final _config = Configuration.instance;
  late final FilesDB _db = FilesDB.instance;

  EntityService(this._prefs) {
    debugPrint("EntityService constructor");
  }

  String _getEntityLastSyncTimePrefix(EntityType type) {
    return "entity_last_sync_time_" + type.name;
  }

  Future<List<LocalEntityData>> getCertainEntities(
    EntityType type,
    List<String> ids,
  ) async {
    return await _db.getCertainEntities(type, ids);
  }

  Future<List<LocalEntityData>> getEntities(EntityType type) async {
    return await _db.getEntities(type);
  }

  Future<LocalEntityData?> getEntity(EntityType type, String id) async {
    return await _db.getEntity(type, id);
  }

  Future<LocalEntityData> addOrUpdate(
    EntityType type,
    Map<String, dynamic> jsonMap, {
    String? id,
    bool addWithCustomID = false,
    int? expectedUpdatedAt,
  }) async {
    final localData = await FilenEntities.put(
      type,
      id,
      jsonEncode(jsonMap),
      _config.getUserID() ?? 0,
    );
    await _db.upsertEntities([localData]);
    syncEntities().ignore();
    return localData;
  }

  Future<void> deleteEntry(String id) async {
    await FilenEntities.delete(id);
    await _db.deleteEntities([id]);
  }

  Future<void> syncEntities() async {
    try {
      await syncEntity(EntityType.location);
      await syncEntity(EntityType.cgroup);
      await syncEntity(EntityType.smartAlbum);
    } catch (e) {
      _logger.severe("Failed to sync entities", e);
    }
  }

  /// Pulls changes of [type] from Filen; returns how many records were seen, or -1 on failure.
  Future<int> syncEntity(EntityType type) async {
    try {
      return await FilenEntities.pull(type, _prefs, _db);
    } catch (e) {
      _logger.severe("Failed to sync entities", e);
      return -1;
    }
  }

  int lastSyncTime(EntityType type) {
    return _prefs.getInt(_getEntityLastSyncTimePrefix(type)) ?? 0;
  }

  Future<String?> getPreHashForEntities(
    EntityType type,
    List<String> ids,
  ) async {
    return await _db.getPreHashForEntities(type, ids);
  }

  Future<String> getHashForIds(List<String> personIds) async {
    final preHash = await getPreHashForEntities(EntityType.cgroup, personIds);

    if (preHash == null) {
      return "";
    }

    final hash = md5.convert(utf8.encode(preHash)).toString().substring(0, 10);
    return hash;
  }

  Future<Map<String, int>> getUpdatedAts(
    EntityType type,
    List<String> personIds,
  ) async {
    return await _db.getUpdatedAts(type, personIds);
  }
}
