import 'dart:convert';

import 'package:logging/logging.dart';
import 'package:photos/filen/filen_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Which app settings travel with the account. Only choices about how the gallery looks and
/// behaves; anything tied to this device (app mode, debug switches, "seen" hints, upload folders)
/// stays out on purpose.
const List<String> kFilenSyncedSettings = [
  'collection_sort_pref',
  'collection_sort_direction',
  'collection_view_type',
  'gallery_group_type',
  'gallery_layout_type',
  'photo_grid_size',
  'people_sort_key',
  'people_sort_name_ascending',
  'people_sort_updated_ascending',
  'people_sort_photos_ascending',
  'people_sort_similarity_selected',
  'ls.curated_memories_enabled',
  'ls.on_this_day_notifications_enabled',
  'ls.birthday_notifications_enabled',
  'ls.pet_recognition_enabled',
  'video.should_loop',
  'video.is_muted',
  'memories.audio_muted',
  'memories.video_muted',
  'album_slideshow.duration_seconds',
  'album_slideshow.blurred_background',
  'album_slideshow.random_order',
  'delete_preference',
  'should_backup_over_mobile_data',
  'should_backup_videos',
  'filen.compress_uploads',
  'filen.upload_on_low_battery',
  'filen.reupload_deleted',
  'filen.ml_consent',
  'ml_debug.run_ml_during_interaction',
  'filen.map_enabled',
  'filen.accent_color',
];

/// One setting as stored in the cloud document: a type tag plus the value, canonical JSON so two
/// devices compare equal values as equal strings.
String encodeSetting(Object value) {
  final String t;
  if (value is bool) {
    t = 'b';
  } else if (value is int) {
    t = 'i';
  } else if (value is double) {
    t = 'd';
  } else if (value is List) {
    t = 'l';
  } else {
    t = 's';
  }
  return jsonEncode({'t': t, 'v': value});
}

Object? decodeSetting(String encoded) {
  final m = jsonDecode(encoded);
  if (m is! Map) return null;
  final v = m['v'];
  switch (m['t']) {
    case 'b':
      return v is bool ? v : null;
    case 'i':
      return v is int ? v : null;
    case 'd':
      return v is num ? v.toDouble() : null;
    case 'l':
      return v is List ? v.map((e) => e.toString()).toList() : null;
    case 's':
      return v is String ? v : null;
  }
  return null;
}

class SettingsMerge {
  SettingsMerge({
    required this.applyLocally,
    required this.pushToCloud,
    required this.snapshot,
  });

  /// Cloud values that replace the local ones.
  final Map<String, String> applyLocally;

  /// Local values the cloud should get.
  final Map<String, String> pushToCloud;

  /// What both sides agree on after this merge; the base for the next one.
  final Map<String, String> snapshot;
}

/// Three-way merge of the settings. [local] and [remote] hold encoded values by key, [snapshot] the
/// agreed state of the last merge (null before the first one).
///
///  * First merge on this device: a value that exists in the cloud wins (a new phone gets the old
///    phone's choices); local-only values are pushed.
///  * Later: a value changed on this device since the last merge is pushed, otherwise a different
///    cloud value is applied. A setting is never deleted by a merge.
SettingsMerge mergeSettings({
  required Map<String, String> local,
  required Map<String, String> remote,
  required Map<String, String>? snapshot,
  required Iterable<String> keys,
}) {
  final apply = <String, String>{};
  final push = <String, String>{};
  final agreed = <String, String>{};
  for (final key in keys) {
    final l = local[key];
    final r = remote[key];
    final s = snapshot?[key];
    String? result;
    if (snapshot == null) {
      if (r != null) {
        result = r;
        if (l != r) apply[key] = r;
      } else if (l != null) {
        result = l;
        push[key] = l;
      }
    } else {
      final localChanged = l != null && l != s;
      if (localChanged) {
        result = l;
        if (r != l) push[key] = l;
      } else if (r != null) {
        result = r;
        if (l != r) apply[key] = r;
      } else if (l != null) {
        // Present locally from the start but never uploaded.
        result = l;
        push[key] = l;
      }
    }
    if (result != null) agreed[key] = result;
  }
  return SettingsMerge(
    applyLocally: apply,
    pushToCloud: push,
    snapshot: agreed,
  );
}

/// Backs the whitelisted settings up to the Filen state folder (`settings/prefs`) and restores
/// them on a new device.
class FilenSettingsSync {
  FilenSettingsSync._();

  static final _logger = Logger('FilenSettings');
  static const _dir = 'settings';
  static const _base = 'prefs';
  static const _snapshotKey = 'filen_settings_snapshot';

  static Future<void> sync() async {
    final state = FilenState.instance;
    await state.ensureInitialized();
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();

    final local = <String, String>{};
    for (final key in kFilenSyncedSettings) {
      final value = prefs.get(key);
      if (value != null) local[key] = encodeSetting(value);
    }
    Map<String, String>? snapshot;
    final stored = prefs.getString(_snapshotKey);
    if (stored != null) {
      try {
        snapshot = Map<String, String>.from(jsonDecode(stored) as Map);
      } catch (_) {
        snapshot = null;
      }
    }

    SettingsMerge? merged;
    final now = DateTime.now().millisecondsSinceEpoch;
    await state.docs.update(_dir, _base, (current) {
      final remote = <String, String>{};
      final values = current['values'];
      if (values is Map) {
        for (final e in values.entries) {
          final v = e.value;
          if (e.key is String && v is String) remote[e.key as String] = v;
        }
      }
      merged = mergeSettings(
        local: local,
        remote: remote,
        snapshot: snapshot,
        keys: kFilenSyncedSettings,
      );
      if (merged!.pushToCloud.isEmpty) return null;
      return {
        'v': 1,
        't': now,
        'values': {...remote, ...merged!.pushToCloud},
      };
    });
    final result = merged;
    if (result == null) return;

    for (final entry in result.applyLocally.entries) {
      final value = decodeSetting(entry.value);
      switch (value) {
        case final bool b:
          await prefs.setBool(entry.key, b);
        case final int i:
          await prefs.setInt(entry.key, i);
        case final double d:
          await prefs.setDouble(entry.key, d);
        case final String s:
          await prefs.setString(entry.key, s);
        case final List<String> l:
          await prefs.setStringList(entry.key, l);
        default:
          _logger.warning('Ignoring setting ${entry.key} of unknown type');
      }
    }
    await prefs.setString(_snapshotKey, jsonEncode(result.snapshot));
    if (result.applyLocally.isNotEmpty || result.pushToCloud.isNotEmpty) {
      _logger.info(
        'Settings synced: ${result.applyLocally.length} restored, '
        '${result.pushToCloud.length} saved',
      );
    }
  }

  /// Logout: the next account starts with a first merge.
  static Future<void> reset() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_snapshotKey);
  }
}
