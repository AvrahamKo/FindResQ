/// Builds the exact byte sequence the backend's report ingest pipeline
/// expects: `pack(report) -> sign(payload) -> encrypt(payload || signature)`
/// -- the same envelope construction as [TelemetryPacketBuilder], just a
/// different (variable-length) payload shape.
///
/// Mirrors `backend/app/reports/pipeline.py`, which locates the trailing
/// 64-byte Ed25519 signature by first peeking the header's `note_len` field
/// via `report_format.peek_note_length` to compute the payload's actual
/// length -- see that module's docstring for why a report can't use a pure
/// fixed-width struct the way a location point does.
library;

import 'dart:typed_data';

import 'package:sodium/sodium.dart';

import '../crypto/device_identity.dart';
import '../crypto/mesh_crypto.dart';
import '../crypto/report_wire_format.dart';

class ReportPacketBuilder {
  final DeviceIdentity _identity;
  final MeshCrypto _crypto;

  const ReportPacketBuilder(this._identity, this._crypto);

  /// Returns the encrypted blob ready to submit to `/reports`.
  /// [deviceSecretKey] and [sectorKey] are the caller's responsibility to
  /// dispose -- this method only reads them, it does not take ownership.
  Uint8List build({
    required int wireId,
    required SecureKey deviceSecretKey,
    required SecureKey sectorKey,
    required int recordedAtMs,
    required String kind,
    required double lat,
    required double lng,
    required String note,
  }) {
    final payload = packReportPayload(
      ReportPayload(
        wireId: wireId,
        recordedAtMs: recordedAtMs,
        kind: kind,
        lat: lat,
        lng: lng,
        note: note,
      ),
    );

    final signature = _identity.sign(deviceSecretKey, payload);

    final plaintext = Uint8List(payload.length + signature.length)
      ..setRange(0, payload.length, payload)
      ..setRange(payload.length, payload.length + signature.length, signature);

    return _crypto.encrypt(sectorKey, plaintext);
  }
}
