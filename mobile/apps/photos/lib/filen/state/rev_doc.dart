import 'dart:convert';
import 'dart:typed_data';

import 'package:photos/filen/state/blob_store.dart';

/// A JSON document that is "updated" by writing a new revision file and deleting old ones.
///
///   `<base>.r00000007-<writer>.json`
///
/// Readers take the highest revision (ties: the lexicographically larger writer id), so two devices
/// that write at the same moment never overwrite each other's file; one write simply wins. Callers
/// that need to merge (maps, sets) read-modify-write through [update].
class RevDocs {
  RevDocs(this.store, {required this.writerId, this.keep = 2});

  final FilenBlobStore store;

  /// Short, stable id of this installation; makes file names unique across devices.
  final String writerId;

  /// How many revisions to keep around after a successful write.
  final int keep;

  static final RegExp _pattern = RegExp(
    r'^(.+)\.r(\d{8})-([A-Za-z0-9]+)\.json$',
  );

  /// All revisions of [base] in [dir], newest first.
  static List<DocRevision> revisionsOf(String base, List<BlobInfo> files) {
    final found = <DocRevision>[];
    for (final f in files) {
      final m = _pattern.firstMatch(f.name);
      if (m == null || m.group(1) != base) continue;
      found.add(DocRevision(f, int.parse(m.group(2)!), m.group(3)!));
    }
    found.sort((a, b) {
      final byRev = b.revision.compareTo(a.revision);
      return byRev != 0 ? byRev : b.writer.compareTo(a.writer);
    });
    return found;
  }

  /// Distinct base names present in [files].
  static Set<String> basesOf(List<BlobInfo> files) {
    return {
      for (final f in files)
        if (_pattern.firstMatch(f.name) case final m?) m.group(1)!,
    };
  }

  /// The newest revision of [base], or null.
  Future<DocRevision?> latest(String dir, String base) async {
    final revs = revisionsOf(base, await store.list(dir));
    return revs.isEmpty ? null : revs.first;
  }

  Future<Map<String, dynamic>?> read(String dir, String base) async {
    final rev = await latest(dir, base);
    if (rev == null) return null;
    return _decode(await store.readById(rev.file.id));
  }

  /// Writes [json] as the next revision and prunes old ones. Returns the new revision.
  Future<DocRevision> write(
    String dir,
    String base,
    Map<String, dynamic> json, {
    List<BlobInfo>? knownFiles,
  }) async {
    final files = knownFiles ?? await store.list(dir);
    final revs = revisionsOf(base, files);
    final next = (revs.isEmpty ? 0 : revs.first.revision) + 1;
    final name = '$base.r${next.toString().padLeft(8, '0')}-$writerId.json';
    final written = await store.write(
      dir,
      name,
      Uint8List.fromList(utf8.encode(jsonEncode(json))),
    );
    for (final old in revs.skip(keep - 1)) {
      try {
        await store.deleteById(old.file.id);
      } catch (_) {
        // A leftover old revision is harmless; the newest one always wins.
      }
    }
    return DocRevision(written, next, writerId);
  }

  /// Read-modify-write. [change] receives the current document (empty when none) and returns the new
  /// one, or null to leave the document untouched.
  Future<Map<String, dynamic>?> update(
    String dir,
    String base,
    Map<String, dynamic>? Function(Map<String, dynamic> current) change,
  ) async {
    final files = await store.list(dir);
    final revs = revisionsOf(base, files);
    final current = revs.isEmpty
        ? <String, dynamic>{}
        : await _decode(await store.readById(revs.first.file.id));
    final next = change(current);
    if (next == null) return null;
    await write(dir, base, next, knownFiles: files);
    return next;
  }

  Future<Map<String, dynamic>> _decode(Uint8List bytes) async {
    final decoded = jsonDecode(utf8.decode(bytes));
    return decoded is Map<String, dynamic> ? decoded : <String, dynamic>{};
  }
}

class DocRevision {
  const DocRevision(this.file, this.revision, this.writer);
  final BlobInfo file;
  final int revision;
  final String writer;

  /// Changes whenever the document is rewritten; used to skip re-downloads.
  String get tag => '${file.id}@$revision-$writer';
}
