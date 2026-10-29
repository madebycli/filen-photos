import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:photos/filen/state/blob_store.dart';
import 'package:photos/filen/state/collection_store.dart';
import 'package:photos/filen/state/entity_store.dart';
import 'package:photos/filen/state/meta_store.dart';
import 'package:photos/filen/state/ml_store.dart';
import 'package:photos/filen/state/rev_doc.dart';

const _uuidA = '3f2c1f6f-4e8f-4a7c-9a1e-5d3b7e9a0c11';
const _uuidB = '3f99aaaa-4e8f-4a7c-9a1e-5d3b7e9a0c22';
const _uuidC = 'a0000000-4e8f-4a7c-9a1e-5d3b7e9a0c33';

void main() {
  group('RevDocs', () {
    test('writes revisions, reads the newest and prunes old ones', () async {
      final store = MemoryBlobStore();
      final docs = RevDocs(store, writerId: 'devA');
      expect(await docs.read('d', 'doc'), isNull);
      await docs.write('d', 'doc', {'n': 1});
      await docs.write('d', 'doc', {'n': 2});
      await docs.write('d', 'doc', {'n': 3});
      expect((await docs.read('d', 'doc'))!['n'], 3);
      // keep = 2: only the two newest revisions remain.
      expect(store.names('d'), [
        'doc.r00000002-devA.json',
        'doc.r00000003-devA.json',
      ]);
    });

    test(
      'two devices writing the same revision never overwrite each other',
      () async {
        final store = MemoryBlobStore();
        final a = RevDocs(store, writerId: 'aaa');
        final b = RevDocs(store, writerId: 'bbb');
        final files = await store.list('d');
        await a.write('d', 'doc', {'from': 'a'}, knownFiles: files);
        await b.write('d', 'doc', {'from': 'b'}, knownFiles: files);
        expect(store.names('d'), hasLength(2));
        // Ties go to the larger writer id, deterministically on every device.
        expect((await a.read('d', 'doc'))!['from'], 'b');
        expect((await b.read('d', 'doc'))!['from'], 'b');
      },
    );

    test('documents with similar names are kept apart', () async {
      final store = MemoryBlobStore();
      final docs = RevDocs(store, writerId: 'x');
      await docs.write('d', 'a', {'v': 'a'});
      await docs.write('d', 'a.r1', {'v': 'tricky'});
      expect((await docs.read('d', 'a'))!['v'], 'a');
      expect((await docs.read('d', 'a.r1'))!['v'], 'tricky');
    });

    test('update skips the write when nothing changes', () async {
      final store = MemoryBlobStore();
      final docs = RevDocs(store, writerId: 'x');
      await docs.update('d', 'doc', (c) => {'n': 1});
      final writes = store.writeCalls;
      final result = await docs.update('d', 'doc', (c) => null);
      expect(result, isNull);
      expect(store.writeCalls, writes);
    });
  });

  group('FilenMetaStore', () {
    test('shards by the first two hex digits', () {
      expect(FilenMetaStore.shardOf(_uuidA), '3f');
      expect(FilenMetaStore.shardOf(_uuidC), 'a0');
    });

    test(
      'flush writes one document per shard and a second device sees it',
      () async {
        final store = MemoryBlobStore();
        final a = FilenMetaStore(
          RevDocs(store, writerId: 'a'),
          flushDelay: const Duration(hours: 1),
        );
        a.queue(_uuidA, const FileMetaEntry(mmd: '{"visibility":1}', mv: 1));
        a.queue(_uuidB, const FileMetaEntry(pub: '{"caption":"x"}', pv: 2));
        a.queue(_uuidC, const FileMetaEntry(mmd: '{"visibility":2}', mv: 1));
        await a.flush();
        expect(a.hasPending, isFalse);
        expect(store.names('meta').length, 2); // shards 3f (A+B) and a0 (C)

        final b = FilenMetaStore(RevDocs(store, writerId: 'b'));
        expect(b.remote(_uuidA), isNull);
        await b.pull();
        expect(b.remote(_uuidA)!.mmd, '{"visibility":1}');
        expect(b.remote(_uuidB)!.pub, '{"caption":"x"}');
        expect(b.remote(_uuidB)!.pv, 2);
        expect(b.remote(_uuidC)!.mv, 1);
      },
    );

    test('a pull without changes downloads nothing', () async {
      final store = MemoryBlobStore();
      final a = FilenMetaStore(RevDocs(store, writerId: 'a'));
      a.queue(_uuidA, const FileMetaEntry(mmd: '{}', mv: 1));
      await a.flush();
      final b = FilenMetaStore(RevDocs(store, writerId: 'b'));
      await b.pull();
      final reads = store.readCalls;
      await b.pull();
      expect(store.readCalls, reads);
    });

    test(
      'higher versions win per field and old data never overwrites new',
      () async {
        final store = MemoryBlobStore();
        final a = FilenMetaStore(RevDocs(store, writerId: 'a'));
        a.queue(_uuidA, const FileMetaEntry(mmd: '{"v":"new"}', mv: 5));
        await a.flush();
        final stale = FilenMetaStore(RevDocs(store, writerId: 'b'));
        stale.queue(
          _uuidA,
          const FileMetaEntry(mmd: '{"v":"old"}', mv: 3, pub: '{"c":1}', pv: 1),
        );
        await stale.flush();
        final reader = FilenMetaStore(RevDocs(store, writerId: 'c'));
        await reader.pull();
        final e = reader.remote(_uuidA)!;
        expect(e.mmd, '{"v":"new"}');
        expect(e.mv, 5);
        expect(e.pub, '{"c":1}'); // the other field still merged in
      },
    );

    test('only the shards of files that exist are read', () async {
      final store = MemoryBlobStore();
      final writer = FilenMetaStore(RevDocs(store, writerId: 'a'));
      writer.queue(_uuidA, const FileMetaEntry(mmd: '{}', mv: 1)); // shard 3f
      writer.queue(_uuidC, const FileMetaEntry(mmd: '{}', mv: 1)); // shard a0
      await writer.flush();

      final reader = FilenMetaStore(RevDocs(store, writerId: 'b'));
      await reader.pull(onlyShards: {'a0'});
      expect(reader.remote(_uuidC), isNotNull);
      expect(reader.remote(_uuidA), isNull);
      expect(store.readCalls, 1);

      // An empty library needs no shard at all.
      final nothing = FilenMetaStore(RevDocs(store, writerId: 'c'));
      final reads = store.readCalls;
      await nothing.pull(onlyShards: {});
      expect(store.readCalls, reads);
    });

    test('a restart with the disk cache reads only what changed', () async {
      final store = MemoryBlobStore();
      final cache = _MemoryMetaCache();
      final first = FilenMetaStore(RevDocs(store, writerId: 'a'), cache: cache);
      first.queue(_uuidA, const FileMetaEntry(mmd: '{"a":1}', mv: 1));
      first.queue(_uuidC, const FileMetaEntry(mmd: '{"c":1}', mv: 1));
      await first.flush();
      await first.pull();

      // The app starts again: nothing in memory, the cache on disk.
      final reads = store.readCalls;
      final second = FilenMetaStore(
        RevDocs(store, writerId: 'a'),
        cache: cache,
      );
      await second.pull();
      expect(store.readCalls, reads, reason: 'nothing changed in the cloud');
      expect(second.remote(_uuidA)!.mmd, '{"a":1}');
      expect(second.remote(_uuidC)!.mmd, '{"c":1}');

      // Another device changes one shard: only that one is read again.
      final other = FilenMetaStore(RevDocs(store, writerId: 'b'));
      other.queue(_uuidA, const FileMetaEntry(mmd: '{"a":2}', mv: 2));
      await other.flush();
      final before = store.readCalls;
      final third = FilenMetaStore(RevDocs(store, writerId: 'a'), cache: cache);
      await third.pull();
      expect(store.readCalls - before, 1);
      expect(third.remote(_uuidA)!.mmd, '{"a":2}');
      expect(third.remote(_uuidC)!.mmd, '{"c":1}');
    });

    test('a broken cache is ignored and everything is read', () async {
      final store = MemoryBlobStore();
      final writer = FilenMetaStore(RevDocs(store, writerId: 'a'));
      writer.queue(_uuidA, const FileMetaEntry(mmd: '{}', mv: 1));
      await writer.flush();
      final reader = FilenMetaStore(
        RevDocs(store, writerId: 'b'),
        cache: _MemoryMetaCache(broken: true),
      );
      await reader.pull();
      expect(reader.remote(_uuidA), isNotNull);
    });

    test('entries the cloud already has are not written again', () async {
      final store = MemoryBlobStore();
      final a = FilenMetaStore(RevDocs(store, writerId: 'a'));
      a.queue(_uuidA, const FileMetaEntry(mmd: '{}', mv: 1));
      await a.flush();
      final writes = store.writeCalls;
      a.queue(_uuidA, const FileMetaEntry(mmd: '{}', mv: 1));
      expect(a.hasPending, isFalse);
      await a.flush();
      expect(store.writeCalls, writes);
    });
  });

  group('FilenEntityStore', () {
    FilenEntityStore make(MemoryBlobStore s, String w) =>
        FilenEntityStore(RevDocs(s, writerId: w), ownerID: () => 7);

    test('put, update and diff by time', () async {
      final store = MemoryBlobStore();
      final e = make(store, 'a');
      final first = await e.put('cgroup', 'p1', '{"name":"Anna"}');
      expect(first.updatedAt, greaterThan(0));
      final second = await e.put('cgroup', 'p2', '{"name":"Ben"}');
      final all = await e.diff('cgroup', 0);
      expect(all.map((r) => r.id), ['p1', 'p2']);
      expect(all.first.data, '{"name":"Anna"}');
      expect(all.first.ownerID, 7);

      // Only changes after a timestamp.
      final later = await e.diff('cgroup', first.updatedAt);
      expect(later.map((r) => r.id), ['p2']);
      await e.put('cgroup', 'p1', '{"name":"Anna B"}');
      final changed = await e.diff('cgroup', second.updatedAt);
      expect(changed.single.data, '{"name":"Anna B"}');
    });

    test('deleting leaves a tombstone other devices can sync', () async {
      final store = MemoryBlobStore();
      final e = make(store, 'a');
      await e.put('location', 'l1', '{"n":1}');
      final before = (await e.diff('location', 0)).single.updatedAt;
      await e.delete('location', 'l1');
      final diff = await e.diff('location', before);
      expect(diff.single.isDeleted, isTrue);
      expect(diff.single.data, isEmpty);
    });

    test('types are separate and ids with odd characters work', () async {
      final store = MemoryBlobStore();
      final e = make(store, 'a');
      await e.put('cgroup', 'we/ird id', '{}');
      await e.put('location', 'we/ird id', '{}');
      expect((await e.diff('cgroup', 0)).single.id, 'we/ird id');
      expect(await e.typeOf('we/ird id', ['location', 'cgroup']), 'location');
      expect(await e.typeOf('missing', ['location', 'cgroup']), isNull);
    });

    test('limit returns the oldest changes first', () async {
      final store = MemoryBlobStore();
      final e = make(store, 'a');
      for (var i = 0; i < 5; i++) {
        await e.put('cgroup', 'p$i', '{}');
      }
      final page = await e.diff('cgroup', 0, limit: 2);
      expect(page.map((r) => r.id), ['p0', 'p1']);
    });
  });

  group('FilenMlStore', () {
    test('put, refresh on another device, get', () async {
      final store = MemoryBlobStore();
      final a = FilenMlStore(store);
      await a.put(_uuidA, 'mldata', 1, {
        'face': {'faces': [], 'version': 1},
        'clip': {
          'version': 1,
          'client': 'x',
          'embedding': [0.5, 0.25],
        },
      });
      final b = FilenMlStore(store);
      expect(b.has(_uuidA, 'mldata'), isFalse); // not indexed yet
      await b.refresh();
      expect(b.isIndexed, isTrue);
      expect(b.has(_uuidA, 'mldata'), isTrue);
      expect(b.has(_uuidB, 'mldata'), isFalse);
      final data = await b.get(_uuidA, 'mldata');
      expect((data!['clip'] as Map)['embedding'], [0.5, 0.25]);
    });

    test(
      'the highest compatible version is used and a repeat put is free',
      () async {
        final store = MemoryBlobStore();
        final a = FilenMlStore(store);
        await a.put(_uuidA, 'mldata', 1, {'v': 1});
        await a.put(_uuidA, 'mldata', 2, {'v': 2});
        final writes = store.writeCalls;
        await a.put(_uuidA, 'mldata', 2, {'v': 2});
        expect(store.writeCalls, writes);
        expect((await a.get(_uuidA, 'mldata'))!['v'], 2);
        expect((await a.get(_uuidA, 'mldata', maxVersion: 1))!['v'], 1);
      },
    );

    test('damaged data reads as missing instead of throwing', () async {
      final store = MemoryBlobStore();
      await store.write(
        'ml/3f',
        '$_uuidA.mldata.v1.json.gz',
        Uint8List.fromList(utf8.encode('not gzip')),
      );
      final ml = FilenMlStore(store);
      await ml.refresh();
      expect(await ml.get(_uuidA, 'mldata'), isNull);
    });
  });

  group('FilenCollectionStore', () {
    FilenCollectionStore make(
      MemoryBlobStore s,
      String w,
      MapStringStorage kv, {
      int Function()? clock,
    }) => FilenCollectionStore(
      RevDocs(s, writerId: w),
      kv,
      flushDelay: const Duration(hours: 1),
      clock: clock,
    );

    test('virtual collections round trip between devices', () async {
      final store = MemoryBlobStore();
      var t = 100;
      final a = make(store, 'a', MapStringStorage(), clock: () => t++);
      await a.create(uuid: 'fav-1', name: 'Favorites', type: 'favorites');
      await a.create(uuid: 'alb-1', name: 'Holiday', type: 'album');
      await a.rename('alb-1', 'Holiday 2026');

      final b = make(store, 'b', MapStringStorage());
      await b.pull();
      expect(
        b.virtualCollections.map((c) => c.name),
        unorderedEquals(['Favorites', 'Holiday 2026']),
      );
      expect(b.virtualCollection('fav-1')!.type, 'favorites');

      await a.delete('alb-1');
      await b.pull();
      expect(b.virtualCollections.map((c) => c.name), ['Favorites']);
    });

    test(
      'membership is write-behind, visible at once and shared after flush',
      () async {
        final store = MemoryBlobStore();
        final kv = MapStringStorage();
        final a = make(store, 'a', kv);
        a.addMembers('fav-1', [_uuidA, _uuidB]);
        expect(a.membersOf('fav-1'), {_uuidA, _uuidB});
        expect(a.hasPending, isTrue);
        expect(store.names('members'), isEmpty);

        await a.flush();
        expect(a.hasPending, isFalse);
        expect(kv.values, isEmpty);

        a.removeMembers('fav-1', [_uuidA]);
        expect(a.membersOf('fav-1'), {_uuidB});
        await a.flush();

        final b = make(store, 'b', MapStringStorage());
        await b.pull();
        expect(b.membersOf('fav-1'), {_uuidB});
        expect(b.collectionsOfFile(_uuidB), ['fav-1']);
        expect(b.collectionsOfFile(_uuidA), isEmpty);
      },
    );

    test('pending changes survive a restart and are written later', () async {
      final store = MemoryBlobStore();
      final kv = MapStringStorage();
      final a = make(store, 'a', kv);
      a.addMembers('fav-1', [_uuidA]);
      await Future<void>.delayed(Duration.zero);
      expect(kv.values['filen_pending_members'], isNotNull);

      // "App killed": a new instance restores the journal from storage.
      final restarted = make(store, 'a', kv);
      expect(restarted.membersOf('fav-1'), {_uuidA});
      await restarted.flush();
      final other = make(store, 'b', MapStringStorage());
      await other.pull();
      expect(other.membersOf('fav-1'), {_uuidA});
    });

    test('folder metadata overlays live next to virtual collections', () async {
      final store = MemoryBlobStore();
      final a = make(store, 'a', MapStringStorage());
      await a.updateMeta(
        'folder-uuid',
        const CollectionMeta(mmd: '{"visibility":1}', mv: 1),
      );
      await a.updateMeta(
        'folder-uuid',
        const CollectionMeta(mmd: '{"visibility":0}', mv: 0),
      ); // older: ignored
      final b = make(store, 'b', MapStringStorage());
      await b.pull();
      expect(b.folderMeta('folder-uuid').mmd, '{"visibility":1}');
      expect(b.folderMeta('other').mv, 0);
    });

    test('a damaged journal is ignored', () {
      final kv = MapStringStorage()
        ..values['filen_pending_members'] = '{broken';
      final c = make(MemoryBlobStore(), 'a', kv);
      expect(c.hasPending, isFalse);
    });
  });
}

class _MemoryMetaCache implements MetaCache {
  _MemoryMetaCache({this.broken = false});
  final bool broken;
  MetaSnapshot? _snapshot;

  @override
  Future<MetaSnapshot?> load() async {
    if (broken) throw const FormatException('damaged');
    return _snapshot;
  }

  @override
  Future<void> save(MetaSnapshot snapshot) async => _snapshot = snapshot;

  @override
  Future<void> clear() async => _snapshot = null;
}
