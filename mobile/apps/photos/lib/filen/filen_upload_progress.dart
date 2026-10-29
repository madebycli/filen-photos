import 'dart:async';
import 'dart:collection';

import 'package:filen_sdk/filen_sdk.dart';

/// How far the running backup is, from what the Filen SDK reports while it sends a file: the
/// percent of the run (finished files plus the fraction of the files in flight), the upload speed
/// and a callback per file for Ente's per-photo progress in the backup status screen.
class FilenUploadProgress {
  FilenUploadProgress._({Stream<({String id, int bytes})>? source}) {
    // Lives as long as the app, like the singleton itself.
    // ignore: cancel_subscriptions
    (source ?? FilenSdk.instance.uploadProgress).listen(_onBytes);
  }

  static final instance = FilenUploadProgress._();

  /// For tests: a tracker fed from [source] instead of the SDK.
  factory FilenUploadProgress.forTest(
    Stream<({String id, int bytes})> source,
  ) => FilenUploadProgress._(source: source);

  static const _speedWindow = Duration(seconds: 5);

  final _sent = <String, int>{};
  final _size = <String, int>{};
  final _onFileProgress = <String, void Function(int sent, int total)>{};
  final _samples = Queue<({DateTime at, int bytes})>();
  final _changes = StreamController<void>.broadcast();
  int _completed = 0;
  int _total = 0;
  DateTime _lastChange = DateTime.fromMillisecondsSinceEpoch(0);

  /// Fires (at most twice a second) when the numbers below changed.
  Stream<void> get changes => _changes.stream;

  /// A new run of uploads with [total] files.
  void begin(int total) {
    _completed = 0;
    _total = total;
    _sent.clear();
    _size.clear();
    _onFileProgress.clear();
    _samples.clear();
    _changes.add(null);
  }

  /// [onProgress] gets the bytes sent so far and the file's size.
  void fileStarted(
    String id,
    int size, {
    void Function(int sent, int total)? onProgress,
  }) {
    _sent[id] = 0;
    _size[id] = size;
    if (onProgress != null) {
      _onFileProgress[id] = onProgress;
    } else {
      _onFileProgress.remove(id);
    }
  }

  /// The file is no longer in flight (sent or given up).
  void fileEnded(String id) {
    _sent.remove(id);
    _size.remove(id);
    _onFileProgress.remove(id);
  }

  /// One more file of this run is done.
  void fileCounted() {
    _completed++;
    _changes.add(null);
  }

  void end() {
    _total = 0;
    _completed = 0;
    _sent.clear();
    _size.clear();
    _onFileProgress.clear();
    _samples.clear();
    _changes.add(null);
  }

  bool get active => _total > 0;
  int get completed => _completed;
  int get total => _total;

  /// Whole percent of the run, or null when no run is known.
  int? get percent {
    if (_total <= 0) return null;
    var inFlight = 0.0;
    for (final e in _sent.entries) {
      final size = _size[e.key] ?? 0;
      if (size > 0) inFlight += (e.value / size).clamp(0.0, 1.0);
    }
    return (((_completed + inFlight) / _total) * 100).clamp(0, 100).floor();
  }

  /// Bytes per second over the last few seconds, or null before anything was sent.
  double? get bytesPerSecond {
    final now = DateTime.now();
    while (_samples.isNotEmpty &&
        now.difference(_samples.first.at) > _speedWindow) {
      _samples.removeFirst();
    }
    if (_samples.isEmpty) return null;
    final sum = _samples.fold<int>(0, (a, s) => a + s.bytes);
    final span = now.difference(_samples.first.at).inMilliseconds;
    // Less than a second of data would show wild numbers.
    return sum / (span < 1000 ? 1000 : span) * 1000;
  }

  void _onBytes(({String id, int bytes}) e) {
    final sent = _sent[e.id];
    if (sent == null) return;
    final now = DateTime.now();
    _sent[e.id] = sent + e.bytes;
    _samples.addLast((at: now, bytes: e.bytes));
    _onFileProgress[e.id]?.call(sent + e.bytes, _size[e.id] ?? 0);
    if (now.difference(_lastChange) < const Duration(milliseconds: 500)) return;
    _lastChange = now;
    _changes.add(null);
  }
}
