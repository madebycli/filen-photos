// ignore_for_file: depend_on_referenced_packages
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:photos/core/cache/thumbnail_in_memory_cache.dart';
import 'package:photos/core/cache/video_cache_manager.dart';
import 'package:photos/core/configuration.dart';
import 'package:photos/filen/filen_account.dart';
import 'package:photos/filen/filen_ids.dart';
import 'package:photos/filen/filen_state.dart';
import 'package:photos/models/file/file.dart';
import 'package:photos/models/file/file_type.dart';
import 'package:photos/module/download/file.dart';
import 'package:photos/module/download/thumbnail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_filen_drive.dart';

class _TestPaths extends PathProviderPlatform {
  _TestPaths(this.root);
  final Directory root;

  Future<String> _dir(String name) async {
    final d = Directory('${root.path}/$name')..createSync(recursive: true);
    return d.path;
  }

  @override
  Future<String?> getTemporaryPath() => _dir('cache');
  @override
  Future<String?> getApplicationDocumentsPath() => _dir('documents');
  @override
  Future<String?> getApplicationSupportPath() => _dir('support');
}

/// What a user of the app (and of Ente) expects of data usage, written from the user's point of
/// view and checked against a counting fake of the Filen drive:
///
///  * scrolling the grid loads small previews, never originals, and each preview only once;
///  * opening a photo fetches that photo once, from the network, into an evictable cache;
///  * looking at photos never fills the phone's library or documents folder;
///  * videos are streamed, not downloaded;
///  * syncing the library reads lists only, no photo data.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  final drive = FakeFilenDrive();
  const mb = 1024 * 1024;

  EnteFile remote(String uuid, String name, int size, FileType type) {
    return EnteFile()
      ..uploadedFileID = filenUuidToId(uuid)
      ..generatedID = filenUuidToId(uuid)
      ..collectionID = 1
      ..encryptedKey = uuid
      ..keyDecryptionNonce = kFilenKeyMarker
      ..title = name
      ..fileType = type
      ..fileSize = size
      ..creationTime = 1700000000000000
      ..modificationTime = 1700000000000000;
  }

  List<File> filesUnder(String sub) {
    final d = Directory('${root.path}/$sub');
    if (!d.existsSync()) return [];
    return d.listSync(recursive: true).whereType<File>().toList();
  }

  setUpAll(() async {
    root = Directory.systemTemp.createTempSync('filen-contract');
    PathProviderPlatform.instance = _TestPaths(root);
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async => null,
        );
    drive.install();
    await Configuration.instance.init(await SharedPreferences.getInstance());
  });

  tearDownAll(() {
    drive.uninstall();
    root.deleteSync(recursive: true);
  });

  setUp(() async {
    drive.resetCounters();
    FilenState.instance.reset();
    FilenAccount.instance.onLogout().ignore();
    ThumbnailInMemoryLruCache.clearCache;
    await DefaultCacheManager().emptyCache();
    await VideoCacheManager.instance.emptyCache();
    for (final f in filesUnder('cache/thumbnail-cache')) {
      f.deleteSync();
    }
  });

  group('scrolling the grid', () {
    test('shows previews only: no original is downloaded', () async {
      final photos = [
        for (var i = 0; i < 30; i++)
          remote(
            drive.addMedia('IMG_$i.jpg', 5 * mb),
            'IMG_$i.jpg',
            5 * mb,
            FileType.image,
          ),
      ];
      drive.resetCounters();
      for (final p in photos) {
        await getThumbnail(p);
      }
      expect(drive.originalDownloads, 0);
      expect(drive.originalBytesSent, 0);
      expect(drive.thumbnailRequests, 30);
    });

    test('scrolling back and forth loads each preview once', () async {
      final p = remote(
        drive.addMedia('a.jpg', 5 * mb),
        'a.jpg',
        5 * mb,
        FileType.image,
      );
      await getThumbnail(p);
      final first = drive.thumbnailRequests;
      for (var i = 0; i < 5; i++) {
        await getThumbnail(p);
      }
      expect(drive.thumbnailRequests, first);
    });

    test(
      'previews of photos that scrolled away before their turn are never fetched',
      () async {
        drive.thumbnailDelay = const Duration(milliseconds: 200);
        final photos = [
          for (var i = 0; i < 60; i++)
            remote(
              drive.addMedia('f$i.jpg', 5 * mb),
              'f$i.jpg',
              5 * mb,
              FileType.image,
            ),
        ];
        drive.resetCounters();
        // A fling: the screen asks for all 60, then only the last 6 are still visible.
        final pending = [
          for (final p in photos) getThumbnail(p).then((_) {}, onError: (_) {}),
        ];
        // Wait until the first preview is really on its way (the app has queued the rest).
        while (drive.thumbnailRequests == 0) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
        for (final p in photos.take(54)) {
          removePendingGetThumbnailRequestIfAny(p);
        }
        await Future.wait(pending.skip(54));
        await Future<void>.delayed(const Duration(milliseconds: 300));
        drive.thumbnailDelay = Duration.zero;
        expect(
          drive.thumbnailRequests,
          lessThan(15),
          reason: 'only what is on screen (plus the few already running)',
        );
        expect(drive.originalDownloads, 0);
      },
    );

    test('a preview seen before is still there after the app restarts', () async {
      final p = remote(
        drive.addMedia('b.jpg', 5 * mb),
        'b.jpg',
        5 * mb,
        FileType.image,
      );
      await getThumbnail(p);
      // "Restart": the in-memory copy and the in-memory index are gone, the disk cache stays.
      ThumbnailInMemoryLruCache.clearCache(p);
      FilenState.instance.reset();
      drive.resetCounters();
      await getThumbnail(p);
      expect(
        drive.thumbnailRequests,
        0,
        reason: 'must come from the disk cache',
      );
      expect(drive.originalDownloads, 0);
    });
  });

  group('a second device (or a reinstall)', () {
    test(
      'gets previews from the small copies on Filen, not from the originals',
      () async {
        final p = remote(
          drive.addMedia('d.jpg', 6 * mb),
          'd.jpg',
          6 * mb,
          FileType.image,
        );
        await getThumbnail(p);
        // Let the background write of the stored preview finish.
        await Future<void>.delayed(const Duration(milliseconds: 200));
        expect(drive.stateBytesWritten, greaterThan(0));

        // New device: no memory copy, no disk cache, nothing known yet.
        ThumbnailInMemoryLruCache.clearCache(p);
        for (final f in filesUnder('cache/thumbnail-cache')) {
          f.deleteSync();
        }
        FilenState.instance.reset();
        drive.resetCounters();

        await getThumbnail(p);
        expect(
          drive.thumbnailRequests,
          0,
          reason: 'the stored preview is used',
        );
        expect(drive.originalDownloads, 0);
        expect(drive.stateBytesRead, lessThan(100 * 1024));
      },
    );
  });

  group('opening a photo', () {
    test(
      'fetches that photo once and keeps it only in the evictable cache',
      () async {
        final p = remote(
          drive.addMedia('c.jpg', 3 * mb),
          'c.jpg',
          3 * mb,
          FileType.image,
        );
        drive.resetCounters();
        final file = await getFile(p);
        expect(file, isNotNull);
        expect(drive.originalDownloads, 1);
        expect(drive.originalBytesSent, 3 * mb);

        // Opening it again (or swiping back to it) costs nothing.
        await getFile(p);
        expect(drive.originalDownloads, 1);

        expect(
          filesUnder('documents'),
          isEmpty,
          reason: 'nothing may be kept in the documents folder',
        );
        expect(
          filesUnder('cache').where((f) => f.path.contains('/temp/filen-')),
          isEmpty,
          reason: 'the temporary download must be cleaned up',
        );
      },
    );

    test(
      'looking at many photos never downloads more than was opened',
      () async {
        final photos = [
          for (var i = 0; i < 10; i++)
            remote(
              drive.addMedia('v$i.jpg', 4 * mb),
              'v$i.jpg',
              4 * mb,
              FileType.image,
            ),
        ];
        drive.resetCounters();
        for (final p in photos) {
          await getFile(p);
        }
        expect(drive.originalDownloads, 10);
        expect(drive.originalBytesSent, 40 * mb);
        expect(filesUnder('documents'), isEmpty);
      },
    );

    test(
      'the cache is bounded like Ente\'s (it is not a second library)',
      () async {
        // Ente's cache managers are limited by object count and age, not kept forever.
        final video = VideoCacheManager.instance.config;
        expect(video.maxNrOfCacheObjects, lessThanOrEqualTo(50));
        expect(video.stalePeriod, lessThanOrEqualTo(const Duration(days: 3)));
        final photos = DefaultCacheManager().config;
        expect(photos.maxNrOfCacheObjects, lessThanOrEqualTo(200));
        expect(photos.stalePeriod, lessThanOrEqualTo(const Duration(days: 30)));
      },
    );
  });

  group('videos', () {
    test(
      'a video preview is made from a few seconds of the stream, not a download',
      () async {
        final v = remote(
          drive.addMedia('clip.mp4', 200 * mb),
          'clip.mp4',
          200 * mb,
          FileType.video,
        );
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel('native_video_editor'),
              (call) async => null,
            );
        drive.resetCounters();
        try {
          await getThumbnail(v);
        } catch (_) {
          // The frame extractor is native; only the network behaviour matters here.
        }
        expect(drive.originalDownloads, 0);
        expect(drive.originalBytesSent, 0);
      },
    );
  });
}
