/// Domain-specific façade over [KeyValueStore]: knows WHAT gets stored
/// (device identity, account token, sector session) and under what keys,
/// but not HOW it's stored -- that's the injected store's job. See
/// key_value_store.dart for why the storage backend is injected rather
/// than hardcoded to `flutter_secure_storage`.
library;

import 'dart:convert';

import 'key_value_store.dart';
import 'stored_models.dart';

class SecureStorageManager {
  static const _deviceIdentityKey = 'lifesearch.device_identity.v1';
  static const _accountKey = 'lifesearch.account.v1';
  static const _sessionKey = 'lifesearch.session.v1';

  final KeyValueStore _store;

  const SecureStorageManager(this._store);

  // --- Device identity -------------------------------------------------

  Future<StoredDeviceIdentity?> loadDeviceIdentity() async {
    final raw = await _store.read(_deviceIdentityKey);
    if (raw == null) return null;
    return StoredDeviceIdentity.fromJson(
      jsonDecode(raw) as Map<String, dynamic>,
    );
  }

  Future<void> saveDeviceIdentity(StoredDeviceIdentity identity) =>
      _store.write(_deviceIdentityKey, jsonEncode(identity.toJson()));

  // --- Account (Phase 1 token) ------------------------------------------

  Future<StoredAccount?> loadAccount() async {
    final raw = await _store.read(_accountKey);
    if (raw == null) return null;
    return StoredAccount.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }

  Future<void> saveAccount(StoredAccount account) =>
      _store.write(_accountKey, jsonEncode(account.toJson()));

  Future<void> clearAccount() => _store.delete(_accountKey);

  // --- Session (Phase 2/3: sector key + session token) ------------------

  Future<StoredSession?> loadSession() async {
    final raw = await _store.read(_sessionKey);
    if (raw == null) return null;
    return StoredSession.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }

  Future<void> saveSession(StoredSession session) =>
      _store.write(_sessionKey, jsonEncode(session.toJson()));

  /// Deletes the session -- and with it, the sector key. This is the
  /// client-side half of Q9's data-minimization design: once this is
  /// called, the sector's decryption key is gone from this device, full
  /// stop, regardless of whether the server-side session was also
  /// invalidated.
  Future<void> clearSession() => _store.delete(_sessionKey);

  /// Full teardown: wipes account, session, and device identity. The device
  /// would need to re-register (a new keypair) after this -- only intended
  /// for an explicit "sign out and forget this device" action, not routine
  /// session/event teardown (which is `clearSession` alone).
  Future<void> clearAll() => _store.deleteAll();
}
