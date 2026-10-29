import 'package:flutter_test/flutter_test.dart';
import 'package:photos/filen/filen_media_mapper.dart';

int _ms(int y, int m, int d, [int h = 12]) =>
    DateTime(y, m, d, h).millisecondsSinceEpoch;

void main() {
  group('captureTimeMicros', () {
    test(
      'desktop copy: old modified time beats the copy day as created time',
      () {
        final t = captureTimeMicros(
          name: 'DSC00123.JPG',
          createdMs: _ms(2025, 11, 3),
          modifiedMs: _ms(2014, 6, 7),
        );
        expect(t, _ms(2014, 6, 7) * 1000);
      },
    );

    test('a missing created time falls back to the modified time', () {
      final t = captureTimeMicros(
        name: 'a.jpg',
        createdMs: null,
        modifiedMs: _ms(2019, 1, 2),
      );
      expect(t, _ms(2019, 1, 2) * 1000);
    });

    test('the date in the file name wins when it names another day', () {
      final t = captureTimeMicros(
        name: 'IMG_20140512_101500.jpg',
        createdMs: _ms(2025, 11, 3),
        modifiedMs: _ms(2025, 11, 3),
      );
      final d = DateTime.fromMicrosecondsSinceEpoch(t);
      expect([d.year, d.month, d.day], [2014, 5, 12]);
    });

    test('the file time is kept when the name names the same day', () {
      final modified = _ms(2014, 5, 12, 10);
      final t = captureTimeMicros(
        name: 'IMG_20140512_101500.jpg',
        createdMs: modified,
        modifiedMs: modified,
      );
      expect(t, modified * 1000);
    });

    test('names without a date change nothing', () {
      final t = captureTimeMicros(
        name: 'holiday.jpg',
        createdMs: _ms(2020, 3, 4),
        modifiedMs: _ms(2021, 3, 4),
      );
      expect(t, _ms(2020, 3, 4) * 1000);
    });
  });
}
