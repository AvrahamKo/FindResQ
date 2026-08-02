/// Data persisted by [SecureStorageManager], each serialized as ONE JSON
/// blob under one storage key -- writing several related fields as
/// separate keys risks leaving inconsistent state if the app is killed
/// mid-write (e.g. a session token saved but its sector key not yet
/// written). One blob, one write, atomic from the app's point of view.
library;

class StoredDeviceIdentity {
  /// The device's own Ed25519 keypair, generated once at install time.
  final String publicKeyBase64;

  /// Raw Ed25519 secret key bytes (base64). The private key never leaves
  /// the device; this is the ONLY place it is ever persisted, and it lives
  /// in platform Secure Storage (Keychain/Keystore), not app-readable prefs.
  final String secretKeyBase64;

  /// Null until `POST /devices` has succeeded and assigned a backend id.
  /// Kept separate from the keypair's own lifecycle: the keypair must be
  /// generated and persisted BEFORE attempting registration, so a crash or
  /// dropped connection between generating the key and confirming
  /// registration doesn't cause a second keypair to be generated on retry.
  final String? deviceId;

  const StoredDeviceIdentity({
    required this.publicKeyBase64,
    required this.secretKeyBase64,
    this.deviceId,
  });

  StoredDeviceIdentity withDeviceId(String deviceId) => StoredDeviceIdentity(
    publicKeyBase64: publicKeyBase64,
    secretKeyBase64: secretKeyBase64,
    deviceId: deviceId,
  );

  Map<String, dynamic> toJson() => {
    'publicKeyBase64': publicKeyBase64,
    'secretKeyBase64': secretKeyBase64,
    'deviceId': deviceId,
  };

  factory StoredDeviceIdentity.fromJson(Map<String, dynamic> json) =>
      StoredDeviceIdentity(
        publicKeyBase64: json['publicKeyBase64'] as String,
        secretKeyBase64: json['secretKeyBase64'] as String,
        deviceId: json['deviceId'] as String?,
      );
}

/// The account-level token (Phase 1: proves "this phone number is mine").
/// No sector, no role, no key material -- see backend/app/security/tokens.py.
class StoredAccount {
  final String accessToken;
  final DateTime expiresAt;
  final String userId;
  final String phoneE164;
  final String displayName;

  const StoredAccount({
    required this.accessToken,
    required this.expiresAt,
    required this.userId,
    required this.phoneE164,
    required this.displayName,
  });

  bool get isExpired => DateTime.now().isAfter(expiresAt);

  Map<String, dynamic> toJson() => {
    'accessToken': accessToken,
    'expiresAt': expiresAt.toIso8601String(),
    'userId': userId,
    'phoneE164': phoneE164,
    'displayName': displayName,
  };

  factory StoredAccount.fromJson(Map<String, dynamic> json) => StoredAccount(
    accessToken: json['accessToken'] as String,
    expiresAt: DateTime.parse(json['expiresAt'] as String),
    userId: json['userId'] as String,
    phoneE164: json['phoneE164'] as String,
    displayName: json['displayName'] as String,
  );
}

/// The sector-scoped session (Phase 2/3): the session JWT plus the raw
/// sector key, delivered exactly once at claim time
/// (`POST /memberships/{id}/session`) and never re-fetchable from the
/// server after that -- so once this is deleted, that key is gone for
/// this device until a Lead/Commander re-approves and the device claims a
/// fresh session.
class StoredSession {
  final String accessToken;
  final DateTime expiresAt;
  final int keyEpoch;
  final String sectorKeyBase64;
  final String membershipId;
  final String sectorId;
  final String eventId;
  final String role;
  final String movementMode;

  const StoredSession({
    required this.accessToken,
    required this.expiresAt,
    required this.keyEpoch,
    required this.sectorKeyBase64,
    required this.membershipId,
    required this.sectorId,
    required this.eventId,
    required this.role,
    required this.movementMode,
  });

  bool get isExpired => DateTime.now().isAfter(expiresAt);

  Map<String, dynamic> toJson() => {
    'accessToken': accessToken,
    'expiresAt': expiresAt.toIso8601String(),
    'keyEpoch': keyEpoch,
    'sectorKeyBase64': sectorKeyBase64,
    'membershipId': membershipId,
    'sectorId': sectorId,
    'eventId': eventId,
    'role': role,
    'movementMode': movementMode,
  };

  factory StoredSession.fromJson(Map<String, dynamic> json) => StoredSession(
    accessToken: json['accessToken'] as String,
    expiresAt: DateTime.parse(json['expiresAt'] as String),
    keyEpoch: json['keyEpoch'] as int,
    sectorKeyBase64: json['sectorKeyBase64'] as String,
    membershipId: json['membershipId'] as String,
    sectorId: json['sectorId'] as String,
    eventId: json['eventId'] as String,
    role: json['role'] as String,
    movementMode: json['movementMode'] as String,
  );
}
