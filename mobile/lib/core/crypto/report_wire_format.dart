/// The signed field-report payload: a fixed-width 24-byte header followed
/// by a variable-length UTF-8 note -- mirrors
/// `backend/app/mesh/report_format.py` BYTE FOR BYTE. See
/// `wire_format.dart`'s docstring for why this isn't JSON.
///
/// Unlike a location point, a report carries free text (the note), so this
/// can't be a pure fixed-width struct. The header's `noteLen` field is what
/// lets a reader locate exactly where the note ends and the trailing
/// Ed25519 signature begins, without any ambiguity.
///
/// Layout (24-byte header + noteLen bytes of UTF-8, big-endian / network
/// byte order, no padding):
///
///   offset  size  field           encoding
///   0       1     version         uint8
///   1       4     wireId          uint32  (devices.wire_id, not the UUID)
///   5       8     recordedAtMs    uint64  (device clock, unix epoch millis)
///   13      1     kind            uint8   (index into [reportKinds])
///   14      4     latE7           int32   (degrees * 1e7)
///   18      4     lngE7           int32   (degrees * 1e7)
///   22      2     noteLen         uint16  (byte length of the UTF-8 note)
///   24      noteLen  note         UTF-8 bytes
///
/// `deliveryPath` is always 'direct' for now -- mesh relay (Phase 7) and SMS
/// fallback (Phase 6c) don't exist yet, but nothing in this wire format is
/// direct-path-specific, so neither will require a format change when they
/// land.
library;

import 'dart:convert';
import 'dart:typed_data';

const int reportWireFormatVersion = 1;
const int reportHeaderBytes = 24;
const int maxNoteBytes = 1000;

const int _latLngScale = 10000000;

/// Mirrors `report_format.py`'s `KINDS` tuple exactly, index for index --
/// the wire format encodes the index, not the string, so order matters.
const List<String> reportKinds = [
  'subject_found',
  'medical',
  'item_found',
  'hazard',
  'no_passage',
];

class ReportWireFormatException implements Exception {
  final String message;
  ReportWireFormatException(this.message);

  @override
  String toString() => 'ReportWireFormatException: $message';
}

class ReportPayload {
  final int wireId;
  final int recordedAtMs;
  final String kind;
  final double lat;
  final double lng;
  final String note;

  const ReportPayload({
    required this.wireId,
    required this.recordedAtMs,
    required this.kind,
    required this.lat,
    required this.lng,
    required this.note,
  });
}

Uint8List packReportPayload(ReportPayload payload) {
  final kindIndex = reportKinds.indexOf(payload.kind);
  if (kindIndex == -1) {
    throw ReportWireFormatException('unknown kind: ${payload.kind}');
  }
  if (payload.lat < -90.0 || payload.lat > 90.0) {
    throw ReportWireFormatException('lat out of range: ${payload.lat}');
  }
  if (payload.lng < -180.0 || payload.lng > 180.0) {
    throw ReportWireFormatException('lng out of range: ${payload.lng}');
  }

  final Uint8List noteBytes = Uint8List.fromList(utf8.encode(payload.note));
  if (noteBytes.length > maxNoteBytes) {
    throw ReportWireFormatException(
      'note too long: ${noteBytes.length} bytes (max $maxNoteBytes)',
    );
  }

  final ByteData header = ByteData(reportHeaderBytes);
  int offset = 0;
  header.setUint8(offset, reportWireFormatVersion);
  offset += 1;
  header.setUint32(offset, payload.wireId, Endian.big);
  offset += 4;
  header.setUint64(offset, payload.recordedAtMs, Endian.big);
  offset += 8;
  header.setUint8(offset, kindIndex);
  offset += 1;
  header.setInt32(offset, (payload.lat * _latLngScale).round(), Endian.big);
  offset += 4;
  header.setInt32(offset, (payload.lng * _latLngScale).round(), Endian.big);
  offset += 4;
  header.setUint16(offset, noteBytes.length, Endian.big);
  offset += 2;

  final Uint8List result = Uint8List(reportHeaderBytes + noteBytes.length);
  result.setRange(0, reportHeaderBytes, header.buffer.asUint8List());
  result.setRange(reportHeaderBytes, result.length, noteBytes);
  return result;
}

/// Reads just the header's `noteLen` field -- lets the caller locate where
/// the payload ends and a trailing signature begins before fully unpacking.
int peekNoteLength(Uint8List raw) {
  if (raw.length < reportHeaderBytes) {
    throw ReportWireFormatException(
      'expected at least $reportHeaderBytes header bytes, got ${raw.length}',
    );
  }
  final ByteData buffer = ByteData.sublistView(raw);
  return buffer.getUint16(reportHeaderBytes - 2, Endian.big);
}

ReportPayload unpackReportPayload(Uint8List raw) {
  if (raw.length < reportHeaderBytes) {
    throw ReportWireFormatException(
      'expected at least $reportHeaderBytes header bytes, got ${raw.length}',
    );
  }
  final ByteData buffer = ByteData.sublistView(raw);

  int offset = 0;
  final int version = buffer.getUint8(offset);
  offset += 1;
  if (version != reportWireFormatVersion) {
    throw ReportWireFormatException(
      'unsupported wire format version: $version',
    );
  }
  final int wireId = buffer.getUint32(offset, Endian.big);
  offset += 4;
  final int recordedAtMs = buffer.getUint64(offset, Endian.big);
  offset += 8;
  final int kindIndex = buffer.getUint8(offset);
  offset += 1;
  if (kindIndex >= reportKinds.length) {
    throw ReportWireFormatException('unknown kind index: $kindIndex');
  }
  final int latE7 = buffer.getInt32(offset, Endian.big);
  offset += 4;
  final int lngE7 = buffer.getInt32(offset, Endian.big);
  offset += 4;
  final int noteLen = buffer.getUint16(offset, Endian.big);
  offset += 2;

  final Uint8List noteBytes = raw.sublist(reportHeaderBytes);
  if (noteBytes.length != noteLen) {
    throw ReportWireFormatException(
      'expected $noteLen note bytes, got ${noteBytes.length}',
    );
  }

  return ReportPayload(
    wireId: wireId,
    recordedAtMs: recordedAtMs,
    kind: reportKinds[kindIndex],
    lat: latE7 / _latLngScale,
    lng: lngE7 / _latLngScale,
    note: utf8.decode(noteBytes),
  );
}
