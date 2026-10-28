import 'dart:convert';
import 'dart:math';

import 'package:filen_sdk/filen_sdk.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:logging/logging.dart';
import 'package:photos/core/configuration.dart';
import 'package:photos/core/event_bus.dart';
import 'package:photos/events/user_details_changed_event.dart';
import 'package:photos/filen/filen_ids.dart';
import 'package:photos/filen/filen_settings.dart';
import 'package:photos/filen/filen_state.dart';
import 'package:photos/filen/filen_sync.dart';
import 'package:photos/gateways/billing/models/subscription.dart';
import 'package:photos/models/user_details.dart';

/// Filen session handling for the fork. The SDK performs the login (including all key
/// derivation); this class only persists the resulting session in the platform keystore-backed
/// secure storage and tells Ente's [Configuration] that an account exists.
///
/// The user's password is never stored.
class FilenAccount {
  FilenAccount._();
  static final FilenAccount instance = FilenAccount._();

  static const _sessionKey = 'filen_session_v1';
  static final _logger = Logger('FilenAccount');

  final FilenSdk _sdk = FilenSdk.instance;
  final FlutterSecureStorage _storage = const FlutterSecureStorage();
  String? _photosRootUuid;

  /// True when the signed-in account is a Filen account.
  static bool get isActive =>
      Configuration.instance.getToken() == kFilenTokenMarker;

  /// Re-attaches the persisted session to the SDK (local only, no network access).
  /// Called on every process start, UI and background alike.
  Future<void> restoreSession() async {
    _logger.info(
      'Filen Photos start: Filen account active=$isActive, Filen SDK $kFilenSdkVersion',
    );
    if (!isActive) return;
    try {
      final session = await _storage.read(key: _sessionKey);
      if (session == null) {
        _logger.warning('Filen account active but no stored session');
        return;
      }
      await _sdk.restore(session);
      _logger.info('Filen session restored');
    } catch (e, s) {
      // Keep the account: a transient failure must not look like a logout.
      _logger.severe('Failed to restore Filen session', e, s);
    }
  }

  /// Throws [FilenException] (e.g. TWO_FACTOR_REQUIRED, BAD_CREDENTIALS).
  Future<FilenUserInfo> signIn({
    required String email,
    required String password,
    String? twoFactorCode,
  }) async {
    final session = await _sdk.login(
      email: email.trim(),
      password: password,
      twoFactorCode: twoFactorCode,
    );
    await _storage.write(key: _sessionKey, value: session);
    final info = await _sdk.userInfo();
    _logger.info(
      'Filen login ok: userId=${info.userId}, storage ${info.storageUsed}/${info.maxStorage} bytes',
    );

    final config = Configuration.instance;
    await config.setEmail(info.email);
    await config.setUserID(info.userId);
    // Ente expects a local master key to exist. Filen derives and holds its own keys inside
    // the SDK; this random key only satisfies Ente's "account is configured" checks.
    await config.setKey(base64.encode(_randomBytes(32)));
    // Last: setting the token flips the app into the signed-in state.
    await config.setToken(kFilenTokenMarker);
    return info;
  }

  /// Storage figures from Filen in the shape Ente's settings screens expect. Filen has no
  /// subscription objects here, so the plan is a placeholder that never expires.
  Future<UserDetails> userDetails() async {
    final info = await _sdk.userInfo();
    return UserDetails(
      info.email,
      info.storageUsed,
      0,
      0,
      0,
      Subscription(
        productID: 'filen',
        storage: info.maxStorage,
        originalTransactionID: '',
        paymentProvider: 'filen',
        expiryTime: DateTime(2100).microsecondsSinceEpoch,
        price: '',
        period: '',
      ),
      null,
      ProfileData(),
      null,
    );
  }

  UserDetails? _cachedDetails;

  /// Storage figures fetched earlier in this process, or null.
  UserDetails? getCachedUserDetails() => _cachedDetails;

  /// Fresh storage figures from Filen; remembered for [getCachedUserDetails].
  Future<UserDetails> getUserDetails() async {
    final details = await userDetails();
    _cachedDetails = details;
    Bus.instance.fire(UserDetailsChangedEvent());
    return details;
  }

  /// Signs out of Filen on this device (nothing is deleted from Filen) and returns to the first
  /// route, which shows the sign-in page again.
  Future<void> logout(BuildContext context) async {
    await Configuration.instance.logout();
    if (!context.mounted) return;
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  /// Drops the in-memory client. [Configuration.logout] already wiped secure storage.
  Future<void> onLogout() async {
    _photosRootUuid = null;
    _cachedDetails = null;
    FilenState.instance.reset();
    await FilenSettingsSync.reset();
    FilenSyncService.instance.reset();
    try {
      await _sdk.logout();
    } catch (e, s) {
      _logger.warning('Filen SDK logout failed', e, s);
    }
  }

  /// UUID of the photo library folder, created on first use.
  Future<String> photosRootUuid() async {
    return _photosRootUuid ??= await _sdk.findOrCreateRootChild(
      kFilenPhotosRootName,
    );
  }

  static List<int> _randomBytes(int n) {
    final r = Random.secure();
    return List<int>.generate(n, (_) => r.nextInt(256));
  }
}
