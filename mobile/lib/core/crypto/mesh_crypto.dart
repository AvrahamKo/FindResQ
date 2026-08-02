/// XChaCha20-Poly1305 for mesh/point payload encryption.
///
/// Mirrors `backend/app/security/mesh_crypto.py`. This uses the `sodium`
/// package's direct libsodium bindings -- the SAME native library the
/// Python backend calls via PyNaCl -- rather than a pure-Dart
/// reimplementation of the algorithm, which would introduce a second,
/// independently-maintained implementation of the same crypto and the
/// cross-implementation drift risk that comes with it.
///
/// Wire representation: `nonce (24 bytes) || ciphertext_with_tag`. The nonce
/// travels with the ciphertext as one opaque blob rather than a separate
/// field -- matching the Python side exactly.
library;

import 'dart:typed_data';

import 'package:sodium/sodium.dart';

const int meshKeyBytes = 32;
const int meshNonceBytes = 24;
const int meshTagBytes = 16;

class MeshCryptoException implements Exception {
  final String message;
  MeshCryptoException(this.message);

  @override
  String toString() => 'MeshCryptoException: $message';
}

class MeshCrypto {
  final Sodium _sodium;

  const MeshCrypto(this._sodium);

  Uint8List encrypt(SecureKey key, Uint8List plaintext) {
    if (key.length != meshKeyBytes) {
      throw MeshCryptoException('key must be $meshKeyBytes bytes');
    }

    final Uint8List nonce = _sodium.randombytes.buf(meshNonceBytes);
    final Uint8List ciphertext = _sodium.crypto.aeadXChaCha20Poly1305IETF
        .encrypt(message: plaintext, nonce: nonce, key: key);

    final Uint8List blob = Uint8List(nonce.length + ciphertext.length);
    blob.setRange(0, nonce.length, nonce);
    blob.setRange(nonce.length, blob.length, ciphertext);
    return blob;
  }

  Uint8List decrypt(SecureKey key, Uint8List blob) {
    if (key.length != meshKeyBytes) {
      throw MeshCryptoException('key must be $meshKeyBytes bytes');
    }
    if (blob.length < meshNonceBytes + meshTagBytes) {
      throw MeshCryptoException(
        'blob too short to contain a nonce and auth tag (${blob.length} bytes)',
      );
    }

    final Uint8List nonce = blob.sublist(0, meshNonceBytes);
    final Uint8List ciphertext = blob.sublist(meshNonceBytes);
    try {
      return _sodium.crypto.aeadXChaCha20Poly1305IETF.decrypt(
        cipherText: ciphertext,
        nonce: nonce,
        key: key,
      );
    } on SodiumException catch (e) {
      throw MeshCryptoException(
        'decryption failed -- wrong sector key, or the blob was tampered with ($e)',
      );
    }
  }
}
