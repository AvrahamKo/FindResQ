"""The signed point payload: a fixed-width binary struct, not JSON.

Ed25519 signs raw bytes. If we signed a JSON encoding instead, the signer and
verifier would have to agree on byte-for-byte canonical serialization (key
order, float formatting, whitespace) -- a classic source of "verification
fails intermittently across implementations" bugs once a second language
(the Flutter client) enters the picture. A fixed-width struct sidesteps the
whole problem: every field has an exact offset and width, full stop.

This module is the wire-protocol CONTRACT. Whoever writes the Dart/Flutter
side must pack an identical layout, byte for byte, or every signature this
backend tries to verify will simply fail. Treat `WIRE_FORMAT_VERSION` as the
seam for any future change -- never silently redefine the layout under the
same version number.

Layout (27 bytes, network byte order, no padding):

    offset  size  field          encoding
    0       1     version        uint8
    1       4     wire_id        uint32  (devices.wire_id, not the UUID)
    5       8     recorded_at_ms uint64  (device clock, unix epoch millis)
    13      4     lat_e7         int32   (degrees * 1e7)
    17      4     lng_e7         int32   (degrees * 1e7)
    21      2     accuracy_dm    uint16  (horizontal accuracy, decimeters)
    23      2     speed_cms      uint16  (device-reported speed, cm/s)
    25      1     battery_pct    uint8
    26      1     flags          uint8   (bit0 = is_mocked; bits 1-7 reserved)

This is the plaintext that gets Ed25519-signed, and the (payload || signature)
bundle that then gets XChaCha20-Poly1305 encrypted (security/mesh_crypto.py)
for transport. Fixed-point lat/lng (1e7 scale, ~1.1cm resolution) is used
instead of IEEE 754 floats specifically to keep the encoding unambiguous
across platforms -- float bit-patterns are consistent under IEEE 754 in
practice, but there is no reason to rely on that when integers are exact,
smaller, and simpler to reason about.
"""

from __future__ import annotations

import struct
from dataclasses import dataclass

WIRE_FORMAT_VERSION = 1

_STRUCT_FORMAT = "!BIQiiHHBB"
PAYLOAD_BYTES = struct.calcsize(_STRUCT_FORMAT)
assert PAYLOAD_BYTES == 27

_FLAG_IS_MOCKED = 0b0000_0001

_LAT_LNG_SCALE = 10_000_000
_MAX_ACCURACY_DM = 65_535  # uint16 ceiling; see docstring below
_MAX_SPEED_CMS = 65_535


class WireFormatError(ValueError):
    """Raised on a malformed or unsupported-version payload."""


@dataclass(frozen=True, slots=True)
class PointPayload:
    wire_id: int
    recorded_at_ms: int
    lat: float
    lng: float
    accuracy_m: float
    speed_mps: float
    battery_pct: int
    is_mocked: bool


def pack(payload: PointPayload) -> bytes:
    if not (-90.0 <= payload.lat <= 90.0):
        raise WireFormatError(f"lat out of range: {payload.lat}")
    if not (-180.0 <= payload.lng <= 180.0):
        raise WireFormatError(f"lng out of range: {payload.lng}")
    if not (0 <= payload.battery_pct <= 100):
        raise WireFormatError(f"battery_pct out of range: {payload.battery_pct}")

    # Accuracy/speed are clamped, not rejected: a GPS chipset reporting a
    # wild accuracy value (hundreds of meters) is exactly the kind of point
    # the plausibility stage needs to see and flag, not one the wire format
    # should refuse to carry.
    accuracy_dm = min(round(payload.accuracy_m * 10), _MAX_ACCURACY_DM)
    speed_cms = min(round(max(payload.speed_mps, 0.0) * 100), _MAX_SPEED_CMS)

    flags = _FLAG_IS_MOCKED if payload.is_mocked else 0

    return struct.pack(
        _STRUCT_FORMAT,
        WIRE_FORMAT_VERSION,
        payload.wire_id,
        payload.recorded_at_ms,
        round(payload.lat * _LAT_LNG_SCALE),
        round(payload.lng * _LAT_LNG_SCALE),
        accuracy_dm,
        speed_cms,
        payload.battery_pct,
        flags,
    )


def unpack(raw: bytes) -> PointPayload:
    if len(raw) != PAYLOAD_BYTES:
        raise WireFormatError(f"expected {PAYLOAD_BYTES} bytes, got {len(raw)}")

    (
        version,
        wire_id,
        recorded_at_ms,
        lat_e7,
        lng_e7,
        accuracy_dm,
        speed_cms,
        battery_pct,
        flags,
    ) = struct.unpack(_STRUCT_FORMAT, raw)

    if version != WIRE_FORMAT_VERSION:
        raise WireFormatError(f"unsupported wire format version: {version}")

    return PointPayload(
        wire_id=wire_id,
        recorded_at_ms=recorded_at_ms,
        lat=lat_e7 / _LAT_LNG_SCALE,
        lng=lng_e7 / _LAT_LNG_SCALE,
        accuracy_m=accuracy_dm / 10,
        speed_mps=speed_cms / 100,
        battery_pct=battery_pct,
        is_mocked=bool(flags & _FLAG_IS_MOCKED),
    )
