import 'dart:math';

import 'package:logging/logging.dart';
import 'package:photos/core/configuration.dart';
import 'package:photos/filen/filen_account.dart';
import 'package:photos/filen/state/blob_store.dart';
import 'package:photos/filen/state/collection_store.dart';
import 'package:photos/filen/state/entity_store.dart';
import 'package:photos/filen/state/meta_disk_cache.dart';
import 'package:photos/filen/state/meta_store.dart';
import 'package:photos/filen/state/ml_store.dart';
import 'package:photos/filen/state/rev_doc.dart';
import 'package:photos/filen/state/thumb_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _PrefsStorage implements StringStorage {
  _PrefsStorage(this._prefs);
  final SharedPreferences _prefs;

  @override
  String? read(String key) => _prefs.getString(key);

  @override
  Future<void> write(String key, String? value) async {
    if (value == null) {
      await _prefs.remove(key);
    } else {
      await _prefs.setString(key, value);
    }
  }
}

/// The app's cloud state on Filen (see `state/`): wires the stores to the real drive.
/// Created lazily after login; one instance per isolate.
class FilenState {
  FilenState._();
  static final FilenState instance = FilenState._();
  static final _logger = Logger('FilenState');

  Future<void>? _init;
  late FilenDriveBlobStore blobs;
  late RevDocs docs;
  late FilenMetaStore meta;
  MetaCache? _metaCache;
  late FilenCollectionStore collections;
  late FilenEntityStore entities;
  late FilenMlStore ml;
  late FilenThumbStore thumbs;

  /// Idempotent; safe to await from anywhere.
  Future<void> ensureInitialized() => _init ??= _initialize();

  Future<void> _initialize() async {
    final prefs = await SharedPreferences.getInstance();
    var writer = prefs.getString('filen_writer_id');
    if (writer == null) {
      const alphabet = 'abcdefghijklmnopqrstuvwxyz0123456789';
      final r = Random.secure();
      writer = String.fromCharCodes(
        List.generate(
          8,
          (_) => alphabet.codeUnitAt(r.nextInt(alphabet.length)),
        ),
      );
      await prefs.setString('filen_writer_id', writer);
    }
    blobs = FilenDriveBlobStore(
      libraryRootUuid: FilenAccount.instance.photosRootUuid,
    );
    docs = RevDocs(blobs, writerId: writer);
    _metaCache = MetaDiskCache(await FilenAccount.instance.photosRootUuid());
    meta = FilenMetaStore(docs, cache: _metaCache);
    collections = FilenCollectionStore(docs, _PrefsStorage(prefs));
    entities = FilenEntityStore(
      docs,
      ownerID: () => Configuration.instance.getUserID() ?? 0,
    );
    ml = FilenMlStore(blobs);
    thumbs = FilenThumbStore(blobs);
    _logger.info('Filen state ready (writer $writer)');
  }

  Future<void>? _pulling;

  /// Downloads what changed in the cloud state since the last call. Callers that arrive while a
  /// pull runs share it. [metaShards]: only the metadata shards that hold files of the library.
  Future<void> pull({Set<String>? metaShards}) =>
      _pulling ??= _pull(metaShards).whenComplete(() => _pulling = null);

  Future<void> _pull(Set<String>? metaShards) async {
    await ensureInitialized();
    final watch = Stopwatch()..start();
    await Future.wait([meta.pull(onlyShards: metaShards), collections.pull()]);
    _logger.info('Filen state pulled in ${watch.elapsedMilliseconds} ms');
  }

  /// Writes everything that is still queued (call when the app goes to the background).
  Future<void> flush() async {
    if (_init == null) return;
    await Future.wait([meta.flush(), collections.flush()]);
  }

  /// Forget everything (logout). Nothing is deleted from Filen.
  void reset() {
    if (_init != null) {
      blobs.reset();
    }
    _metaCache?.clear().ignore();
    _metaCache = null;
    _pulling = null;
    _init = null;
  }
}
