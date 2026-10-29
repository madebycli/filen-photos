import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:logging/logging.dart';

/// Failure reported by the Filen SDK layer. [code] is one of:
/// TWO_FACTOR_REQUIRED, TWO_FACTOR_WRONG, BAD_CREDENTIALS, UNAUTHENTICATED, NOT_LOGGED_IN,
/// STORAGE_FULL, NETWORK, NOT_FOUND, CANCELLED, SDK_ERROR, PLUGIN_ERROR.
class FilenException implements Exception {
  final String code;
  final String? message;
  const FilenException(this.code, [this.message]);

  @override
  String toString() => 'FilenException($code${message == null ? '' : ': $message'})';
}

class FilenUserInfo {
  final String email;
  final int userId;
  final int storageUsed;
  final int maxStorage;
  final String rootUuid;
  final String? nickName;
  final bool versioningEnabled;
  final int versionedFiles;
  final int versionedStorage;
  final bool loginAlertsEnabled;
  final bool twoFactorEnabled;
  final int unfinishedFiles;
  final int unfinishedStorage;

  const FilenUserInfo({
    required this.email,
    required this.userId,
    required this.storageUsed,
    required this.maxStorage,
    required this.rootUuid,
    this.nickName,
    this.versioningEnabled = false,
    this.versionedFiles = 0,
    this.versionedStorage = 0,
    this.loginAlertsEnabled = false,
    this.twoFactorEnabled = false,
    this.unfinishedFiles = 0,
    this.unfinishedStorage = 0,
  });

  factory FilenUserInfo.fromMap(Map<Object?, Object?> m) => FilenUserInfo(
    email: m['email']! as String,
    userId: m['userId']! as int,
    storageUsed: m['storageUsed']! as int,
    maxStorage: m['maxStorage']! as int,
    rootUuid: m['rootUuid']! as String,
    nickName: m['nickName'] as String?,
    versioningEnabled: (m['versioningEnabled'] as bool?) ?? false,
    versionedFiles: (m['versionedFiles'] as int?) ?? 0,
    versionedStorage: (m['versionedStorage'] as int?) ?? 0,
    loginAlertsEnabled: (m['loginAlertsEnabled'] as bool?) ?? false,
    twoFactorEnabled: (m['twoFactorEnabled'] as bool?) ?? false,
    unfinishedFiles: (m['unfinishedFiles'] as int?) ?? 0,
    unfinishedStorage: (m['unfinishedStorage'] as int?) ?? 0,
  );
}

class FilenDir {
  final String uuid;
  final String parentUuid;
  final String? name;

  const FilenDir({required this.uuid, required this.parentUuid, this.name});

  factory FilenDir.fromMap(Map<Object?, Object?> m) => FilenDir(
    uuid: m['uuid']! as String,
    parentUuid: m['parent']! as String,
    name: m['name'] as String?,
  );
}

class FilenFile {
  final String uuid;
  final String parentUuid;
  final String name;
  final String mime;
  final int size;

  /// Milliseconds since epoch; null when the uploader did not record a creation time.
  final int? createdMs;
  final int modifiedMs;
  final bool canMakeThumbnail;

  const FilenFile({
    required this.uuid,
    required this.parentUuid,
    required this.name,
    required this.mime,
    required this.size,
    required this.createdMs,
    required this.modifiedMs,
    required this.canMakeThumbnail,
  });

  factory FilenFile.fromMap(Map<Object?, Object?> m) => FilenFile(
    uuid: m['uuid']! as String,
    parentUuid: m['parent']! as String,
    name: m['name']! as String,
    mime: m['mime']! as String,
    size: m['size']! as int,
    createdMs: m['created'] as int?,
    modifiedMs: m['modified']! as int,
    canMakeThumbnail: (m['canMakeThumbnail'] as bool?) ?? false,
  );
}

class FilenTree {
  final List<FilenDir> dirs;
  final List<FilenFile> files;
  const FilenTree(this.dirs, this.files);
}

