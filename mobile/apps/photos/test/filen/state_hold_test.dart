// ignore_for_file: depend_on_referenced_packages
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:photos/core/configuration.dart';
import 'package:photos/filen/filen_sync.dart';
import 'package:photos/service_locator.dart';
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

/// Without the cloud state a Filen file cannot be told apart from the local copy of the same
/// photo. New files then wait for it, instead of showing up twice.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  final drive = FakeFilenDrive();

  setUpAll(() async {
    root = Directory.systemTemp.createTempSync('filen-hold');
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
  });

  tearDownAll(() {
    drive.uninstall();
    root.deleteSync(recursive: true);
  });

  Future<int> newFilesInDiff() async {
    final sync = FilenSyncService.instance;
    final collections = await sync.fetchCollections();
    final album = collections.firstWhere((c) => c.displayName == 'Camera');
    return (await sync.getDiff(album.id)).updatedFiles.length;
  }

  test('new files wait while the state cannot be read, then arrive', () async {
    drive.addMedia('a.jpg', 10, album: 'Camera');
    drive.addMedia('b.jpg', 10, album: 'Camera');
    FilenSyncService.instance.reset();

    drive.failFolderListings = true;
    // The state is not there (the connection dropped): nothing new is put in the gallery.
    // (The folder listing itself uses the tree call, which still works.)
    expect(await newFilesInDiff(), 0);

    drive.failFolderListings = false;
    expect(await newFilesInDiff(), 2);
  });

  test(
    'a state that stays unreadable does not hide the library for good',
    () async {
      FilenSyncService.instance.reset();
      drive.addMedia('c.jpg', 10, album: 'Camera');
      drive.failFolderListings = true;
      for (var i = 0; i < 3; i++) {
        await newFilesInDiff();
      }
      // After three failed attempts the files are taken anyway.
      expect(await newFilesInDiff(), greaterThan(0));
      drive.failFolderListings = false;
    },
  );
}
