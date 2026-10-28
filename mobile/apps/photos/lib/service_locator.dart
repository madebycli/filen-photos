import "package:ente_feature_flag/ente_feature_flag.dart";
import "package:package_info_plus/package_info_plus.dart";
import "package:photos/core/event_bus.dart";
import "package:photos/events/ml_consent_changed_event.dart";
import "package:photos/services/backup_preference_service.dart";
import "package:photos/services/collections_service.dart";
import "package:photos/services/entity_service.dart";
import "package:photos/services/filedata/filedata_service.dart";
import "package:photos/services/location_service.dart";
import "package:photos/services/machine_learning/compute_controller.dart";
import "package:photos/services/machine_learning/ml_decryption_record_store.dart";
import "package:photos/services/magic_cache_service.dart";
import "package:photos/services/memories_cache_service.dart";
import "package:photos/services/permission/service.dart";
import "package:photos/services/rituals/rituals_service.dart";
import "package:photos/services/smart_albums_service.dart";
import "package:photos/services/smart_memories_service.dart";
import "package:photos/services/sync/trash_sync_service.dart";
import "package:photos/services/text_embeddings_cache_service.dart";
import "package:photos/services/wake_lock_service.dart";
import "package:photos/services/wrapped/wrapped_cache_service.dart";
import "package:photos/services/wrapped/wrapped_service.dart";
import "package:photos/settings/backup_settings.dart";
import "package:photos/settings/local_settings.dart";
import "package:shared_preferences/shared_preferences.dart";

class ServiceLocator {
  late final SharedPreferences prefs;
  late final PackageInfo packageInfo;
  late final LocalSettings localSettings;
  late final BackupSettings backupSettings;
  late final EnteWakeLockService wakeLockService;
  late final MlDecryptionRecordStore mlDecryptionRecordStore;

  ServiceLocator._privateConstructor();

  static final ServiceLocator instance = ServiceLocator._privateConstructor();

  void init(SharedPreferences prefs, PackageInfo packageInfo) {
    this.prefs = prefs;
    this.packageInfo = packageInfo;
    localSettings = LocalSettings(prefs);
    backupSettings = BackupSettings(prefs);
    wakeLockService = EnteWakeLockService();
    mlDecryptionRecordStore = MlDecryptionRecordStore(prefs);
  }
}

FlagService? _flagService;

FlagService get flagService {
  _flagService ??= FlagService(ServiceLocator.instance.prefs);
  return _flagService!;
}

LocalSettings get localSettings => ServiceLocator.instance.localSettings;

BackupSettings get backupSettings => ServiceLocator.instance.backupSettings;

EnteWakeLockService get wakeLockService =>
    ServiceLocator.instance.wakeLockService;

MlDecryptionRecordStore get mlDecryptionRecordStore =>
    ServiceLocator.instance.mlDecryptionRecordStore;

// True when showing local-device photos instead of an Ente account. Network
// access may still be used.
bool get isLocalGalleryMode => localSettings.isLocalGalleryMode;

// Filen fork: consent and the map switch are plain local settings, with or without an account.
bool get hasGrantedMLConsent => flagService.hasGrantedMLConsent;

Future<void> setMLConsent(bool enabled) async {
  await flagService.setMLConsent(enabled);
  Bus.instance.fire(MLConsentChangedEvent(enabled));
}

bool get mapEnabled => flagService.mapEnabled;

Future<void> setMapEnabled(bool enabled) => flagService.setMapEnabled(enabled);

BackupPreferenceService? _backupPreferenceService;
BackupPreferenceService get backupPreferenceService {
  _backupPreferenceService ??= BackupPreferenceService(
    ServiceLocator.instance.prefs,
  );
  return _backupPreferenceService!;
}

EntityService? _entityService;

EntityService get entityService {
  _entityService ??= EntityService(ServiceLocator.instance.prefs);
  return _entityService!;
}

TrashSyncService? _trashSyncService;
TrashSyncService get trashSyncService {
  _trashSyncService ??= TrashSyncService(ServiceLocator.instance.prefs);
  return _trashSyncService!;
}

LocationService? _locationService;
LocationService get locationService {
  _locationService ??= LocationService();
  return _locationService!;
}

MagicCacheService? _magicCacheService;
MagicCacheService get magicCacheService {
  _magicCacheService ??= MagicCacheService(ServiceLocator.instance.prefs);
  return _magicCacheService!;
}

MemoriesCacheService? _memoriesCacheService;
MemoriesCacheService get memoriesCacheService {
  _memoriesCacheService ??= MemoriesCacheService(ServiceLocator.instance.prefs);
  return _memoriesCacheService!;
}

SmartMemoriesService? _smartMemoriesService;
SmartMemoriesService get smartMemoriesService {
  _smartMemoriesService ??= SmartMemoriesService();
  return _smartMemoriesService!;
}

TextEmbeddingsCacheService? _textEmbeddingsCacheService;
TextEmbeddingsCacheService get textEmbeddingsCacheService {
  _textEmbeddingsCacheService ??= TextEmbeddingsCacheService.instance;
  return _textEmbeddingsCacheService!;
}

ComputeController? _computeController;
ComputeController get computeController {
  _computeController ??= ComputeController(localSettings);
  return _computeController!;
}

PermissionService? _permissionService;
PermissionService get permissionService {
  _permissionService ??= PermissionService(ServiceLocator.instance.prefs);
  return _permissionService!;
}

FileDataService? _fileDataService;
FileDataService get fileDataService {
  _fileDataService ??= FileDataService(ServiceLocator.instance.prefs);
  return _fileDataService!;
}

SmartAlbumsService? _smartAlbumsService;
SmartAlbumsService get smartAlbumsService {
  _smartAlbumsService ??= SmartAlbumsService();
  return _smartAlbumsService!;
}

RitualsService? _ritualsService;
RitualsService get ritualsService {
  _ritualsService ??= RitualsService.instance;
  return _ritualsService!;
}

CollectionsService? _collectionsService;
CollectionsService get collectionsService {
  _collectionsService ??= CollectionsService.instance;
  return _collectionsService!;
}

WrappedService? _wrappedService;
WrappedService get wrappedService {
  _wrappedService ??= WrappedService.instance;
  return _wrappedService!;
}

WrappedCacheService? _wrappedCacheService;
WrappedCacheService get wrappedCacheService {
  _wrappedCacheService ??= WrappedCacheService.instance;
  return _wrappedCacheService!;
}
