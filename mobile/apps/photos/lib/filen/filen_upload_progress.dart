import 'package:filen_sdk/filen_sdk.dart';
import 'package:photos/core/event_bus.dart';
import 'package:photos/events/sync_status_update_event.dart';

/// How far the running backup is, in percent, from what the Filen SDK reports while it sends a
/// file: finished files plus the fraction of the files in flight, out of the files of this run.
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

  final _sent = <String, int>{};
  final _size = <String, int>{};
  int _completed = 0;
  int _total = 0;
  DateTime _lastEvent = DateTime.fromMillisecondsSinceEpoch(0);

  /// A new run of uploads with [total] files.
  void begin(int total) {
    _completed = 0;
    _total = total;
    _sent.clear();
    _size.clear();
  }

  void fileStarted(String id, int size) {
    _sent[id] = 0;
    _size[id] = size;
  }

  /// The file is no longer in flight (sent or given up).
  void fileEnded(String id) {
    _sent.remove(id);
    _size.remove(id);
  }

  /// One more file of this run is done (the status bar's "x of y").
  void fileCounted() => _completed++;

  void end() {
    _total = 0;
    _completed = 0;
    _sent.clear();
    _size.clear();
  }

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

  void _onBytes(({String id, int bytes}) e) {
    if (!_sent.containsKey(e.id)) return;
    _sent[e.id] = _sent[e.id]! + e.bytes;
    // At most twice a second: enough to look alive, not enough to rebuild the UI per chunk.
    final now = DateTime.now();
    if (now.difference(_lastEvent) < const Duration(milliseconds: 500)) return;
    _lastEvent = now;
    if (_total > 0) {
      Bus.instance.fire(
        SyncStatusUpdate(
          SyncStatus.inProgress,
          completed: _completed,
          total: _total,
        ),
      );
    }
  }
}
