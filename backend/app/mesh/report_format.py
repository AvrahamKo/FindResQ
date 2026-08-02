"""The signed field-report payload: a fixed-width header followed by a
variable-length UTF-8 note -- not JSON, for exactly the same reason
`wire_format.py`'s point payload isn't JSON (see that module's docstring).

Unlike a location point, a report carries free-text (the `note` field), so
this can't be a pure fixed-width struct like the point payload. Instead it's
a fixed 24-byte header (which includes the note's byte length) immediately
followed by that many UTF-8 bytes -- the header's `note_len` field is what
lets a reader (or `ingest_reports_route`, before it even knows the note's
content) locate exactly where the note ends and the trailing Ed25519
signature begins, without any ambiguity.

Layout (24-byte header + note_len bytes of UTF-8, big-endian / network byte
order, no padding):

    offset  size  field           encoding
    0       1     version         uint8
    1       4     wire_id         uint32  (devices.wire_id, not the UUID)
    5       8     recorded_at_ms  uint64  (device clock, unix epoch millis)
    13      1     kind            uint8   (index into KINDS)
    14      4     lat_e7          int32   (degrees * 1e7)
    18      4     lng_e7          int32   (degrees * 1e7)
    22      2     note_len        uint16  (byte length of the UTF-8 note)
    24      note_len  note        UTF-8 bytes

This is the plaintext that gets Ed25519-signed, and the (payload || signature)
bundle that then gets XChaCha20-Poly1305 encrypted (security/mesh_crypto.py)
for transport -- the exact same envelope construction as location points,
just a different payload shape. `delivery_path` is always 'direct' for now:
mesh relay (Phase 7) and SMS fallback (Phase 6c) are both out of scope until
those transports exist, but the wire format itself has nothing
direct-path-specific baked into it, so neither will require a format change
when they land.
"""

from __future__ import annotations

import struct
from dataclasses import dataclass

REPORT_WIRE_FORMAT_VERSION = 1

_HEADER_FORMAT = "!BIQBiiH"
HEADER_BYTES = struct.calcsize(_HEADER_FORMAT)
assert HEADER_BYTES == 24

_LAT_LNG_SCALE = 10_000_000
MAX_NOTE_BYTES = 1000

KINDS = ("subject_found", "medical", "item_found", "hazard", "no_passage")
_KIND_TO_INDEX = {kind: index for index, kind in enumerate(KINDS)}


class ReportWireFormatError(ValueError):
    """Raised on a malformed or unsupported-version payload."""


@dataclass(frozen=True, slots=True)
class ReportPayload:
    wire_id: int
    recorded_at_ms: int
    kind: str
    lat: float
    lng: float
    note: str


def pack(payload: ReportPayload) -> bytes:
    if payload.kind not in _KIND_TO_INDEX:
        raise ReportWireFormatError(f"unknown kind: {payload.kind}")
    if not (-90.0 <= payload.lat <= 90.0):
        raise ReportWireFormatError(f"lat out of range: {payload.lat}")
    if not (-180.0 <= payload.lng <= 180.0):
        raise ReportWireFormatError(f"lng out of range: {payload.lng}")

    note_bytes = payload.note.encode("utf-8")
    if len(note_bytes) > MAX_NOTE_BYTES:
        raise ReportWireFormatError(
            f"note too long: {len(note_bytes)} bytes (max {MAX_NOTE_BYTES})"
        )

    header = struct.pack(
        _HEADER_FORMAT,
        REPORT_WIRE_FORMAT_VERSION,
        payload.wire_id,
        payload.recorded_at_ms,
        _KIND_TO_INDEX[payload.kind],
        round(payload.lat * _LAT_LNG_SCALE),
        round(payload.lng * _LAT_LNG_SCALE),
        len(note_bytes),
    )
    return header + note_bytes


def peek_note_length(raw: bytes) -> int:
    """Reads just the header's `note_len` field -- lets the caller (the
    ingest pipeline) compute where the payload ends and the trailing
    signature begins before fully unpacking anything."""
    if len(raw) < HEADER_BYTES:
        raise ReportWireFormatError(
            f"expected at least {HEADER_BYTES} header bytes, got {len(raw)}"
        )
    (note_len,) = struct.unpack_from("!H", raw, HEADER_BYTES - 2)
    return note_len


def unpack(raw: bytes) -> ReportPayload:
    if len(raw) < HEADER_BYTES:
        raise ReportWireFormatError(
            f"expected at least {HEADER_BYTES} header bytes, got {len(raw)}"
        )

    (
        version,
        wire_id,
        recorded_at_ms,
        kind_index,
        lat_e7,
        lng_e7,
        note_len,
    ) = struct.unpack(_HEADER_FORMAT, raw[:HEADER_BYTES])

    if version != REPORT_WIRE_FORMAT_VERSION:
        raise ReportWireFormatError(f"unsupported wire format version: {version}")
    if kind_index >= len(KINDS):
        raise ReportWireFormatError(f"unknown kind index: {kind_index}")

    note_bytes = raw[HEADER_BYTES:]
    if len(note_bytes) != note_len:
        raise ReportWireFormatError(
            f"expected {note_len} note bytes, got {len(note_bytes)}"
        )

    try:
        note = note_bytes.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise ReportWireFormatError("note is not valid UTF-8") from exc

    return ReportPayload(
        wire_id=wire_id,
        recorded_at_ms=recorded_at_ms,
        kind=KINDS[kind_index],
        lat=lat_e7 / _LAT_LNG_SCALE,
        lng=lng_e7 / _LAT_LNG_SCALE,
        note=note,
    )
