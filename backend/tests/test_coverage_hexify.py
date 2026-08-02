"""H3 hexification of a buffered swath polygon, and the day/night POD
selector. Pure -- exercises the real h3-py API, no database."""

from __future__ import annotations

from decimal import Decimal

import h3
import pytest

from app.ingest.coverage import (
    CoverageGeometryError,
    polygon_geojson_to_hex_ids,
    select_base_pod,
)

CENTER_LAT, CENTER_LNG = 31.771959, 35.217018
RESOLUTION = 12


def _square_geojson(lat: float, lng: float, half_side_deg: float) -> dict:
    d = half_side_deg
    ring = [
        [lng - d, lat - d],
        [lng - d, lat + d],
        [lng + d, lat + d],
        [lng + d, lat - d],
        [lng - d, lat - d],
    ]
    return {"type": "Polygon", "coordinates": [ring]}


def test_hexifies_a_small_polygon() -> None:
    geojson = _square_geojson(CENTER_LAT, CENTER_LNG, 0.0002)  # ~40m box
    hex_ids = polygon_geojson_to_hex_ids(geojson, RESOLUTION)

    assert len(hex_ids) >= 1
    for hex_id in hex_ids:
        assert isinstance(hex_id, int)
        # Round trip through h3's own int<->str conversion should be stable.
        assert h3.str_to_int(h3.int_to_str(hex_id)) == hex_id


def test_larger_polygon_covers_more_hexes_than_a_smaller_one() -> None:
    small = polygon_geojson_to_hex_ids(_square_geojson(CENTER_LAT, CENTER_LNG, 0.0001), RESOLUTION)
    large = polygon_geojson_to_hex_ids(_square_geojson(CENTER_LAT, CENTER_LNG, 0.001), RESOLUTION)
    assert len(large) > len(small)


def test_multipolygon_unions_hexes_from_both_parts() -> None:
    far_lat, far_lng = CENTER_LAT + 0.05, CENTER_LNG + 0.05  # far enough apart: disjoint hex sets
    geojson = {
        "type": "MultiPolygon",
        "coordinates": [
            _square_geojson(CENTER_LAT, CENTER_LNG, 0.0002)["coordinates"],
            _square_geojson(far_lat, far_lng, 0.0002)["coordinates"],
        ],
    }
    combined = polygon_geojson_to_hex_ids(geojson, RESOLUTION)
    part_a = polygon_geojson_to_hex_ids(_square_geojson(CENTER_LAT, CENTER_LNG, 0.0002), RESOLUTION)
    part_b = polygon_geojson_to_hex_ids(_square_geojson(far_lat, far_lng, 0.0002), RESOLUTION)

    assert combined == part_a | part_b
    assert part_a.isdisjoint(part_b)


def test_unsupported_geometry_type_is_rejected() -> None:
    with pytest.raises(CoverageGeometryError):
        polygon_geojson_to_hex_ids({"type": "Point", "coordinates": [35.0, 31.0]}, RESOLUTION)


class TestSelectBasePod:
    DAY = Decimal("0.400")
    NIGHT = Decimal("0.250")

    def _ms_at_utc_hour(self, hour: int) -> int:
        from datetime import datetime, timezone

        dt = datetime(2026, 6, 1, hour, 0, 0, tzinfo=timezone.utc)
        return int(dt.timestamp() * 1000)

    def test_noon_is_daylight(self) -> None:
        assert select_base_pod(
            base_pod_day=self.DAY, base_pod_night=self.NIGHT,
            recorded_at_ms=self._ms_at_utc_hour(12),
        ) == self.DAY

    def test_midnight_is_night(self) -> None:
        assert select_base_pod(
            base_pod_day=self.DAY, base_pod_night=self.NIGHT,
            recorded_at_ms=self._ms_at_utc_hour(0),
        ) == self.NIGHT

    def test_boundary_hours(self) -> None:
        assert select_base_pod(
            base_pod_day=self.DAY, base_pod_night=self.NIGHT,
            recorded_at_ms=self._ms_at_utc_hour(6),
        ) == self.DAY
        assert select_base_pod(
            base_pod_day=self.DAY, base_pod_night=self.NIGHT,
            recorded_at_ms=self._ms_at_utc_hour(18),
        ) == self.NIGHT
