import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:photos/filen/state/meta_store.dart';

/// The metadata cache as one JSON file in the app's private folder. It belongs to one library
/// folder on Filen; another account's file is ignored and replaced.
class MetaDiskCache implements MetaCache {
  MetaDiskCache(this.libraryUuid, {Directory? directory})
    : _directory = directory;

  final String libraryUuid;
  final Directory? _directory;

  Future<File> _file() async {
    final dir = _directory ?? await getApplicationSupportDirectory();
    return File('${dir.path}/filen_meta_cache.json');
  }

  @override
  Future<MetaSnapshot?> load() async {
    final file = await _file();
    if (!await file.exists()) return null;
    final json = jsonDecode(await file.readAsString());
    if (json is! Map<String, dynamic> || json['library'] != libraryUuid) {
      return null;
    }
    final tags = <String, String>{
      for (final e in (json['tags'] as Map<String, dynamic>).entries)
        e.key: e.value as String,
    };
    final entries = <String, FileMetaEntry>{
      for (final e in (json['entries'] as Map<String, dynamic>).entries)
        e.key: FileMetaEntry.fromJson(e.value as Map<String, dynamic>),
    };
    return MetaSnapshot(tags, entries);
  }

  @override
  Future<void> save(MetaSnapshot snapshot) async {
    final file = await _file();
    final temp = File('${file.path}.tmp');
    await temp.writeAsString(
      jsonEncode({
        'library': libraryUuid,
        'tags': snapshot.tags,
        'entries': {
          for (final e in snapshot.entries.entries) e.key: e.value.toJson(),
        },
      }),
      flush: true,
    );
    await temp.rename(file.path);
  }

  @override
  Future<void> clear() async {
    final file = await _file();
    if (await file.exists()) await file.delete();
  }
}
