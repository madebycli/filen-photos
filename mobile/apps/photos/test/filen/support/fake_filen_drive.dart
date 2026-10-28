import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// A Filen drive in memory behind the same method channel the real plugin uses, so the app code
/// under test runs unchanged. It does nothing but keep files and count what the app asks for;
/// `originalBytesSent` is what a real phone would have pulled over the network for photo/video
/// originals (state-folder files are counted separately).
class FakeFilenDrive {
  FakeFilenDrive() {
    _dirs[rootUuid] = _Dir('', null);
  }

  static const channelName = 'io.ente.photos/filen_sdk';
  static const rootUuid = '00000000-0000-4000-8000-000000000000';

  final Map<String, _Dir> _dirs = {};
  final Map<String, _File> _files = {};
  int _next = 1;

  /// Every call by method name, in order.
  final List<String> calls = [];
  int originalDownloads = 0;
  int originalBytesSent = 0;
  int thumbnailRequests = 0;

  /// How long a preview takes, so tests can scroll faster than previews arrive.
  Duration thumbnailDelay = Duration.zero;
  int streamRequests = 0;
  int stateBytesRead = 0;
  int stateBytesWritten = 0;

  int count(String method) => calls.where((c) => c == method).length;

  void resetCounters() {
    calls.clear();
    originalDownloads = 0;
    originalBytesSent = 0;
    thumbnailRequests = 0;
    streamRequests = 0;
    stateBytesRead = 0;
    stateBytesWritten = 0;
  }

  // The app derives its numeric ids from the first 15 hex digits, so the counter goes there.
  String _id() =>
      '${(_next++).toRadixString(16).padLeft(8, '0')}-1000-4000-8000-000000000000';

  /// Adds a user photo/video (not state) below the library folder and returns its uuid.
  String addMedia(String name, int size, {String album = ''}) {
    final library = _ensureDir(rootUuid, 'Filen Photos');
    final parent = album.isEmpty ? library : _ensureDir(library, album);
    final uuid = _id();
    _files[uuid] = _File(parent, name, Uint8List(size), isState: false);
    return uuid;
  }

  String _ensureDir(String parent, String name) {
    for (final e in _dirs.entries) {
      if (e.value.parent == parent && e.value.name == name) return e.key;
    }
    final uuid = _id();
    _dirs[uuid] = _Dir(name, parent);
    return uuid;
  }

  bool _isStateDir(String? uuid) {
    var d = uuid;
    while (d != null) {
      if (_dirs[d]?.name == '.filen-photos') return true;
      d = _dirs[d]?.parent;
    }
    return false;
  }

  Map<String, Object?> _fileMap(String uuid, _File f) => {
    'uuid': uuid,
    'parent': f.parent,
    'name': f.name,
    'mime': f.name.endsWith('.mp4') ? 'video/mp4' : 'image/jpeg',
    'size': f.data.length,
    'created': 1700000000000,
    'modified': 1700000000000,
    'canMakeThumbnail': true,
  };

  Map<String, Object?> _folder(String uuid) => {
    'dirs': [
      for (final e in _dirs.entries)
        if (e.value.parent == uuid)
          {'uuid': e.key, 'parent': uuid, 'name': e.value.name},
    ],
    'files': [
      for (final e in _files.entries)
        if (e.value.parent == uuid) _fileMap(e.key, e.value),
    ],
  };

  void install() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel(channelName), _handle);
  }

  void uninstall() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel(channelName), null);
  }

  Future<Object?> _handle(MethodCall call) async {
    calls.add(call.method);
    final a = (call.arguments as Map?)?.cast<String, Object?>() ?? {};
    switch (call.method) {
      case 'findOrCreateRootChild':
        return _ensureDir(rootUuid, a['name']! as String);
      case 'ensureDir':
      case 'createDir':
        return _ensureDir(a['parentUuid']! as String, a['name']! as String);
      case 'listFolder':
        return _folder(a['uuid']! as String);
      case 'listTree':
        final all = <String, Object?>{
          'dirs': [
            for (final e in _dirs.entries)
              if (e.key != rootUuid)
                {'uuid': e.key, 'parent': e.value.parent, 'name': e.value.name},
          ],
          'files': [for (final e in _files.entries) _fileMap(e.key, e.value)],
        };
        return all;
      case 'readBytes':
        final f = _files[a['uuid']]!;
        if (f.isState) {
          stateBytesRead += f.data.length;
        } else {
          originalDownloads++;
          originalBytesSent += f.data.length;
        }
        return f.data;
      case 'writeBytes':
        final data = a['data']! as Uint8List;
        final uuid = _id();
        final parent = a['parentUuid']! as String;
        _files[uuid] = _File(
          parent,
          a['name']! as String,
          data,
          isState: _isStateDir(parent),
        );
        stateBytesWritten += data.length;
        return _fileMap(uuid, _files[uuid]!);
      case 'deleteFilePermanently':
        _files.remove(a['uuid']);
        return null;
      case 'downloadFile':
        final f = _files[a['uuid']]!;
        originalDownloads++;
        originalBytesSent += f.data.length;
        await File(a['destPath']! as String).writeAsBytes(f.data);
        return null;
      case 'thumbnail':
        thumbnailRequests++;
        if (thumbnailDelay > Duration.zero)
          await Future<void>.delayed(thumbnailDelay);
        // A real thumbnail is a few KB read from the start of the file.
        return Uint8List(4096);
      case 'streamUrl':
        streamRequests++;
        return 'http://127.0.0.1:1/stream/${a['uuid']}';
    }
    throw MissingPluginException('FakeFilenDrive: ${call.method}');
  }
}

class _Dir {
  _Dir(this.name, this.parent);
  final String name;
  final String? parent;
}

class _File {
  _File(this.parent, this.name, this.data, {required this.isState});
  final String parent;
  final String name;
  final Uint8List data;
  final bool isState;
}
