import 'package:ente_photos_platform/ente_photos_platform.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photos/filen/filen_battery.dart';
import 'package:photos/filen/filen_compress.dart';

void main() {
  group('sameUploadName', () {
    test('equal names match', () {
      expect(sameUploadName('IMG_1.jpg', 'IMG_1.jpg'), isTrue);
    });

    test('a HEIC photo that went up as JPEG matches its JPEG', () {
      expect(sameUploadName('IMG_1.HEIC', 'IMG_1.jpg'), isTrue);
      expect(sameUploadName('IMG_1.heif', 'IMG_1.jpg'), isTrue);
    });

    test('other differences do not match', () {
      expect(sameUploadName('IMG_1.png', 'IMG_1.jpg'), isFalse);
      expect(sameUploadName('IMG_1.heic', 'IMG_2.jpg'), isFalse);
      expect(sameUploadName('IMG_1.jpg', 'IMG_1.heic'), isFalse);
      expect(sameUploadName(null, 'IMG_1.jpg'), isFalse);
    });
  });

  group('batteryIsLow', () {
    DeviceBatterySnapshot battery(int? level, DeviceSignalStatus status) =>
        DeviceBatterySnapshot(status: status, levelPercent: level);

    test('below 15 percent', () {
      expect(batteryIsLow(battery(14, DeviceSignalStatus.available)), isTrue);
      expect(batteryIsLow(battery(15, DeviceSignalStatus.available)), isFalse);
      expect(batteryIsLow(battery(80, DeviceSignalStatus.available)), isFalse);
    });

    test('an unreadable battery never blocks the backup', () {
      expect(
        batteryIsLow(battery(null, DeviceSignalStatus.unsupported)),
        isFalse,
      );
    });
  });
}
