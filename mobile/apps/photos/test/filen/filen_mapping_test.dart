import 'package:filen_sdk/filen_sdk.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photos/filen/filen_ids.dart';
import 'package:photos/filen/filen_media_mapper.dart';
import 'package:photos/filen/filen_sync.dart';
import 'package:photos/models/api/collection/user.dart';
import 'package:photos/models/collection/collection.dart';
import 'package:photos/models/file/file.dart';
import 'package:photos/models/file/file_type.dart';

FilenFile _file({
  String uuid = '2c1f6f4e-8f0a-4c7d-9a1e-5d3b7e9a0c11',
  String parent = '11111111-2222-4333-8444-555555555555',
  String name = 'IMG_0001.jpg',
  String mime = 'image/jpeg',
  int size = 1234,
  int? created = 1700000000000,
  int modified = 1700000500000,
}) => FilenFile(
  uuid: uuid,
  parentUuid: parent,
  name: name,
  mime: mime,
  size: size,
  createdMs: created,
  modifiedMs: modified,
  canMakeThumbnail: true,
);

void main() {
  group('filenUuidToId', () {
    test('is deterministic, positive and 60 bit', () {
      const uuid = 'ffffffff-ffff-4fff-bfff-ffffffffffff';
      final id = filenUuidToId(uuid);
      expect(id, filenUuidToId(uuid.toUpperCase()));
      // 15 hex digits (60 bits) of the dash-less UUID, version nibble included.
      expect(id, 0xffffffffffff4ff);
      expect(id, greaterThan(0));
    });

    test('differs for different uuids', () {
      expect(
        filenUuidToId('aaaaaaaa-0000-4000-8000-000000000000'),
        isNot(filenUuidToId('bbbbbbbb-0000-4000-8000-000000000000')),
      );
    });

    test('rejects non-uuids', () {
      expect(() => filenUuidToId('nope'), throwsArgumentError);
      expect(
        () => filenUuidToId('zzzzzzzz-zzzz-zzzz-zzzz-zzzzzzzzzzzz'),
        throwsArgumentError,
      );
    });
  });

  group('filenFileType', () {
    test('uses mime first', () {
      expect(filenFileType('image/heic', 'x'), FileType.image);
      expect(filenFileType('video/quicktime', 'x'), FileType.video);
    });

    test('falls back to extension for generic mime types', () {
      expect(
        filenFileType('application/octet-stream', 'a.HEIC'),
        FileType.image,
      );
      expect(
        filenFileType('application/octet-stream', 'clip.mp4'),
        FileType.video,
      );
    });

    test('ignores non-media files', () {
      expect(filenFileType('application/pdf', 'doc.pdf'), isNull);
      expect(filenFileType('application/octet-stream', 'noext'), isNull);
      expect(filenFileType('application/octet-stream', 'trailing.'), isNull);
    });
  });

  group('filenFileToEnteFile', () {
    test('maps metadata into Ente units and tags the file as Filen', () {
      final f = _file();
      final e = filenFileToEnteFile(f, collectionID: 7, ownerID: 42)!;
      expect(e.uploadedFileID, filenUuidToId(f.uuid));
      expect(e.collectionID, 7);
      expect(e.ownerID, 42);
      expect(e.title, 'IMG_0001.jpg');
      expect(e.fileType, FileType.image);
      // Ente stores microseconds.
      expect(e.creationTime, 1700000000000 * 1000);
      expect(e.modificationTime, 1700000500000 * 1000);
      expect(e.fileSize, 1234);
      expect(e.localID, isNull);
      expect(isFilenFile(e), isTrue);
      expect(filenUuidOf(e), f.uuid);
      expect(e.isRemoteOnlyFile, isTrue);
    });

    test(
      'falls back to the modification time when no creation time exists',
      () {
        final e = filenFileToEnteFile(
          _file(created: null),
          collectionID: 1,
          ownerID: 1,
        )!;
        expect(e.creationTime, 1700000500000 * 1000);
      },
    );

    test('keeps the row identity of an already synced file', () {
      final e = filenFileToEnteFile(
        _file(),
        collectionID: 1,
        ownerID: 1,
        existingGeneratedID: 99,
      )!;
      expect(e.generatedID, 99);
    });

    test('skips non-media files', () {
      expect(
        filenFileToEnteFile(
          _file(name: 'a.pdf', mime: 'application/pdf'),
          collectionID: 1,
          ownerID: 1,
        ),
        isNull,
      );
    });

    test('plain Ente files are not Filen files', () {
      expect(isFilenFile(EnteFile()), isFalse);
      expect(() => filenUuidOf(EnteFile()), throwsStateError);
    });
  });

  group('collectionsFromTree', () {
    test('library root is Uncategorized, sub folders are albums', () {
      const root = '11111111-2222-4333-8444-555555555555';
      const sub = '99999999-2222-4333-8444-555555555555';
      const tree = FilenTree([
        FilenDir(uuid: sub, parentUuid: root, name: 'Holiday'),
      ], []);
      final cols = collectionsFromTree(
        tree,
        rootUuid: root,
        owner: User(id: 5, email: 'a@b.c'),
        updationTime: 123,
      );
      expect(cols, hasLength(2));
      expect(cols[0].id, filenUuidToId(root));
      expect(cols[0].type, CollectionType.uncategorized);
      expect(cols[1].id, filenUuidToId(sub));
      expect(cols[1].type, CollectionType.album);
      expect(cols[1].displayName, 'Holiday');
      expect(cols[1].updationTime, 123);
      expect(cols[1].isOwner(5), isTrue);
    });

    test('folders whose name could not be decrypted are left out', () {
      const root = '11111111-2222-4333-8444-555555555555';
      const tree = FilenTree([
        FilenDir(
          uuid: '99999999-2222-4333-8444-555555555555',
          parentUuid: root,
        ),
      ], []);
      final cols = collectionsFromTree(
        tree,
        rootUuid: root,
        owner: User(id: 5, email: 'a@b.c'),
        updationTime: 1,
      );
      expect(cols, hasLength(1));
    });
  });
}
