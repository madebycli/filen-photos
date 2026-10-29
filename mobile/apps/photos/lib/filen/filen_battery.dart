import 'package:ente_photos_platform/ente_photos_platform.dart';
import 'package:logging/logging.dart';
import 'package:photos/service_locator.dart';
import 'package:photos/settings/backup_settings.dart';

/// Filen's camera upload option "upload on low battery": unless it is on, the backup waits while
/// the battery is below [BackupSettings.lowBatteryPercent]. If the level cannot be read the backup
/// is not blocked.
Future<bool> backupBlockedByBattery({DeviceHealthSource? source}) async {
  if (backupSettings.shouldBackupOnLowBattery()) return false;
  try {
    final snapshot = await (source ?? DeviceHealthClient.instance)
        .getSnapshot()
        .timeout(const Duration(seconds: 5));
    if (batteryIsLow(snapshot.battery)) {
      Logger(
        'FilenBattery',
      ).info('Backup waits: battery at ${snapshot.battery.levelPercent} %');
      return true;
    }
  } catch (_) {
    // No reading, no blocking.
  }
  return false;
}

/// Below [BackupSettings.lowBatteryPercent]; an unreadable battery counts as fine.
bool batteryIsLow(DeviceBatterySnapshot battery) {
  final level = battery.levelPercent;
  return battery.status == DeviceSignalStatus.available &&
      level != null &&
      level < BackupSettings.lowBatteryPercent;
}
