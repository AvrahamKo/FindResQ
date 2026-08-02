/// The signed point payload: a fixed-width binary struct, not JSON.
///
/// This mirrors `backend/app/mesh/wire_format.py` BYTE FOR BYTE. Ed25519
/// signs raw bytes, and the signer/verifier must agree on an exact,
/// unambiguous serialization -- a JSON encoding would require both sides to
/// agree on canonical key order/float formatting, which is a classic source
/// of "verification fails intermittently across languages" bugs. A
/// fixed-width struct sidesteps the whole problem: every field has an exact
/// offset and width, full stop.
///
/// This file is one half of the wire-protocol CONTRACT; the other half is
/// the Python module above. Whoever changes one must change the other, byte
/// for byte, or every signature either side tries to verify will simply
/// fail. Treat [wireFormatVersion] as the seam for any future change --
/// never silently redefine the layout under the same version number.
///
/// Layout (27 bytes, big-endian / network byte order, no padding):
///
///   offset  size  field           encoding
///   0       1     version         uint8
///   1       4     wireId          uint32  (devices.wire_id, not the UUID)
///   5       8     recordedAtMs    uint64  (device clock, unix epoch millis)
///   13      4     latE7           int32   (degrees * 1e7)
///   17      4     lngE7           int32   (degrees * 1e7)
///   21      2     accuracyDm      uint16  (horizontal accuracy, decimeters)
///   23      2     speedCms        uint16  (device-reported speed, cm/s)
///   25      1     batteryPct      uint8
///   26      1     flags           uint8   (bit0 = isMocked; bits 1-7 reserved)
///
/// Fixed-point lat/lng (1e7 scale, ~1.1cm resolution) is used instead of
/// IEEE 754 floats specifically to keep the encoding unambiguous across
/// platforms -- see the Python module for the full rationale.
library;

import 'dart:typed_data';

const int wireFormatVersion = 1;
const int payloadBytes = 27;

const int _flagIsMocked = 0x01;
const int _latLngScale = 10000000;
const int _maxAccuracyDm = 65535;
const int _maxSpeedCms = 65535;

class WireFormatException implements Exception {
  final String message;
  WireFormatException(this.message);

  @override
  String toString() => 'WireFormatException: $message';
}

class PointPayload {
  final int wireId;
  final int recordedAtMs;
  final double lat;
  final double lng;
  final double accuracyM;
  final double speedMps;
  final int batteryPct;
  final bool isMocked;

  const PointPayload({
    required this.wireId,
    required this.recordedAtMs,
    required this.lat,
    required this.lng,
    required this.accuracyM,
    required this.speedMps,
    required this.batteryPct,
    required this.isMocked,
  });
}

/// Packs [payload] into the 27-byte wire format.
///
/// Accuracy/speed are clamped, not rejected: a GPS chipset reporting a wild
/// accuracy value (hundreds of meters) is exactly the kind of point the
/// backend's plausibility stage needs to see and flag, not one the wire
/// format should refuse to carry.
Uint8List packPointPayload(PointPayload payload) {
  if (payload.lat < -90.0 || payload.lat > 90.0) {
    throw WireFormatException('lat out of range: ${payload.lat}');
  }
  if (payload.lng < -180.0 || payload.lng > 180.0) {
    throw WireFormatException('lng out of range: ${payload.lng}');
  }
  if (payload.batteryPct < 0 || payload.batteryPct > 100) {
    throw WireFormatException(
      'batteryPct out of range: ${payload.batteryPct}',
    );
  }

  final int accuracyDm = (payload.accuracyM * 10).round().clamp(
    0,
    _maxAccuracyDm,
  );
  final double clampedSpeed = payload.speedMps < 0 ? 0.0 : payload.speedMps;
  final int speedCms = (clampedSpeed * 100).round().clamp(0, _maxSpeedCms);
  final int flags = payload.isMocked ? _flagIsMocked : 0;

  final ByteData buffer = ByteData(payloadBytes);
  int offset = 0;
  buffer.setUint8(offset, wireFormatVersion);
  offset += 1;
  buffer.setUint32(offset, payload.wireId, Endian.big);
  offset += 4;
  buffer.setUint64(offset, payload.recordedAtMs, Endian.big);
  offset += 8;
  buffer.setInt32(offset, (payload.lat * _latLngScale).round(), Endian.big);
  offset += 4;
  buffer.setInt32(offset, (payload.lng * _latLngScale).round(), Endian.big);
  offset += 4;
  buffer.setUint16(offset, accuracyDm, Endian.big);
  offset += 2;
  buffer.setUint16(offset, speedCms, Endian.big);
  offset += 2;
  buffer.setUint8(offset, payload.batteryPct);
  offset += 1;
  buffer.setUint8(offset, flags);
  offset += 1;

  return buffer.buffer.asUint8List();
}

PointPayload unpackPointPayload(Uint8List raw) {
  if (raw.length != payloadBytes) {
    throw WireFormatException(
      'expected $payloadBytes bytes, got ${raw.length}',
    );
  }
  final ByteData buffer = ByteData.sublistView(raw);

  int offset = 0;
  final int version = buffer.getUint8(offset);
  offset += 1;
  if (version != wireFormatVersion) {
    throw WireFormatException('unsupported wire format version: $version');
  }
  final int wireId = buffer.getUint32(offset, Endian.big);
  offset += 4;
  final int recordedAtMs = buffer.getUint64(offset, Endian.big);
  offset += 8;
  final int latE7 = buffer.getInt32(offset, Endian.big);
  offset += 4;
  final int lngE7 = buffer.getInt32(offset, Endian.big);
  offset += 4;
  final int accuracyDm = buffer.getUint16(offset, Endian.big);
  offset += 2;
  final int speedCms = buffer.getUint16(offset, Endian.big);
  offset += 2;
  final int batteryPct = buffer.getUint8(offset);
  offset += 1;
  final int flags = buffer.getUint8(offset);
  offset += 1;

  return PointPayload(
    wireId: wireId,
    recordedAtMs: recordedAtMs,
    lat: latE7 / _latLngScale,
    lng: lngE7 / _latLngScale,
    accuracyM: accuracyDm / 10,
    speedMps: speedCms / 100,
    batteryPct: batteryPct,
    isMocked: (flags & _flagIsMocked) != 0,
  );
}
