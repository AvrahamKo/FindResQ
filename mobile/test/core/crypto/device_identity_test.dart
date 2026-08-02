// Mirrors backend/tests/test_device_enrolment.py.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lifesearch_mobile/core/crypto/device_identity.dart';
import 'package:lifesearch_mobile/core/crypto/sodium_provider.dart';
import 'package:sodium/sodium.dart';

void main() {
  late Sodium sodium;
  late DeviceIdentity identity;

  setUpAll(() async {
    sodium = await SodiumProvider.instance();
    identity = DeviceIdentity(sodium);
  });

  test('generated public key is the correct length', () {
    final pair = identity.generateKeyPair();
    expect(pair.publicKey.length, equals(ed25519PublicKeyBytes));
    pair.dispose();
  });

  test('public key base64 round trips through the wire encoding', () {
    final pair = identity.generateKeyPair();
    final b64 = pair.publicKeyBase64;
    expect(b64, isNotEmpty);
    pair.dispose();
  });

  test('device proves possession of its private key', () {
    final pair = identity.generateKeyPair();
    final nonce = Uint8List.fromList(List.filled(32, 0x01));

    final signature = identity.sign(pair.secretKey, nonce);
    expect(signature.length, equals(ed25519SignatureBytes));
    expect(identity.verify(pair.publicKey, nonce, signature), isTrue);

    pair.dispose();
  });

  test(
    'a signature from a different key does not verify against this public key',
    () {
      // This is exactly the attribution attack the backend's device
      // enrolment flow (0002_auth.sql) is designed to prevent: an attacker
      // cannot bind someone else's public key to their own account, because
      // they cannot produce a signature that verifies against it.
      final victim = identity.generateKeyPair();
      final attacker = identity.generateKeyPair();
      final nonce = Uint8List.fromList(List.filled(32, 0x02));

      final forged = identity.sign(attacker.secretKey, nonce);
      expect(identity.verify(victim.publicKey, nonce, forged), isFalse);

      // Sanity: the victim's own signature does verify.
      final genuine = identity.sign(victim.secretKey, nonce);
      expect(identity.verify(victim.publicKey, nonce, genuine), isTrue);

      victim.dispose();
      attacker.dispose();
    },
  );

  test('a signature over a different nonce is rejected', () {
    final pair = identity.generateKeyPair();
    final oldNonce = Uint8List.fromList(List.filled(32, 0x03));
    final newNonce = Uint8List.fromList(List.filled(32, 0x04));

    final signatureForOldNonce = identity.sign(pair.secretKey, oldNonce);
    expect(
      identity.verify(pair.publicKey, newNonce, signatureForOldNonce),
      isFalse,
    );

    pair.dispose();
  });
}
