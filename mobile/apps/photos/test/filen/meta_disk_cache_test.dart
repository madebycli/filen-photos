import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:photos/filen/state/meta_disk_cache.dart';
import 'package:photos/filen/state/meta_store.dart';

void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('meta-cache'));
  tearDown(() => dir.deleteSync(recursive: true));

  const snapshot = MetaSnapshot(
    {'3f': '3f@2-a'},
    {
      '3f2c': FileMetaEntry(mmd: '{"v":1}', mv: 1, base: {'h': 'x'}),
    },
  );

  test('what is saved comes back, for the same library', () async {
    final cache = MetaDiskCache('lib-1', directory: dir);
    expect(await cache.load(), isNull);
    await cache.save(snapshot);
    final loaded = (await MetaDiskCache('lib-1', directory: dir).load())!;
    expect(loaded.tags, snapshot.tags);
    expect(loaded.entries['3f2c'], snapshot.entries['3f2c']);
  });

  test('another library or account never sees it', () async {
    await MetaDiskCache('lib-1', directory: dir).save(snapshot);
    expect(await MetaDiskCache('lib-2', directory: dir).load(), isNull);
  });

  test('clear removes the file', () async {
    final cache = MetaDiskCache('lib-1', directory: dir);
    await cache.save(snapshot);
    await cache.clear();
    expect(await cache.load(), isNull);
  });
}
