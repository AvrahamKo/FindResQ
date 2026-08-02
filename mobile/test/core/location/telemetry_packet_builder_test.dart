// Verifies TelemetryPacketBuilder produces exactly the plaintext shape the
// backend's ingest pipeline expects: pack(point) || sign(payload), then
// XChaCha20-Poly1305 encrypted. Mirrors the layout assertion in
// backend/app/ingest/pipeline.py's `_EXPECTED_PLAINTEXT_BYTES`.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lifesearch_mobile/core/crypto/device_identity.dart';
import 'package:lifesearch_mobile/core/crypto/mesh_crypto.dart';
import 'package:lifesearch_mobile/core/crypto/sodium_provider.dart';
import 'package:lifesearch_mobile/core/crypto/wire_format.dart';
import 'package:lifesearch_mobile/core/location/location_sample.dart';
import 'package:lifesearch_mobile/core/location/telemetry_packet_builder.dart';
import 'package:sodium/sodium.dart';

const _expectedPlaintextBytes = payloadBytes + ed25519SignatureBytes;

LocationSample _sample({
  double latitude = 31.771959,
  double longitude = 35.217018,
  double accuracyM = 6.5,
  double speedMps = 0.8,
  int recordedAtMs = 1700000000456,
  bool isMocked = false,
}) => LocationSample(
  latitude: latitude,
  longitude: longitude,
  accuracyM: accuracyM,
  speedMps: speedMps,
  recordedAtMs: recordedAtMs,
  isMocked: isMocked,
);

void main() {
  late Sodium sodium;
  late DeviceIdentity identity;
  late MeshCrypto crypto;
  late TelemetryPacketBuilder builder;

  setUpAll(() async {
    sodium = await SodiumProvider.instance();
    identity = DeviceIdentity(sodium);
    crypto = MeshCrypto(sodium);
    builder = TelemetryPacketBuilder(identity, crypto);
  });

  test('produces a blob that decrypts to payload || signature, 91 bytes', () {
    expect(_expectedPlaintextBytes, equals(91));

    final devicePair = identity.generateKeyPair();
    final sectorKey = sodium.secureRandom(meshKeyBytes);

    final blob = builder.build(
      wireId: 42,
      deviceSecretKey: devicePair.secretKey,
      sectorKey: sectorKey,
      sample: _sample(),
      batteryPct: 73,
    );

    // nonce || plaintext-sized-ciphertext || tag
    expect(
      blob.length,
      equals(meshNonceBytes + _expectedPlaintextBytes + meshTagBytes),
    );

    final plaintext = crypto.decrypt(sectorKey, blob);
    expect(plaintext.length, equals(_expectedPlaintextBytes));

    final payloadBytesSlice = Uint8List.sublistView(plaintext, 0, payloadBytes);
    final signatureSlice = Uint8List.sublistView(plaintext, payloadBytes);
    expect(signatureSlice.length, equals(ed25519SignatureBytes));

    final unpacked = unpackPointPayload(payloadBytesSlice);
    expect(unpacked.wireId, equals(42));
    expect(unpacked.batteryPct, equals(73));
    expect(unpacked.lat, closeTo(31.771959, 1e-6));
    expect(unpacked.lng, closeTo(35.217018, 1e-6));

    expect(
      identity.verify(devicePair.publicKey, payloadBytesSlice, signatureSlice),
      isTrue,
    );

    devicePair.dispose();
    sectorKey.dispose();
  });

  test('a signature from a different device does not verify', () {
    final owner = identity.generateKeyPair();
    final impostor = identity.generateKeyPair();
    final sectorKey = sodium.secureRandom(meshKeyBytes);

    final blob = builder.build(
      wireId: 1,
      deviceSecretKey: impostor.secretKey,
      sectorKey: sectorKey,
      sample: _sample(),
      batteryPct: 50,
    );

    final plaintext = crypto.decrypt(sectorKey, blob);
    final payloadBytesSlice = Uint8List.sublistView(plaintext, 0, payloadBytes);
    final signatureSlice = Uint8List.sublistView(plaintext, payloadBytes);

    expect(
      identity.verify(owner.publicKey, payloadBytesSlice, signatureSlice),
      isFalse,
    );

    owner.dispose();
    impostor.dispose();
    sectorKey.dispose();
  });

  test('wrong sector key fails closed', () {
    final devicePair = identity.generateKeyPair();
    final sectorKey = sodium.secureRandom(meshKeyBytes);
    final wrongKey = sodium.secureRandom(meshKeyBytes);

    final blob = builder.build(
      wireId: 1,
      deviceSecretKey: devicePair.secretKey,
      sectorKey: sectorKey,
      sample: _sample(),
      batteryPct: 50,
    );

    expect(
      () => crypto.decrypt(wrongKey, blob),
      throwsA(isA<MeshCryptoException>()),
    );

    devicePair.dispose();
    sectorKey.dispose();
    wrongKey.dispose();
  });

  test('two packets for the same sample never produce the same blob', () {
    // Different nonce per encrypt call -- same guarantee MeshCrypto itself
    // gives, just verified end-to-end through the packet builder.
    final devicePair = identity.generateKeyPair();
    final sectorKey = sodium.secureRandom(meshKeyBytes);
    final sample = _sample();

    final a = builder.build(
      wireId: 1,
      deviceSecretKey: devicePair.secretKey,
      sectorKey: sectorKey,
      sample: sample,
      batteryPct: 50,
    );
    final b = builder.build(
      wireId: 1,
      deviceSecretKey: devicePair.secretKey,
      sectorKey: sectorKey,
      sample: sample,
      batteryPct: 50,
    );

    expect(a, isNot(equals(b)));
    expect(base64Encode(a), isNot(equals(base64Encode(b))));

    devicePair.dispose();
    sectorKey.dispose();
  });
}
