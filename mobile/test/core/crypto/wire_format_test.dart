// Mirrors backend/tests/test_wire_format.py -- same cases, same file layout.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lifesearch_mobile/core/crypto/wire_format.dart';

PointPayload _payload({
  int wireId = 42,
  int recordedAtMs = 1700000000123,
  double lat = 31.771959,
  double lng = 35.217018,
  double accuracyM = 5.5,
  double speedMps = 1.4,
  int batteryPct = 87,
  bool isMocked = false,
}) {
  return PointPayload(
    wireId: wireId,
    recordedAtMs: recordedAtMs,
    lat: lat,
    lng: lng,
    accuracyM: accuracyM,
    speedMps: speedMps,
    batteryPct: batteryPct,
    isMocked: isMocked,
  );
}

void main() {
  test('round trips exactly', () {
    final payload = _payload();
    final packed = packPointPayload(payload);
    expect(packed.length, equals(payloadBytes));
    expect(payloadBytes, equals(27));

    final unpacked = unpackPointPayload(packed);
    expect(unpacked.wireId, equals(payload.wireId));
    expect(unpacked.recordedAtMs, equals(payload.recordedAtMs));
    expect(unpacked.batteryPct, equals(payload.batteryPct));
    expect(unpacked.isMocked, equals(payload.isMocked));
    // Fixed-point lat/lng (1e7 scale) round-trips to ~1.1cm precision.
    expect(unpacked.lat, closeTo(payload.lat, 1e-6));
    expect(unpacked.lng, closeTo(payload.lng, 1e-6));
    expect(unpacked.accuracyM, closeTo(payload.accuracyM, 0.05));
    expect(unpacked.speedMps, closeTo(payload.speedMps, 0.005));
  });

  test('isMocked flag round trips', () {
    expect(
      unpackPointPayload(packPointPayload(_payload(isMocked: true))).isMocked,
      isTrue,
    );
    expect(
      unpackPointPayload(packPointPayload(_payload(isMocked: false))).isMocked,
      isFalse,
    );
  });

  for (final lat in [90.1, -90.1]) {
    test('out-of-range lat $lat is rejected', () {
      expect(
        () => packPointPayload(_payload(lat: lat)),
        throwsA(isA<WireFormatException>()),
      );
    });
  }

  for (final lng in [180.1, -180.1]) {
    test('out-of-range lng $lng is rejected', () {
      expect(
        () => packPointPayload(_payload(lng: lng)),
        throwsA(isA<WireFormatException>()),
      );
    });
  }

  test('wild accuracy is clamped, not rejected', () {
    // A GPS chipset reporting a huge accuracy value is exactly the kind of
    // point the plausibility stage needs to see -- the wire format must
    // carry it, not refuse it.
    final packed = packPointPayload(_payload(accuracyM: 50000.0));
    final unpacked = unpackPointPayload(packed);
    expect(unpacked.accuracyM, closeTo(6553.5, 0.1));
  });

  test('negative speed is clamped to zero', () {
    final packed = packPointPayload(_payload(speedMps: -5.0));
    expect(unpackPointPayload(packed).speedMps, equals(0.0));
  });

  test('wrong length is rejected', () {
    expect(
      () => unpackPointPayload(Uint8List.fromList([1, 2, 3])),
      throwsA(isA<WireFormatException>()),
    );
  });

  test('unsupported version is rejected', () {
    final packed = packPointPayload(_payload());
    packed[0] = 99;
    expect(
      () => unpackPointPayload(packed),
      throwsA(isA<WireFormatException>()),
    );
  });
}
