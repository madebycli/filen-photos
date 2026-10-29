import 'dart:async';
import 'dart:typed_data';

import 'package:filen_sdk/filen_sdk.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photos/filen/state/blob_store.dart';

/// A preview someone is looking at must not wait behind the state folder's background work.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('urgent reads go ahead of queued background reads', () async {
    const channel = MethodChannel('test/filen_blob_priority');
    final started = <String>[];
    final gates = <String, Completer<void>>{};
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          final id = (call.arguments as Map)['uuid'] as String;
          started.add(id);
          await (gates[id] = Completer<void>()).future;
          return Uint8List(1);
        });
    final store = FilenDriveBlobStore(
      libraryRootUuid: () async => 'root',
      sdk: FilenSdk(channel: channel),
      concurrency: 1,
    );

    final first = store.readById('first');
    await Future<void>.delayed(Duration.zero);
    final background1 = store.readById('background1');
    final background2 = store.readById('background2');
    final urgent = store.readById('urgent', urgent: true);
    await Future<void>.delayed(Duration.zero);
    expect(started, ['first']);

    gates['first']!.complete();
    await first;
    await Future<void>.delayed(Duration.zero);
    expect(started, ['first', 'urgent']);

    gates['urgent']!.complete();
    await urgent;
    await Future<void>.delayed(Duration.zero);
    gates['background1']!.complete();
    await background1;
    await Future<void>.delayed(Duration.zero);
    gates['background2']!.complete();
    await background2;
    expect(started, ['first', 'urgent', 'background1', 'background2']);
  });
}
