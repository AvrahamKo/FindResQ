// One-off tool: packs, signs, and encrypts a fixed test payload, then prints
// a JSON fixture. Used to prove the Dart and Python wire-format/crypto
// implementations actually interoperate, not just that each side's own
// tests pass independently. Run via `dart run tool/generate_interop_fixture.dart`.

import 'dart:convert';
import 'dart:typed_data';

import 'package:lifesearch_mobile/core/crypto/device_identity.dart';
import 'package:lifesearch_mobile/core/crypto/mesh_crypto.dart';
import 'package:lifesearch_mobile/core/crypto/sodium_provider.dart';
import 'package:lifesearch_mobile/core/crypto/wire_format.dart';

Future<void> main() async {
  final sodium = await SodiumProvider.instance();
  final identity = DeviceIdentity(sodium);
  final crypto = MeshCrypto(sodium);

  final pair = identity.generateKeyPair();

  final payload = PointPayload(
    wireId: 424242,
    recordedAtMs: 1780000000123,
    lat: 31.771959,
    lng: 35.217018,
    accuracyM: 6.5,
    speedMps: 1.35,
    batteryPct: 73,
    isMocked: false,
  );

  final packed = packPointPayload(payload);
  final signature = identity.sign(pair.secretKey, packed);
  final bundle = Uint8List(packed.length + signature.length);
  bundle.setRange(0, packed.length, packed);
  bundle.setRange(packed.length, bundle.length, signature);

  final sectorKey = sodium.secureRandom(meshKeyBytes);
  final blob = crypto.encrypt(sectorKey, bundle);

  final fixture = {
    'device_public_key_b64': base64Encode(pair.publicKey),
    'sector_key_b64': base64Encode(
      sectorKey.runUnlockedSync((data) => Uint8List.fromList(data)),
    ),
    'blob_b64': base64Encode(blob),
    'expected': {
      'wire_id': payload.wireId,
      'recorded_at_ms': payload.recordedAtMs,
      'lat': payload.lat,
      'lng': payload.lng,
      'accuracy_m': payload.accuracyM,
      'speed_mps': payload.speedMps,
      'battery_pct': payload.batteryPct,
      'is_mocked': payload.isMocked,
    },
  };

  // ignore: avoid_print
  print(const JsonEncoder.withIndent('  ').convert(fixture));

  pair.dispose();
  sectorKey.dispose();
}
