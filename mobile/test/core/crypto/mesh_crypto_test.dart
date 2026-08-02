// Mirrors backend/tests/test_mesh_crypto.py.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lifesearch_mobile/core/crypto/mesh_crypto.dart';
import 'package:lifesearch_mobile/core/crypto/sodium_provider.dart';
import 'package:sodium/sodium.dart';

void main() {
  late Sodium sodium;
  late MeshCrypto crypto;

  setUpAll(() async {
    sodium = await SodiumProvider.instance();
    crypto = MeshCrypto(sodium);
  });

  SecureKey randomKey() => sodium.secureRandom(meshKeyBytes);

  test('round trips', () {
    final key = randomKey();
    final plaintext = Uint8List.fromList(List.filled(91, 0x61)); // 'a' * 91

    final blob = crypto.encrypt(key, plaintext);
    expect(blob.length, equals(meshNonceBytes + plaintext.length + meshTagBytes));
    expect(crypto.decrypt(key, blob), equals(plaintext));

    key.dispose();
  });

  test('nonce is random per call', () {
    final key = randomKey();
    final message = Uint8List.fromList('same message'.codeUnits);

    final a = crypto.encrypt(key, message);
    final b = crypto.encrypt(key, message);
    expect(a, isNot(equals(b)));

    key.dispose();
  });

  test('wrong key fails closed', () {
    final key = randomKey();
    final wrongKey = randomKey();
    final blob = crypto.encrypt(key, Uint8List.fromList('secret'.codeUnits));

    expect(
      () => crypto.decrypt(wrongKey, blob),
      throwsA(isA<MeshCryptoException>()),
    );

    key.dispose();
    wrongKey.dispose();
  });

  test('tampered blob is rejected', () {
    final key = randomKey();
    final blob = crypto.encrypt(key, Uint8List.fromList('trust me'.codeUnits));
    blob[blob.length - 1] ^= 0xFF; // flip a bit in the auth tag

    expect(
      () => crypto.decrypt(key, blob),
      throwsA(isA<MeshCryptoException>()),
    );

    key.dispose();
  });

  test('truncated blob is rejected', () {
    final key = randomKey();
    expect(
      () => crypto.decrypt(key, Uint8List.fromList('short'.codeUnits)),
      throwsA(isA<MeshCryptoException>()),
    );
    key.dispose();
  });

  test('wrong key length is rejected', () {
    final tooShort = sodium.secureRandom(8);
    expect(
      () => crypto.encrypt(tooShort, Uint8List.fromList('message'.codeUnits)),
      throwsA(isA<MeshCryptoException>()),
    );
    tooShort.dispose();
  });
}