/// Dart API over Filen's official Rust SDK (Android only, via the `io.ente.photos/filen_sdk`
/// channel). The SDK does all networking and cryptography; this class only marshals calls.
class FilenSdk {
  FilenSdk({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('io.ente.photos/filen_sdk');

  static final FilenSdk instance = FilenSdk();

  final MethodChannel _channel;

  static final Logger _log = Logger('FilenSdk');

  /// Every call is logged with its duration and, on failure, the error code and message. Arguments
  /// are never logged: they can hold passwords, local paths or file names.
  Future<T?> _call<T>(String method, [Map<String, Object?>? args]) async {
    final watch = Stopwatch()..start();
    try {
      final result = await _channel.invokeMethod<T>(method, args);
      _log.fine('$method ok in ${watch.elapsedMilliseconds} ms');
      return result;
    } on PlatformException catch (e) {
      _log.warning(
        '$method failed after ${watch.elapsedMilliseconds} ms: ${e.code} ${e.message}'
        '${e.details == null ? '' : '\n${e.details}'}',
      );
      throw FilenException(e.code, e.message);
    }
  }

  /// Logs in and returns the serialized session. The caller must keep it in secure storage.
  Future<String> login({
    required String email,
    required String password,
    String? twoFactorCode,
  }) async => (await _call<String>('login', {
    'email': email,
    'password': password,
    'twoFactorCode': twoFactorCode,
  }))!;

  Future<void> restore(String session) => _call<void>('restore', {'session': session});

  Future<void> logout() => _call<void>('logout');

  Future<bool> isLoggedIn() async => (await _call<bool>('isLoggedIn')) ?? false;

  Future<FilenUserInfo> userInfo() async => FilenUserInfo.fromMap(
    (await _call<Map<Object?, Object?>>('userInfo'))!,
  );

  Future<String> rootUuid() async => (await _call<String>('rootUuid'))!;

  /// Total size and counts of the folder [uuid] and everything below it.
  Future<({int size, int files, int dirs})> dirSize(String uuid) async {
    final m = (await _call<Map<Object?, Object?>>('dirSize', {'uuid': uuid}))!;
    return (size: m['size']! as int, files: m['files']! as int, dirs: m['dirs']! as int);
  }

  Future<void> setVersioning(bool enabled) => _call<void>('setVersioning', {'enabled': enabled});

  /// Deletes the old versions Filen keeps of changed files.
  Future<void> deleteAllVersions() => _call<void>('deleteAllVersions');

  Future<void> setLoginAlerts(bool enabled) => _call<void>('setLoginAlerts', {'enabled': enabled});

  Future<void> changePassword({required String current, required String newPassword}) =>
      _call<void>('changePassword', {'current': current, 'new': newPassword});

  /// Every folder and file below [rootUuid].
  Future<FilenTree> listTree(String rootUuid, {List<String> skipDirNames = const []}) async {
    final m = (await _call<Map<Object?, Object?>>('listTree', {
      'rootUuid': rootUuid,
      'skipDirNames': skipDirNames,
    }))!;
    return FilenTree(
      [for (final d in m['dirs']! as List<Object?>) FilenDir.fromMap(d! as Map<Object?, Object?>)],
      [for (final f in m['files']! as List<Object?>) FilenFile.fromMap(f! as Map<Object?, Object?>)],
    );
  }

  Future<String> findOrCreateRootChild(String name) async =>
      (await _call<String>('findOrCreateRootChild', {'name': name}))!;

  Future<String> createDir({required String parentUuid, required String name}) async =>
      (await _call<String>('createDir', {'parentUuid': parentUuid, 'name': name}))!;

  /// One level of a folder (no recursion).
  Future<FilenTree> listFolder(String uuid) async {
    final m = (await _call<Map<Object?, Object?>>('listFolder', {'uuid': uuid}))!;
    return FilenTree(
      [for (final d in m['dirs']! as List<Object?>) FilenDir.fromMap(d! as Map<Object?, Object?>)],
      [for (final f in m['files']! as List<Object?>) FilenFile.fromMap(f! as Map<Object?, Object?>)],
    );
  }

  /// UUID of the child folder [name] of [parentUuid]; created when missing.
  Future<String> ensureDir({required String parentUuid, required String name}) async =>
      (await _call<String>('ensureDir', {'parentUuid': parentUuid, 'name': name}))!;

  Future<Uint8List> readBytes(String uuid) async =>
      (await _call<Uint8List>('readBytes', {'uuid': uuid}))!;

  /// Creates a new file. Never reuses a name: Filen replaces files by name.
  Future<FilenFile> writeBytes({
    required String parentUuid,
    required String name,
    required Uint8List data,
    int? modifiedMs,
  }) async => FilenFile.fromMap(
    (await _call<Map<Object?, Object?>>('writeBytes', {
      'parentUuid': parentUuid,
      'name': name,
      'data': data,
      'modifiedMs': modifiedMs,
    }))!,
  );

  /// Permanently deletes one of the app's own state files.
  Future<void> deleteFilePermanently(String uuid) =>
      _call<void>('deleteFilePermanently', {'uuid': uuid});

  /// Changes the capture/modification time Filen stores for the file.
  Future<void> setFileTimes({required String uuid, int? createdMs, int? modifiedMs}) =>
      _call<void>('setFileTimes', {'uuid': uuid, 'createdMs': createdMs, 'modifiedMs': modifiedMs});

  /// Local http URL that streams the decrypted file (with range requests) for media players.
  Future<String> streamUrl(String uuid) async => (await _call<String>('streamUrl', {'uuid': uuid}))!;

  /// Moves a whole folder to Filen's trash (recoverable there).
  Future<void> trashDir(String uuid) => _call<void>('trashDir', {'uuid': uuid});

  Future<void> renameDir({required String uuid, required String name}) =>
      _call<void>('renameDir', {'uuid': uuid, 'name': name});

  /// Moves the file to Filen's trash.
  Future<void> trashFile(String uuid) => _call<void>('trashFile', {'uuid': uuid});

  /// Files at the top level of Filen's trash.
  Future<List<FilenFile>> listTrash() async {
    final m = (await _call<Map<Object?, Object?>>('listTrash', {}))!;
    return [for (final f in m['files']! as List<Object?>) FilenFile.fromMap(f! as Map<Object?, Object?>)];
  }

  /// Puts a trashed file back into its original folder.
  Future<void> restoreFile(String uuid) => _call<void>('restoreFile', {'uuid': uuid});

  /// Permanently deletes everything in Filen's trash.
  Future<void> emptyTrash() => _call<void>('emptyTrash', {});

  Future<void> moveFile({required String uuid, required String newParentUuid}) =>
      _call<void>('moveFile', {'uuid': uuid, 'newParentUuid': newParentUuid});

  Future<void> downloadFile({required String uuid, required String destPath}) =>
      _call<void>('downloadFile', {'uuid': uuid, 'destPath': destPath});

  /// WebP bytes, or null if the SDK cannot produce a thumbnail for this file type.
  Future<Uint8List?> thumbnail(String uuid, {int maxWidth = 512, int maxHeight = 512}) =>
      _call<Uint8List>('thumbnail', {'uuid': uuid, 'maxWidth': maxWidth, 'maxHeight': maxHeight});

  Future<FilenFile> uploadFile({
    required String localPath,
    required String parentUuid,
    String? name,
    int? createdMs,
    int? modifiedMs,
    String? mime,
  }) async => FilenFile.fromMap(
    (await _call<Map<Object?, Object?>>('uploadFile', {
      'localPath': localPath,
      'parentUuid': parentUuid,
      'name': name,
      'createdMs': createdMs,
      'modifiedMs': modifiedMs,
      'mime': mime,
    }))!,
  );
}
