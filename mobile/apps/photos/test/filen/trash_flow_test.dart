// ignore_for_file: depend_on_referenced_packages
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:photos/core/configuration.dart';
import 'package:photos/db/files_db.dart';
import 'package:photos/db/trash_db.dart';
import 'package:photos/filen/filen_ids.dart';
import 'package:photos/gateways/trash/models/trash_item_request.dart';
import 'package:photos/models/file/file.dart';
import 'package:photos/models/file/file_type.dart';
import 'package:photos/service_locator.dart';
import 'package:photos/services/sync/trash_sync_service.dart';
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

/// The trash as a user of Ente expects it, against a fake Filen drive: deleting a photo from the
/// cloud moves it to Filen's trash, the trash page lists it, and it can be deleted for good.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late TrashSyncService trash;
  final drive = FakeFilenDrive();

  EnteFile backedUp(String uuid, String name) => EnteFile()
    ..uploadedFileID = filenUuidToId(uuid)
    ..collectionID = 1
    ..ownerID = 1
    ..encryptedKey = uuid
    ..keyDecryptionNonce = kFilenKeyMarker
    ..title = name
    ..fileType = FileType.image
    ..fileSize = 100
    ..creationTime = 1700000000000000
    ..modificationTime = 1700000000000000
    ..updationTime = 1700000000000000;

  Future<List<EnteFile>> trashPage() async {
    // The same call the trash page makes for the cloud trash.
    final result = await TrashDB.instance.getTrashedFiles(
      -8640000000000000000,
      9223372036854775807,
      limit: 1000,
      asc: false,
    );
    return result.files;
  }

  setUpAll(() async {
    root = Directory.systemTemp.createTempSync('filen-trash');
    PathProviderPlatform.instance = _TestPaths(root);
    SharedPreferences.setMockInitialValues({'user_id': 1});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async => null,
        );
    drive.install();
    final prefs = await SharedPreferences.getInstance();
    ServiceLocator.instance.init(
      prefs,
      PackageInfo(
        appName: 'test',
        packageName: 'test',
        version: '1',
        buildNumber: '1',
      ),
    );
    await Configuration.instance.init(prefs);
    trash = TrashSyncService(await SharedPreferences.getInstance());
  });

  tearDownAll(() {
    drive.uninstall();
    root.deleteSync(recursive: true);
  });

  test(
    'a photo deleted from Filen lands in Filen\'s trash and on the trash page',
    () async {
      final uuid = drive.addMedia('beach.jpg', 100);
      final row = backedUp(uuid, 'beach.jpg');
      await FilesDB.instance.insertMultiple([row]);

      await trash.trashFilesOnServer([
        TrashRequest(row.uploadedFileID!, row.collectionID!),
      ]);
      await FilesDB.instance.deleteMultipleUploadedFiles([row.uploadedFileID!]);

      expect(
        drive.isTrashed(uuid),
        isTrue,
        reason: 'it must be in Filen\'s trash',
      );
      expect(drive.exists(uuid), isFalse);

      // On the trash page right away: no sync has run (a long upload can keep the next one
      // waiting).
      var listed = await trashPage();
      expect(listed.map((f) => f.title), ['beach.jpg']);
      expect(listed.single.uploadedFileID, row.uploadedFileID);

      // The sync that follows agrees and does not list it twice.
      await trash.syncTrash();
      listed = await trashPage();
      expect(listed.map((f) => f.title), ['beach.jpg']);
    },
  );

  test(
    'a photo trashed on another device shows up when the trash page opens',
    () async {
      final uuid = drive.addMedia('sunset.jpg', 100);
      await drive.trashDirectly(uuid);
      expect((await trashPage()).map((f) => f.title), ['beach.jpg']);

      await trash.syncTrash();
      expect((await trashPage()).map((f) => f.title).toSet(), {
        'beach.jpg',
        'sunset.jpg',
      });
    },
  );

  test(
    'deleting from the trash page removes the photo from Filen for good',
    () async {
      final listed = await trashPage();
      expect(listed.length, 2);
      await trash.deleteFromTrash([for (final f in listed) f as dynamic]);
      await trash.syncTrash();
      expect(await trashPage(), isEmpty);
    },
  );
}
