import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart';

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

  const FilenUserInfo({
    required this.email,
    required this.userId,
    required this.storageUsed,
    required this.maxStorage,
    required this.rootUuid,
    this.nickName,
  });

  factory FilenUserInfo.fromMap(Map<Object?, Object?> m) => FilenUserInfo(
    email: m['email']! as String,
    userId: m['userId']! as int,
    storageUsed: m['storageUsed']! as int,
    maxStorage: m['maxStorage']! as int,
    rootUuid: m['rootUuid']! as String,
    nickName: m['nickName'] as String?,
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

  Future<T?> _call<T>(String method, [Map<String, Object?>? args]) async {
    try {
      return await _channel.invokeMethod<T>(method, args);
    } on PlatformException catch (e) {
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

  /// Every folder and file below [rootUuid].
  Future<FilenTree> listTree(String rootUuid) async {
    final m = (await _call<Map<Object?, Object?>>('listTree', {'rootUuid': rootUuid}))!;
    return FilenTree(
      [for (final d in m['dirs']! as List<Object?>) FilenDir.fromMap(d! as Map<Object?, Object?>)],
      [for (final f in m['files']! as List<Object?>) FilenFile.fromMap(f! as Map<Object?, Object?>)],
    );
  }

  Future<String> findOrCreateRootChild(String name) async =>
      (await _call<String>('findOrCreateRootChild', {'name': name}))!;

  Future<String> createDir({required String parentUuid, required String name}) async =>
      (await _call<String>('createDir', {'parentUuid': parentUuid, 'name': name}))!;

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
