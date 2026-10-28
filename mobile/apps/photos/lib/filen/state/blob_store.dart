import 'dart:async';
import 'dart:typed_data';

import 'package:filen_sdk/filen_sdk.dart';

/// Name of the folder inside the Filen photo library that holds everything the app stores
/// besides the photos themselves (people, albums, favorites, ML results, thumbnails...).
const String kFilenStateDirName = '.filen-photos';

/// One file of the state folder.
class BlobInfo {
  const BlobInfo({
    required this.id,
    required this.name,
    required this.size,
    required this.modifiedMs,
  });

  /// Opaque handle (the Filen file uuid for the real store).
  final String id;
  final String name;
  final int size;
  final int modifiedMs;
}

/// A tiny file store rooted in the app's Filen state folder. `dir` is a relative path such as
/// `meta` or `ml/3f`; directories appear on first write. Files are immutable: an update is a new
/// file with a new name (Filen replaces by name), and the old one is deleted afterwards.
///
/// Everything above this interface is plain Dart and tested against [MemoryBlobStore]; only
/// [FilenDriveBlobStore] knows about Filen.
abstract class FilenBlobStore {
  Future<List<BlobInfo>> list(String dir);

  Future<Uint8List> readById(String id);

  Future<BlobInfo> write(String dir, String name, Uint8List data);

  /// Permanently deletes a file of the state folder. Never call this for photos.
  Future<void> deleteById(String id);
}

/// The real store: files below `<Filen Photos>/.filen-photos` on the user's Filen drive.
class FilenDriveBlobStore implements FilenBlobStore {
  FilenDriveBlobStore({
    required Future<String> Function() libraryRootUuid,
    FilenSdk? sdk,
    int concurrency = 6,
  }) : _libraryRootUuid = libraryRootUuid,
       _sdk = sdk ?? FilenSdk.instance,
       _slots = concurrency;

  final Future<String> Function() _libraryRootUuid;
  final FilenSdk _sdk;
  final Map<String, Future<String>> _dirUuids = {};
  final List<Completer<void>> _waiting = [];
  int _slots;

  Future<T> _limited<T>(Future<T> Function() action) async {
    if (_slots <= 0) {
      final turn = Completer<void>();
      _waiting.add(turn);
      await turn.future;
    } else {
      _slots--;
    }
    try {
      return await action();
    } finally {
      if (_waiting.isNotEmpty) {
        _waiting.removeAt(0).complete();
      } else {
        _slots++;
      }
    }
  }

  Future<String> _dirUuid(String path) {
    return _dirUuids.putIfAbsent(path, () async {
      final parent = path.contains('/')
          ? await _dirUuid(path.substring(0, path.lastIndexOf('/')))
          : await _stateRoot();
      final name = path.substring(path.lastIndexOf('/') + 1);
      return _limited(() => _sdk.ensureDir(parentUuid: parent, name: name));
    });
  }

  Future<String> _stateRoot() {
    return _dirUuids.putIfAbsent('', () async {
      final root = await _libraryRootUuid();
      return _limited(
        () => _sdk.ensureDir(parentUuid: root, name: kFilenStateDirName),
      );
    });
  }

  /// Forget cached folder uuids (after logout).
  void reset() => _dirUuids.clear();

  @override
  Future<List<BlobInfo>> list(String dir) async {
    final uuid = await _dirUuid(dir);
    final tree = await _limited(() => _sdk.listFolder(uuid));
    return [
      for (final f in tree.files)
        BlobInfo(
          id: f.uuid,
          name: f.name,
          size: f.size,
          modifiedMs: f.modifiedMs,
        ),
    ];
  }

  @override
  Future<Uint8List> readById(String id) => _limited(() => _sdk.readBytes(id));

  @override
  Future<BlobInfo> write(String dir, String name, Uint8List data) async {
    final uuid = await _dirUuid(dir);
    final f = await _limited(
      () => _sdk.writeBytes(
        parentUuid: uuid,
        name: name,
        data: data,
        modifiedMs: DateTime.now().millisecondsSinceEpoch,
      ),
    );
    return BlobInfo(
      id: f.uuid,
      name: f.name,
      size: f.size,
      modifiedMs: f.modifiedMs,
    );
  }

  @override
  Future<void> deleteById(String id) =>
      _limited(() => _sdk.deleteFilePermanently(id));
}

/// In-memory store for tests (and a handy reference of the contract).
class MemoryBlobStore implements FilenBlobStore {
  final Map<String, Map<String, ({String id, Uint8List data, int modifiedMs})>>
  _dirs = {};
  final Map<String, ({String dir, String name})> _byId = {};
  int _nextId = 1;
  int clock = 1000;

  /// Counts of calls, to assert that callers do not hammer the drive.
  int listCalls = 0;
  int readCalls = 0;
  int writeCalls = 0;

  @override
  Future<List<BlobInfo>> list(String dir) async {
    listCalls++;
    return [
      for (final e in (_dirs[dir] ?? const {}).entries)
        BlobInfo(
          id: e.value.id,
          name: e.key,
          size: e.value.data.length,
          modifiedMs: e.value.modifiedMs,
        ),
    ];
  }

  @override
  Future<Uint8List> readById(String id) async {
    readCalls++;
    final loc = _byId[id];
    if (loc == null) throw const FilenException('NOT_FOUND', 'no such blob');
    return Uint8List.fromList(_dirs[loc.dir]![loc.name]!.data);
  }

  @override
  Future<BlobInfo> write(String dir, String name, Uint8List data) async {
    writeCalls++;
    final files = _dirs.putIfAbsent(dir, () => {});
    if (files.containsKey(name)) {
      // Real Filen replaces by name; the callers must never rely on that.
      throw StateError('blob $dir/$name already exists');
    }
    final id = 'blob-${_nextId++}';
    clock += 1000;
    files[name] = (id: id, data: Uint8List.fromList(data), modifiedMs: clock);
    _byId[id] = (dir: dir, name: name);
    return BlobInfo(id: id, name: name, size: data.length, modifiedMs: clock);
  }

  @override
  Future<void> deleteById(String id) async {
    final loc = _byId.remove(id);
    if (loc != null) _dirs[loc.dir]?.remove(loc.name);
  }

  /// Names currently stored in [dir] (test helper).
  List<String> names(String dir) => (_dirs[dir]?.keys.toList() ?? [])..sort();
}
