/// Ed25519 device identity: keypair generation, signing, and the base64
/// encoding used on the wire. Mirrors `backend/app/security/signatures.py`.
///
/// The keypair is generated once, on-device, at install time, and the
/// private key never leaves the device (see the architecture review's
/// proof-of-possession design in `backend/migrations/0002_auth.sql` and
/// `routes/devices.py`). This module only ever signs; verification is the
/// server's job.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:sodium/sodium.dart';

const int ed25519PublicKeyBytes = 32;
const int ed25519SignatureBytes = 64;

class DeviceKeyPair {
  final Uint8List publicKey;
  final SecureKey secretKey;

  const DeviceKeyPair({required this.publicKey, required this.secretKey});

  String get publicKeyBase64 => base64Encode(publicKey);

  void dispose() => secretKey.dispose();
}

class DeviceIdentity {
  final Sodium _sodium;

  const DeviceIdentity(this._sodium);

  /// Generates a fresh Ed25519 keypair. Called once, at install time; the
  /// resulting [DeviceKeyPair.secretKey] is meant to be persisted in
  /// platform Secure Storage (Keychain/Keystore) and never transmitted.
  DeviceKeyPair generateKeyPair() {
    final KeyPair pair = _sodium.crypto.sign.keyPair();
    return DeviceKeyPair(publicKey: pair.publicKey, secretKey: pair.secretKey);
  }

  /// Signs [message] with [secretKey], producing a detached 64-byte
  /// signature -- the same `crypto_sign_detached` the backend verifies via
  /// PyNaCl's `VerifyKey.verify`.
  Uint8List sign(SecureKey secretKey, Uint8List message) {
    return _sodium.crypto.sign.detached(
      message: message,
      secretKey: secretKey,
    );
  }

  /// Local verification, for round-trip testing. Production verification
  /// happens server-side; the device never needs to verify its own
  /// signatures in normal operation.
  bool verify(Uint8List publicKey, Uint8List message, Uint8List signature) {
    if (publicKey.length != ed25519PublicKeyBytes) return false;
    if (signature.length != ed25519SignatureBytes) return false;
    try {
      return _sodium.crypto.sign.verifyDetached(
        message: message,
        signature: signature,
        publicKey: publicKey,
      );
    } on SodiumException {
      return false;
    }
  }
}
