import "package:flutter/foundation.dart";
import "package:shared_preferences/shared_preferences.dart";

/// Filen fork: feature flags are local settings. Ente's version fetched them from, and wrote them
/// to, Ente's servers; this app has no such server, so the two user-facing switches (machine
/// learning consent and the map) are plain preferences and everything else is a constant.
class FlagService {
  static const String _mlConsentKey = "filen.ml_consent";
  static const String _mapEnabledKey = "filen.map_enabled";

  final SharedPreferences _prefs;

  FlagService(this._prefs);

  /// Experimental features of Ente's own builds are off, except in debug builds.
  bool get internalUser {
    final isDisabled = _prefs.getBool("ls.internal_user_disabled") ?? false;
    return kDebugMode && !isDisabled;
  }

  bool get internalOrBetaUser => internalUser;

  bool get isBetaUser => internalUser;

  bool get mapEnabled => _prefs.getBool(_mapEnabledKey) ?? false;

  Future<void> setMapEnabled(bool isEnabled) async {
    await _prefs.setBool(_mapEnabledKey, isEnabled);
  }

  /// Whether the user allowed on-device machine learning (faces, semantic search, ...).
  bool get hasGrantedMLConsent => _prefs.getBool(_mlConsentKey) ?? false;

  Future<void> setMLConsent(bool isEnabled) async {
    await _prefs.setBool(_mlConsentKey, isEnabled);
  }

  bool get enableVectorDb => hasGrantedMLConsent;

  bool get manualTagFileToPerson => hasGrantedMLConsent;

  bool get webGPUEnabled => true;

  bool get usearchForSearch => true;

  bool get usearchForSuggestions => true;

  bool get rustMlDb => false;

  bool get useNativeVideoEditor => true;

  bool get videoEditorSpeedEnabled => internalUser;

  bool get progressiveOriginalVideoPlayback => true;

  bool get facesTimeline => true;

  bool get ritualsFlag => true;

  bool get enableShareePin => false;

  bool get enableMLInBackground => true;

  bool get useRustForHeicDecoder => internalUser;

  bool get petEnabled => false;

  bool get qrFeatureEnabled => true;

  bool get ocrOverlayEnabled => true;

  bool get enableBgLocalUploadPriority => internalUser;

  bool get syncRecoveryDiagnostics => false;

  bool get mLHydrationStaleFileRecovery => false;
}
