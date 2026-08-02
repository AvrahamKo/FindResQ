// Mirrors telemetry_packet_builder_test.dart's shape: verifies
// ReportPacketBuilder produces exactly the plaintext shape the backend's
// report ingest pipeline expects.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lifesearch_mobile/core/crypto/device_identity.dart';
import 'package:lifesearch_mobile/core/crypto/mesh_crypto.dart';
import 'package:lifesearch_mobile/core/crypto/report_wire_format.dart';
import 'package:lifesearch_mobile/core/crypto/sodium_provider.dart';
import 'package:lifesearch_mobile/core/reports/report_packet_builder.dart';
import 'package:sodium/sodium.dart';

void main() {
  late Sodium sodium;
  late DeviceIdentity identity;
  late MeshCrypto crypto;
  late ReportPacketBuilder builder;

  setUpAll(() async {
    sodium = await SodiumProvider.instance();
    identity = DeviceIdentity(sodium);
    crypto = MeshCrypto(sodium);
    builder = ReportPacketBuilder(identity, crypto);
  });

  test('produces a blob that decrypts to payload || signature', () {
    final devicePair = identity.generateKeyPair();
    final sectorKey = sodium.secureRandom(meshKeyBytes);

    final blob = builder.build(
      wireId: 42,
      deviceSecretKey: devicePair.secretKey,
      sectorKey: sectorKey,
      recordedAtMs: 1700000000456,
      kind: 'hazard',
      lat: 31.771959,
      lng: 35.217018,
      note: 'Downed power line.',
    );

    final plaintext = crypto.decrypt(sectorKey, blob);
    final expectedPayloadLen =
        reportHeaderBytes + 'Downed power line.'.codeUnits.length;
    expect(plaintext.length, equals(expectedPayloadLen + ed25519SignatureBytes));

    final payloadBytes = Uint8List.sublistView(plaintext, 0, expectedPayloadLen);
    final signatureBytes = Uint8List.sublistView(plaintext, expectedPayloadLen);
    expect(signatureBytes.length, equals(ed25519SignatureBytes));

    final unpacked = unpackReportPayload(payloadBytes);
    expect(unpacked.wireId, equals(42));
    expect(unpacked.kind, equals('hazard'));
    expect(unpacked.note, equals('Downed power line.'));
    expect(unpacked.lat, closeTo(31.771959, 1e-6));
    expect(unpacked.lng, closeTo(35.217018, 1e-6));

    expect(
      identity.verify(devicePair.publicKey, payloadBytes, signatureBytes),
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
      recordedAtMs: 1700000000000,
      kind: 'medical',
      lat: 31.77,
      lng: 35.21,
      note: '',
    );

    final plaintext = crypto.decrypt(sectorKey, blob);
    final payloadLen = reportHeaderBytes;
    final payloadBytes = Uint8List.sublistView(plaintext, 0, payloadLen);
    final signatureBytes = Uint8List.sublistView(plaintext, payloadLen);

    expect(
      identity.verify(owner.publicKey, payloadBytes, signatureBytes),
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
      recordedAtMs: 1700000000000,
      kind: 'item_found',
      lat: 31.77,
      lng: 35.21,
      note: 'clue',
    );

    expect(
      () => crypto.decrypt(wrongKey, blob),
      throwsA(isA<MeshCryptoException>()),
    );

    devicePair.dispose();
    sectorKey.dispose();
    wrongKey.dispose();
  });

  test('rejects an unknown kind before doing any crypto work', () {
    final devicePair = identity.generateKeyPair();
    final sectorKey = sodium.secureRandom(meshKeyBytes);

    expect(
      () => builder.build(
        wireId: 1,
        deviceSecretKey: devicePair.secretKey,
        sectorKey: sectorKey,
        recordedAtMs: 1700000000000,
        kind: 'not_a_real_kind',
        lat: 31.77,
        lng: 35.21,
        note: '',
      ),
      throwsA(isA<ReportWireFormatException>()),
    );

    devicePair.dispose();
    sectorKey.dispose();
  });
}
