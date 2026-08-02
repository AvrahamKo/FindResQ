// Mirrors backend/tests/test_report_format.py -- same cases, same layout.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lifesearch_mobile/core/crypto/report_wire_format.dart';

ReportPayload _payload({
  int wireId = 42,
  int recordedAtMs = 1700000000123,
  String kind = 'hazard',
  double lat = 31.771959,
  double lng = 35.217018,
  String note = 'Downed power line across the trail.',
}) => ReportPayload(
  wireId: wireId,
  recordedAtMs: recordedAtMs,
  kind: kind,
  lat: lat,
  lng: lng,
  note: note,
);

void main() {
  test('round trips exactly', () {
    final payload = _payload();
    final packed = packReportPayload(payload);
    expect(packed.length, equals(reportHeaderBytes + utf8.encode(payload.note).length));

    final unpacked = unpackReportPayload(packed);
    expect(unpacked.wireId, equals(payload.wireId));
    expect(unpacked.recordedAtMs, equals(payload.recordedAtMs));
    expect(unpacked.kind, equals(payload.kind));
    expect(unpacked.note, equals(payload.note));
    expect(unpacked.lat, closeTo(payload.lat, 1e-6));
    expect(unpacked.lng, closeTo(payload.lng, 1e-6));
  });

  test('an empty note round trips', () {
    final packed = packReportPayload(_payload(note: ''));
    expect(packed.length, equals(reportHeaderBytes));
    expect(unpackReportPayload(packed).note, equals(''));
  });

  test('a unicode note round trips (byte length, not code point count)', () {
    const note = 'נמצא פצוע ליד השביל 🚑';
    final packed = packReportPayload(_payload(note: note));
    expect(unpackReportPayload(packed).note, equals(note));
  });

  for (final kind in reportKinds) {
    test('kind "$kind" round trips', () {
      final packed = packReportPayload(_payload(kind: kind));
      expect(unpackReportPayload(packed).kind, equals(kind));
    });
  }

  test('an unknown kind is rejected at pack time', () {
    expect(
      () => packReportPayload(_payload(kind: 'not_a_real_kind')),
      throwsA(isA<ReportWireFormatException>()),
    );
  });

  test('out-of-range lat is rejected', () {
    expect(
      () => packReportPayload(_payload(lat: 90.1)),
      throwsA(isA<ReportWireFormatException>()),
    );
    expect(
      () => packReportPayload(_payload(lat: -90.1)),
      throwsA(isA<ReportWireFormatException>()),
    );
  });

  test('out-of-range lng is rejected', () {
    expect(
      () => packReportPayload(_payload(lng: 180.1)),
      throwsA(isA<ReportWireFormatException>()),
    );
  });

  test('a note over the byte cap is rejected', () {
    expect(
      () => packReportPayload(_payload(note: 'x' * (maxNoteBytes + 1))),
      throwsA(isA<ReportWireFormatException>()),
    );
  });

  test('a note at exactly the byte cap is accepted', () {
    final note = 'x' * maxNoteBytes;
    final packed = packReportPayload(_payload(note: note));
    expect(unpackReportPayload(packed).note, equals(note));
  });

  test('a truncated header is rejected', () {
    expect(
      () => unpackReportPayload(Uint8List(reportHeaderBytes - 1)),
      throwsA(isA<ReportWireFormatException>()),
    );
  });

  test('a truncated note is rejected', () {
    final packed = packReportPayload(_payload(note: 'hello'));
    final truncated = Uint8List.sublistView(packed, 0, packed.length - 2);
    expect(
      () => unpackReportPayload(truncated),
      throwsA(isA<ReportWireFormatException>()),
    );
  });

  test('an unsupported version is rejected', () {
    final packed = packReportPayload(_payload(note: ''));
    packed[0] = reportWireFormatVersion + 1;
    expect(
      () => unpackReportPayload(packed),
      throwsA(isA<ReportWireFormatException>()),
    );
  });

  test('an unknown kind index is rejected', () {
    final packed = packReportPayload(_payload(note: ''));
    packed[13] = reportKinds.length; // one past the last valid index
    expect(
      () => unpackReportPayload(packed),
      throwsA(isA<ReportWireFormatException>()),
    );
  });

  group('peekNoteLength', () {
    test('reads the note length without a full unpack', () {
      final packed = packReportPayload(_payload(note: 'hello world'));
      expect(peekNoteLength(packed), equals(utf8.encode('hello world').length));
    });

    test('rejects a buffer shorter than the header', () {
      expect(
        () => peekNoteLength(Uint8List(reportHeaderBytes - 1)),
        throwsA(isA<ReportWireFormatException>()),
      );
    });
  });
}
