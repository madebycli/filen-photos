import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:photos/filen/filen_upload_progress.dart';

void main() {
  test(
    'percent follows finished files and the bytes of the files in flight',
    () async {
      final bytes = StreamController<({String id, int bytes})>.broadcast();
      final progress = FilenUploadProgress.forTest(bytes.stream);
      expect(progress.percent, isNull);

      progress.begin(4);
      progress.fileCounted();
      progress.fileStarted('a', 100);
      bytes.add((id: 'a', bytes: 50));
      await Future<void>.delayed(Duration.zero);
      // 1 finished + half of one, out of 4 files.
      expect(progress.percent, 37);

      progress.fileEnded('a');
      progress.fileCounted();
      expect(progress.percent, 50);

      // Bytes of a file nobody started are ignored; the result stays within 0..100.
      bytes.add((id: 'unknown', bytes: 999));
      progress.fileStarted('b', 10);
      bytes.add((id: 'b', bytes: 99999));
      await Future<void>.delayed(Duration.zero);
      expect(progress.percent, 75);

      progress.end();
      expect(progress.percent, isNull);
    },
  );
}
