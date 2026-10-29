import "package:shared_preferences/shared_preferences.dart";

class BackupSettings {
  BackupSettings(this._preferences);

  static const _keyShouldBackupOverMobileData =
      "should_backup_over_mobile_data";
  static const _keyShouldBackupVideos = "should_backup_videos";

  // Filen fork: the upload options of Filen's own camera upload, next to Ente's.
  static const _keyCompressUploads = "filen.compress_uploads";
  static const _keyBackupOnLowBattery = "filen.upload_on_low_battery";
  static const _keyReuploadDeleted = "filen.reupload_deleted";

  final SharedPreferences _preferences;

  /// Re-encode JPEG/HEIC photos as JPEG (quality 80) before the upload when that is smaller.
  bool shouldCompressUploads() =>
      _preferences.getBool(_keyCompressUploads) ?? false;

  Future<void> setCompressUploads(bool value) =>
      _preferences.setBool(_keyCompressUploads, value);

  /// Whether the backup keeps going when the battery is below [lowBatteryPercent].
  bool shouldBackupOnLowBattery() =>
      _preferences.getBool(_keyBackupOnLowBattery) ?? false;

  Future<void> setBackupOnLowBattery(bool value) =>
      _preferences.setBool(_keyBackupOnLowBattery, value);

  static const lowBatteryPercent = 15;

  /// Whether a photo deleted from Filen is uploaded again from this phone. Off is Ente's
  /// behaviour: the deleted photo is remembered and skipped.
  bool shouldReuploadDeleted() =>
      _preferences.getBool(_keyReuploadDeleted) ?? false;

  Future<void> setReuploadDeleted(bool value) =>
      _preferences.setBool(_keyReuploadDeleted, value);

  bool shouldBackupOverMobileData() {
    return _preferences.getBool(_keyShouldBackupOverMobileData) ?? false;
  }

  Future<void> setBackupOverMobileData(bool value) async {
    await _preferences.setBool(_keyShouldBackupOverMobileData, value);
  }

  bool shouldBackupVideos() {
    return _preferences.getBool(_keyShouldBackupVideos) ?? true;
  }

  Future<void> setBackupVideos(bool value) async {
    await _preferences.setBool(_keyShouldBackupVideos, value);
  }
}
