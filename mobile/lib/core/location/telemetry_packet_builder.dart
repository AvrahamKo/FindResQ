/// Builds the exact byte sequence the backend's ingest pipeline expects for
/// one mesh telemetry packet: `pack(point) -> sign(payload) -> encrypt(payload
/// || signature)`.
///
/// Mirrors `backend/app/ingest/pipeline.py`'s
/// `_EXPECTED_PLAINTEXT_BYTES = wire_format.PAYLOAD_BYTES +
/// signatures.ED25519_SIGNATURE_BYTES` -- the plaintext that gets encrypted
/// is the 27-byte point payload with the 64-byte detached Ed25519 signature
/// appended, 91 bytes total, and the AEAD ciphertext (nonce || ciphertext ||
/// tag) of THAT is what gets buffered locally and, later (Phase 5d), POSTed
/// to `/ingest` as one base64 blob.
library;

import 'dart:typed_data';

import 'package:sodium/sodium.dart';

import '../crypto/device_identity.dart';
import '../crypto/mesh_crypto.dart';
import '../crypto/wire_format.dart';
import 'location_sample.dart';

class TelemetryPacketBuilder {
  final DeviceIdentity _identity;
  final MeshCrypto _crypto;

  const TelemetryPacketBuilder(this._identity, this._crypto);

  /// Returns the encrypted blob ready for local buffering. [deviceSecretKey]
  /// and [sectorKey] are the caller's responsibility to dispose -- this
  /// method only reads them, it does not take ownership.
  Uint8List build({
    required int wireId,
    required SecureKey deviceSecretKey,
    required SecureKey sectorKey,
    required LocationSample sample,
    required int batteryPct,
  }) {
    final payload = packPointPayload(
      PointPayload(
        wireId: wireId,
        recordedAtMs: sample.recordedAtMs,
        lat: sample.latitude,
        lng: sample.longitude,
        accuracyM: sample.accuracyM,
        speedMps: sample.speedMps,
        batteryPct: batteryPct,
        isMocked: sample.isMocked,
      ),
    );

    final signature = _identity.sign(deviceSecretKey, payload);

    final plaintext = Uint8List(payload.length + signature.length)
      ..setRange(0, payload.length, payload)
      ..setRange(payload.length, payload.length + signature.length, signature);

    return _crypto.encrypt(sectorKey, plaintext);
  }
}
