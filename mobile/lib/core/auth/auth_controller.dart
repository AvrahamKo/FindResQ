/// Orchestrates the phone/OTP login flow and device enrolment.
///
/// Device registration is retry-safe by construction: the keypair is
/// generated and persisted to Secure Storage BEFORE any network call, so a
/// dropped connection or app kill between "generate key" and "confirm
/// registration" can never cause a second keypair to be created on retry --
/// the stored keypair is reused, only the challenge/register HTTP round
/// trip repeats. And if the backend actually completed the registration
/// but the confirmation never reached this device (the 409 "already
/// registered to you" case -- see `routes/devices.py`), that is treated as
/// success, not failure: this device's public key IS registered, we just
/// need to look up the id it was assigned.
library;

import 'dart:convert';

import 'package:sodium/sodium.dart';
import 'package:state_notifier/state_notifier.dart';

import '../api/api_client.dart';
import '../api/api_exception.dart';
import '../api/api_models.dart';
import '../crypto/device_identity.dart';
import '../storage/secure_storage_manager.dart';
import '../storage/stored_models.dart';
import 'auth_state.dart';

const String _platformName = 'android'; // TODO(Phase 5c): detect iOS too.

class AuthController extends StateNotifier<AuthState> {
  final ApiClient _api;
  final SecureStorageManager _storage;
  final DeviceIdentity _identity;
  final Sodium _sodium;

  // Explicit assignment rather than initializing formals (`this._api`):
  // that would force callers to pass underscore-prefixed named arguments
  // (`AuthController(_api: ...)`), leaking the private field names into
  // the public constructor API.
  AuthController({
    required ApiClient api,
    required SecureStorageManager storage,
    required DeviceIdentity identity,
    required Sodium sodium,
  }) : _api = api,
       _storage = storage,
       _identity = identity,
       _sodium = sodium,
       super(const AuthUnknown());

  /// Called once at app start. Restores a signed-in session from Secure
  /// Storage without a network round trip -- an unexpired local account
  /// token is trusted until the next API call proves otherwise, so the app
  /// can show useful UI even when opened offline.
  Future<void> restore() async {
    final account = await _storage.loadAccount();
    if (account == null || account.isExpired) {
      state = const AuthSignedOut();
      return;
    }

    final identity = await _storage.loadDeviceIdentity();
    if (identity?.deviceId == null) {
      // Signed in, but device enrolment never finished -- finish it now
      // rather than leaving the user stuck with no way forward.
      await _ensureDeviceRegistered(account);
      return;
    }

    state = AuthSignedIn(
      user: UserInfo(
        id: account.userId,
        phoneE164: account.phoneE164,
        displayName: account.displayName,
        verificationStatus: 'unverified',
      ),
      deviceId: identity!.deviceId!,
    );
  }

  Future<void> requestOtp(String phoneE164) async {
    state = AuthRequestingOtp(phoneE164);
    try {
      final result = await _api.requestOtp(phoneE164);
      state = AuthOtpSent(
        phoneE164: phoneE164,
        challengeId: result.challengeId,
        expiresAt: result.expiresAt,
        devCode: result.devCode,
      );
    } on ApiException catch (e) {
      state = AuthFailed(message: e.message, previous: const AuthSignedOut());
    }
  }

  Future<void> verifyOtp(String code, {String displayName = ''}) async {
    final current = state;
    if (current is! AuthOtpSent) return;

    state = AuthVerifyingOtp(
      phoneE164: current.phoneE164,
      challengeId: current.challengeId,
    );

    try {
      final result = await _api.verifyOtp(
        challengeId: current.challengeId,
        code: code,
        displayName: displayName,
      );
      await _storage.saveAccount(
        StoredAccount(
          accessToken: result.accessToken,
          expiresAt: result.expiresAt,
          userId: result.user.id,
          phoneE164: result.user.phoneE164,
          displayName: result.user.displayName,
        ),
      );
      await _ensureDeviceRegistered(
        StoredAccount(
          accessToken: result.accessToken,
          expiresAt: result.expiresAt,
          userId: result.user.id,
          phoneE164: result.user.phoneE164,
          displayName: result.user.displayName,
        ),
      );
    } on ApiException catch (e) {
      state = AuthFailed(message: e.message, previous: current);
    }
  }

  Future<void> _ensureDeviceRegistered(StoredAccount account) async {
    state = const AuthRegisteringDevice();

    var identity = await _storage.loadDeviceIdentity();
    if (identity == null) {
      identity = _generateAndPersistKeypair();
      await _storage.saveDeviceIdentity(identity);
    }

    if (identity.deviceId != null) {
      _signIn(account, identity.deviceId!);
      return;
    }

    try {
      final device = await _registerDevice(account.accessToken, identity);
      await _storage.saveDeviceIdentity(
        identity.withRegistration(deviceId: device.id, wireId: device.wireId),
      );
      _signIn(account, device.id);
    } on ApiException catch (e) {
      if (e.isDuplicateDeviceRegistration) {
        final device = await _recoverDeviceAfterConflict(
          account.accessToken,
          identity.publicKeyBase64,
        );
        if (device != null) {
          await _storage.saveDeviceIdentity(
            identity.withRegistration(deviceId: device.id, wireId: device.wireId),
          );
          _signIn(account, device.id);
          return;
        }
      }
      state = AuthFailed(message: e.message, previous: const AuthSignedOut());
    }
  }

  StoredDeviceIdentity _generateAndPersistKeypair() {
    final pair = _identity.generateKeyPair();
    final identity = StoredDeviceIdentity(
      publicKeyBase64: pair.publicKeyBase64,
      secretKeyBase64: base64Encode(pair.secretKey.extractBytes()),
    );
    pair.dispose();
    return identity;
  }

  Future<DeviceInfo> _registerDevice(
    String accountToken,
    StoredDeviceIdentity identity,
  ) async {
    final challenge = await _api.createDeviceKeyChallenge(accountToken);
    final signatureBase64 = _signChallengeNonce(
      identity,
      challenge.nonceBase64,
    );
    return _api.registerDevice(
      accountToken: accountToken,
      challengeId: challenge.challengeId,
      publicKeyBase64: identity.publicKeyBase64,
      signatureBase64: signatureBase64,
      platform: _platformName,
    );
  }

  String _signChallengeNonce(StoredDeviceIdentity identity, String nonceB64) {
    final secretKey = _sodium.secureCopy(
      base64Decode(identity.secretKeyBase64),
    );
    try {
      final signature = _identity.sign(secretKey, base64Decode(nonceB64));
      return base64Encode(signature);
    } finally {
      secretKey.dispose();
    }
  }

  /// The 409 "already registered to you" path: the backend already has a
  /// device row for this public key (perhaps registration succeeded on a
  /// previous attempt whose response never reached this device). Find that
  /// device via the list endpoint rather than treating this as fatal.
  Future<DeviceInfo?> _recoverDeviceAfterConflict(
    String accountToken,
    String publicKeyBase64,
  ) async {
    final devices = await _api.listDevices(accountToken);
    for (final device in devices) {
      if (device.publicKeyBase64 == publicKeyBase64) {
        return device;
      }
    }
    return null;
  }

  void _signIn(StoredAccount account, String deviceId) {
    state = AuthSignedIn(
      user: UserInfo(
        id: account.userId,
        phoneE164: account.phoneE164,
        displayName: account.displayName,
        verificationStatus: 'unverified',
      ),
      deviceId: deviceId,
    );
  }

  Future<void> signOut() async {
    await _storage.clearAll();
    state = const AuthSignedOut();
  }
}
