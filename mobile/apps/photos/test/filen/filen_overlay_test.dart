import 'package:filen_sdk/filen_sdk.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photos/filen/filen_media_mapper.dart';
import 'package:photos/filen/filen_meta_overlay.dart';
import 'package:photos/filen/filen_ml.dart';
import 'package:photos/filen/filen_sync.dart';
import 'package:photos/filen/state/blob_store.dart';
import 'package:photos/filen/state/collection_store.dart';
import 'package:photos/filen/state/meta_store.dart';
import 'package:photos/models/api/collection/user.dart';
import 'package:photos/models/collection/collection.dart';
import 'package:photos/models/file/file.dart';
import 'package:photos/models/file/file_type.dart';
import 'package:photos/models/location/location.dart';

const _uuid = '2c1f6f4e-8f0a-4c7d-9a1e-5d3b7e9a0c11';
const _root = '11111111-2222-4333-8444-555555555555';
const _dirA = 'aaaaaaaa-2222-4333-8444-555555555555';
const _dirB = 'bbbbbbbb-2222-4333-8444-555555555555';
const _dirC = 'cccccccc-2222-4333-8444-555555555555';

EnteFile _row({
  String? hash,
  int? duration,
  Location? location,
  String? deviceFolder,
  String? localID,
}) => EnteFile()
  ..uploadedFileID = 7
  ..collectionID = 1
  ..title = 'a.jpg'
  ..fileType = FileType.image
  ..fileSize = 10
  ..creationTime = 1000
  ..modificationTime = 2000
  ..updationTime = 3000
  ..hash = hash
  ..duration = duration
  ..location = location
  ..deviceFolder = deviceFolder
  ..localID = localID
  ..encryptedKey = _uuid;

