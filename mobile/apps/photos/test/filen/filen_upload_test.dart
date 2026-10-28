import 'package:flutter_test/flutter_test.dart';
import 'package:photos/filen/filen_upload.dart';

void main() {
  group('freeFilenName', () {
    test('keeps a free name', () {
      expect(freeFilenName('IMG_1.jpg', {'IMG_2.jpg'}), 'IMG_1.jpg');
    });

    test('never reuses a taken name (Filen would replace that file)', () {
      expect(freeFilenName('IMG_1.jpg', {'IMG_1.jpg'}), 'IMG_1 (2).jpg');
      expect(
        freeFilenName('IMG_1.jpg', {'IMG_1.jpg', 'IMG_1 (2).jpg'}),
        'IMG_1 (3).jpg',
      );
    });

    test('handles names without extension and dotfiles', () {
      expect(freeFilenName('photo', {'photo'}), 'photo (2)');
      expect(freeFilenName('.hidden', {'.hidden'}), '.hidden (2)');
    });
  });
}
