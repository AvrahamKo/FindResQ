"""Pure geometry helpers: Haversine distance and WKT construction."""

from __future__ import annotations

import pytest

from app.ingest.geometry import haversine_distance_m, linestring_wkt, point_wkt


def test_haversine_zero_distance_for_identical_points() -> None:
    assert haversine_distance_m(31.77, 35.21, 31.77, 35.21) == pytest.approx(0.0, abs=1e-6)


def test_haversine_matches_known_distance() -> None:
    # ~1 degree of latitude is ~111.19 km at the equator-ish; a well-known
    # reference figure, good enough to catch a formula regression.
    d = haversine_distance_m(0.0, 0.0, 1.0, 0.0)
    assert d == pytest.approx(111_195, rel=0.01)


def test_haversine_is_symmetric() -> None:
    a = haversine_distance_m(31.77, 35.21, 31.78, 35.22)
    b = haversine_distance_m(31.78, 35.22, 31.77, 35.21)
    assert a == pytest.approx(b)


def test_point_wkt_swaps_to_lng_lat_order() -> None:
    assert point_wkt(lat=31.77, lng=35.21) == "POINT(35.21 31.77)"


def test_linestring_wkt_swaps_every_coordinate() -> None:
    wkt = linestring_wkt([(31.0, 35.0), (32.0, 36.0)])
    assert wkt == "LINESTRING(35.0 31.0, 36.0 32.0)"


def test_linestring_wkt_requires_at_least_two_points() -> None:
    with pytest.raises(ValueError):
        linestring_wkt([(31.0, 35.0)])