void main() {
  group('FileMetaEntry', () {
    test('an entry with only base values is not empty', () {
      expect(const FileMetaEntry().isEmpty, isTrue);
      expect(const FileMetaEntry(base: {'h': 'x'}).isEmpty, isFalse);
      expect(const FileMetaEntry(base: {}).isEmpty, isTrue);
    });

    test('base values are written once: existing keys win, others add', () {
      const a = FileMetaEntry(base: {'h': 'mine', 'd': 5});
      const b = FileMetaEntry(base: {'h': 'theirs', 'la': 1.5});
      final merged = a.mergedWith(b);
      expect(merged.base, {'h': 'mine', 'd': 5, 'la': 1.5});
    });

    test('magic metadata versions still decide per field', () {
      const a = FileMetaEntry(mmd: '{"a":1}', mv: 2, pub: '{"p":1}', pv: 1);
      const b = FileMetaEntry(mmd: '{"a":2}', mv: 1, pub: '{"p":2}', pv: 3);
      final m = a.mergedWith(b);
      expect((m.mmd, m.mv, m.pub, m.pv), ('{"a":1}', 2, '{"p":2}', 3));
    });

    test('equality compares base by content', () {
      expect(
        const FileMetaEntry(base: {'h': 'x'}),
        const FileMetaEntry(base: {'h': 'x'}),
      );
      expect(
        const FileMetaEntry(base: {'h': 'x'}) ==
            const FileMetaEntry(base: {'h': 'y'}),
        isFalse,
      );
    });

    test('json round trip keeps base', () {
      const e = FileMetaEntry(mmd: '{}', mv: 1, base: {'la': 1.0, 'lo': 2.0});
      expect(FileMetaEntry.fromJson(e.toJson()), e);
    });
  });

  group('base metadata of a file row', () {
    test('only meaningful values are recorded', () {
      expect(baseMetaOf(_row()), isNull);
      expect(
        baseMetaOf(
          _row(
            duration: 0,
            location: const Location(latitude: 0, longitude: 0),
          ),
        ),
        isNull,
      );
      final base = baseMetaOf(
        _row(
          hash: 'h1',
          duration: 12,
          location: const Location(latitude: 48.1, longitude: 11.5),
          deviceFolder: 'Camera',
          localID: 'abc',
        ),
      )!;
      expect(base, {
        'lid': 'abc',
        'df': 'Camera',
        'h': 'h1',
        'la': 48.1,
        'lo': 11.5,
        'd': 12,
      });
    });

    test('applying fills only what the row lacks', () {
      final f = _row(hash: 'keep');
      applyMetaEntry(
        f,
        const FileMetaEntry(
          base: {'h': 'other', 'd': 9, 'la': 1.0, 'lo': 2.0, 'df': 'DCIM'},
        ),
      );
      expect(f.hash, 'keep');
      expect(f.duration, 9);
      expect(f.location!.latitude, 1.0);
      expect(f.deviceFolder, 'DCIM');
    });

    test('magic metadata is applied only when the version is higher', () {
      final f = _row()
        ..mMdVersion = 3
        ..mMdEncodedJson = '{"visibility":0}';
      applyMetaEntry(f, const FileMetaEntry(mmd: '{"visibility":1}', mv: 2));
      expect(f.mMdVersion, 3);
      applyMetaEntry(f, const FileMetaEntry(mmd: '{"visibility":1}', mv: 4));
      expect(f.mMdVersion, 4);
      expect(f.magicMetadata.visibility, 1);
    });
  });

  group('reconcileMeta', () {
    test(
      'a new file without cloud data and without local data needs nothing',
      () {
        final r = reconcileMeta(local: const FileMetaEntry());
        expect(r.uploadNeeded, isFalse);
      },
    );

    test('local data the cloud does not know is queued', () {
      final r = reconcileMeta(local: const FileMetaEntry(mmd: '{}', mv: 1));
      expect(r.uploadNeeded, isTrue);
    });

    test('cloud data wins when it is newer and nothing is uploaded', () {
      final r = reconcileMeta(
        local: const FileMetaEntry(mmd: '{"a":1}', mv: 1),
        cloud: const FileMetaEntry(mmd: '{"a":2}', mv: 2),
      );
      expect(r.entry.mv, 2);
      expect(r.uploadNeeded, isFalse);
    });

    test('newer local edits are queued even when the cloud has older ones', () {
      final r = reconcileMeta(
        local: const FileMetaEntry(mmd: '{"a":3}', mv: 3),
        cloud: const FileMetaEntry(mmd: '{"a":2}', mv: 2),
      );
      expect(r.entry.mv, 3);
      expect(r.uploadNeeded, isTrue);
    });

    test('base values only known locally are queued', () {
      final r = reconcileMeta(
        local: const FileMetaEntry(base: {'h': 'x'}),
        cloud: const FileMetaEntry(mmd: '{}', mv: 1),
      );
      expect(r.uploadNeeded, isTrue);
      expect(r.entry.base, {'h': 'x'});
    });
  });

  group('filenRowUnchanged', () {
    EnteFile mapped() => filenFileToEnteFile(
      const FilenFile(
        uuid: _uuid,
        parentUuid: 'p',
        name: 'a.jpg',
        mime: 'image/jpeg',
        size: 10,
        createdMs: 1,
        modifiedMs: 3,
        canMakeThumbnail: true,
      ),
      collectionID: 1,
      ownerID: 5,
    )!;

    test('a row built from the same listing is unchanged', () {
      final m = mapped();
      final row = EnteFile.from(m)..uploadedFileID = m.uploadedFileID;
      expect(filenRowUnchanged(row, m), isTrue);
    });

    test('a different size or newer metadata version is a change', () {
      final m = mapped();
      final row = EnteFile.from(m);
      row.fileSize = 11;
      expect(filenRowUnchanged(row, m), isFalse);
      final row2 = EnteFile.from(m);
      m.pubMmdVersion = 2;
      expect(filenRowUnchanged(row2, m), isFalse);
    });
  });

  group('collections from the tree', () {
    test('the state folder never becomes an album', () {
      final tree = FilenTree(
        const [
          FilenDir(uuid: _dirA, parentUuid: _root, name: 'Trip'),
          FilenDir(uuid: _dirB, parentUuid: _root, name: kFilenStateDirName),
          FilenDir(uuid: _dirC, parentUuid: _root, name: null),
        ],
        const [
          FilenFile(
            uuid: '00000000-0000-4000-8000-0000000000aa',
            parentUuid: _dirA,
            name: 'a.jpg',
            mime: 'image/jpeg',
            size: 1,
            createdMs: 1,
            modifiedMs: 1,
            canMakeThumbnail: true,
          ),
        ],
      );
      final cols = collectionsFromTree(
        tree,
        rootUuid: _root,
        owner: User(id: 1, email: 'x'),
        updationTime: 1,
      );
      expect(cols.map((c) => c.displayName), ['Filen Photos', 'Trip']);
      expect(cols.first.type, CollectionType.uncategorized);
      expect(cols.last.type, CollectionType.album);
    });
  });

  group('ML data', () {
    test('the version grows when either model version grows', () {
      int v(int face, int clip) => FilenMl.versionOf({
        'face': {'version': face},
        'clip': {'version': clip},
      });
      expect(v(1, 1) < v(1, 2), isTrue);
      expect(v(1, 9) < v(2, 1), isTrue);
      expect(FilenMl.versionOf({}), 0);
    });
  });

  group('virtual collections', () {
    test('favorites and albums map to Ente collection types', () {
      final fav = filenVirtualToCollection(
        VirtualCollection(
          uuid: _uuid,
          name: 'Favorites',
          type: 'favorites',
          createdAt: 1,
          updatedAt: 2,
        ),
        User(id: 1, email: 'x'),
      );
      expect(fav.type, CollectionType.favorites);
      final album = filenVirtualToCollection(
        VirtualCollection(
          uuid: _uuid,
          name: 'Hidden',
          type: 'album',
          createdAt: 1,
          updatedAt: 2,
          meta: const CollectionMeta(
            mmd: '{"visibility":2,"subType":0}',
            mv: 1,
          ),
        ),
        User(id: 1, email: 'x'),
      );
      expect(album.type, CollectionType.album);
      expect(album.mMdVersion, 1);
      expect(album.magicMetadata.visibility, 2);
    });
  });
}
