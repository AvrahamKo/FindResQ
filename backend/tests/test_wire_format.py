"""The signed-payload wire format. Pure -- no crypto, no database."""

from __future__ import annotations

import pytest

from app.mesh import wire_format


def _payload(**overrides) -> wire_format.PointPayload:
    base = dict(
        wire_id=42,
        recorded_at_ms=1_700_000_000_123,
        lat=31.771959,
        lng=35.217018,
        accuracy_m=5.5,
        speed_mps=1.4,
        battery_pct=87,
        is_mocked=False,
    )
    base.update(overrides)
    return wire_format.PointPayload(**base)


def test_round_trips_exactly() -> None:
    payload = _payload()
    packed = wire_format.pack(payload)
    assert len(packed) == wire_format.PAYLOAD_BYTES == 27

    unpacked = wire_format.unpack(packed)
    assert unpacked.wire_id == payload.wire_id
    assert unpacked.recorded_at_ms == payload.recorded_at_ms
    assert unpacked.battery_pct == payload.battery_pct
    assert unpacked.is_mocked == payload.is_mocked
    # Fixed-point lat/lng (1e7 scale) round-trips to ~1.1cm precision.
    assert unpacked.lat == pytest.approx(payload.lat, abs=1e-6)
    assert unpacked.lng == pytest.approx(payload.lng, abs=1e-6)
    assert unpacked.accuracy_m == pytest.approx(payload.accuracy_m, abs=0.05)
    assert unpacked.speed_mps == pytest.approx(payload.speed_mps, abs=0.005)


def test_is_mocked_flag_round_trips() -> None:
    assert wire_format.unpack(wire_format.pack(_payload(is_mocked=True))).is_mocked is True
    assert wire_format.unpack(wire_format.pack(_payload(is_mocked=False))).is_mocked is False


@pytest.mark.parametrize("lat", [90.1, -90.1])
def test_out_of_range_lat_rejected(lat: float) -> None:
    with pytest.raises(wire_format.WireFormatError):
        wire_format.pack(_payload(lat=lat))


@pytest.mark.parametrize("lng", [180.1, -180.1])
def test_out_of_range_lng_rejected(lng: float) -> None:
    with pytest.raises(wire_format.WireFormatError):
        wire_format.pack(_payload(lng=lng))


def test_wild_accuracy_is_clamped_not_rejected() -> None:
    """A GPS chipset reporting a huge accuracy value is exactly the kind of
    point the plausibility stage needs to see -- the wire format must carry
    it, not refuse it."""
    packed = wire_format.pack(_payload(accuracy_m=50_000.0))
    unpacked = wire_format.unpack(packed)
    assert unpacked.accuracy_m == pytest.approx(6553.5, abs=0.1)


def test_negative_speed_is_clamped_to_zero() -> None:
    packed = wire_format.pack(_payload(speed_mps=-5.0))
    assert wire_format.unpack(packed).speed_mps == 0.0


def test_wrong_length_is_rejected() -> None:
    with pytest.raises(wire_format.WireFormatError):
        wire_format.unpack(b"too short")


def test_unsupported_version_is_rejected() -> None:
    packed = bytearray(wire_format.pack(_payload()))
    packed[0] = 99
    with pytest.raises(wire_format.WireFormatError):
        wire_format.unpack(bytes(packed))
