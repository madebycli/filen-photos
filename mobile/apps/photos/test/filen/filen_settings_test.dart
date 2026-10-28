import 'package:flutter_test/flutter_test.dart';
import 'package:photos/filen/filen_settings.dart';

void main() {
  final keys = ['a', 'b', 'c'];
  String b(bool v) => encodeSetting(v);

  test('encode/decode keeps the type', () {
    expect(decodeSetting(encodeSetting(true)), true);
    expect(decodeSetting(encodeSetting(3)), 3);
    expect(decodeSetting(encodeSetting(2.5)), 2.5);
    expect(decodeSetting(encodeSetting('x')), 'x');
    expect(decodeSetting(encodeSetting(['a', 'b'])), ['a', 'b']);
    expect(decodeSetting('{"t":"i","v":"no"}'), isNull);
  });

  test('first merge: cloud wins, local-only values are pushed', () {
    final m = mergeSettings(
      local: {'a': b(false), 'b': b(true)},
      remote: {'a': b(true)},
      snapshot: null,
      keys: keys,
    );
    expect(m.applyLocally, {'a': b(true)});
    expect(m.pushToCloud, {'b': b(true)});
    expect(m.snapshot, {'a': b(true), 'b': b(true)});
  });

  test('later merge: a local change is pushed, not overwritten', () {
    final m = mergeSettings(
      local: {'a': b(false)},
      remote: {'a': b(true)},
      snapshot: {'a': b(true)},
      keys: keys,
    );
    expect(m.applyLocally, isEmpty);
    expect(m.pushToCloud, {'a': b(false)});
    expect(m.snapshot, {'a': b(false)});
  });

  test('later merge: an unchanged local value takes the newer cloud value', () {
    final m = mergeSettings(
      local: {'a': b(true)},
      remote: {'a': b(false)},
      snapshot: {'a': b(true)},
      keys: keys,
    );
    expect(m.applyLocally, {'a': b(false)});
    expect(m.pushToCloud, isEmpty);
  });

  test('nothing to do when both sides agree; never deletes', () {
    final m = mergeSettings(
      local: {'a': b(true)},
      remote: {'a': b(true), 'c': b(true)},
      snapshot: {'a': b(true), 'b': b(true)},
      keys: keys,
    );
    expect(m.applyLocally, {'c': b(true)});
    expect(m.pushToCloud, isEmpty);
    expect(m.snapshot.containsKey('b'), false);
  });
}
