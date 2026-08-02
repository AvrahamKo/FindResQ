"""The signed report payload wire format. Pure -- no crypto, no database."""

from __future__ import annotations

import pytest

from app.mesh import report_format


def _payload(**overrides) -> report_format.ReportPayload:
    base = dict(
        wire_id=42,
        recorded_at_ms=1_700_000_000_123,
        kind="hazard",
        lat=31.771959,
        lng=35.217018,
        note="Downed power line across the trail.",
    )
    base.update(overrides)
    return report_format.ReportPayload(**base)


def test_round_trips_exactly() -> None:
    payload = _payload()
    packed = report_format.pack(payload)
    assert len(packed) == report_format.HEADER_BYTES + len(payload.note.encode("utf-8"))

    unpacked = report_format.unpack(packed)
    assert unpacked.wire_id == payload.wire_id
    assert unpacked.recorded_at_ms == payload.recorded_at_ms
    assert unpacked.kind == payload.kind
    assert unpacked.note == payload.note
    assert unpacked.lat == pytest.approx(payload.lat, abs=1e-6)
    assert unpacked.lng == pytest.approx(payload.lng, abs=1e-6)


def test_empty_note_round_trips() -> None:
    packed = report_format.pack(_payload(note=""))
    assert len(packed) == report_format.HEADER_BYTES
    assert report_format.unpack(packed).note == ""


def test_unicode_note_round_trips() -> None:
    # UTF-8 byte length != character count for multi-byte characters --
    # confirms note_len is measured in BYTES, not code points, matching how
    # the header field is actually interpreted on unpack.
    note = "נמצא פצוע ליד השביל 🚑"
    packed = report_format.pack(_payload(note=note))
    unpacked = report_format.unpack(packed)
    assert unpacked.note == note


@pytest.mark.parametrize("kind", report_format.KINDS)
def test_every_kind_round_trips(kind: str) -> None:
    packed = report_format.pack(_payload(kind=kind))
    assert report_format.unpack(packed).kind == kind


def test_unknown_kind_is_rejected_at_pack_time() -> None:
    with pytest.raises(report_format.ReportWireFormatError):
        report_format.pack(_payload(kind="not_a_real_kind"))


@pytest.mark.parametrize("lat", [90.1, -90.1])
def test_out_of_range_lat_is_rejected(lat: float) -> None:
    with pytest.raises(report_format.ReportWireFormatError):
        report_format.pack(_payload(lat=lat))


@pytest.mark.parametrize("lng", [180.1, -180.1])
def test_out_of_range_lng_is_rejected(lng: float) -> None:
    with pytest.raises(report_format.ReportWireFormatError):
        report_format.pack(_payload(lng=lng))


def test_a_note_over_the_byte_cap_is_rejected() -> None:
    with pytest.raises(report_format.ReportWireFormatError):
        report_format.pack(_payload(note="x" * (report_format.MAX_NOTE_BYTES + 1)))


def test_a_note_at_exactly_the_byte_cap_is_accepted() -> None:
    packed = report_format.pack(_payload(note="x" * report_format.MAX_NOTE_BYTES))
    assert report_format.unpack(packed).note == "x" * report_format.MAX_NOTE_BYTES


def test_truncated_header_is_rejected() -> None:
    with pytest.raises(report_format.ReportWireFormatError):
        report_format.unpack(b"\x00" * (report_format.HEADER_BYTES - 1))


def test_truncated_note_is_rejected() -> None:
    packed = report_format.pack(_payload(note="hello"))
    with pytest.raises(report_format.ReportWireFormatError):
        report_format.unpack(packed[:-2])  # note_len says 5 bytes, only 3 present


def test_unsupported_version_is_rejected() -> None:
    packed = bytearray(report_format.pack(_payload(note="")))
    packed[0] = report_format.REPORT_WIRE_FORMAT_VERSION + 1
    with pytest.raises(report_format.ReportWireFormatError):
        report_format.unpack(bytes(packed))


def test_unknown_kind_index_is_rejected() -> None:
    packed = bytearray(report_format.pack(_payload(note="")))
    packed[13] = len(report_format.KINDS)  # one past the last valid index
    with pytest.raises(report_format.ReportWireFormatError):
        report_format.unpack(bytes(packed))


class TestPeekNoteLength:
    def test_reads_the_note_length_without_full_unpack(self) -> None:
        packed = report_format.pack(_payload(note="hello world"))
        assert report_format.peek_note_length(packed) == len("hello world".encode("utf-8"))

    def test_rejects_a_buffer_shorter_than_the_header(self) -> None:
        with pytest.raises(report_format.ReportWireFormatError):
            report_format.peek_note_length(b"\x00" * (report_format.HEADER_BYTES - 1))
