"""GeoJSON polygon validation. Pure Pydantic model -- no database."""

from __future__ import annotations

import pytest
from pydantic import ValidationError

from app.api.schemas.sectors import GeoJSONPolygon

SQUARE_M = [
    [35.0, 31.0],
    [35.0, 31.001],
    [35.001, 31.001],
    [35.001, 31.0],
    [35.0, 31.0],  # closes the ring
]


def test_valid_closed_ring_is_accepted() -> None:
    polygon = GeoJSONPolygon(type="Polygon", coordinates=[SQUARE_M])
    assert polygon.coordinates[0][0] == polygon.coordinates[0][-1]


def test_unclosed_ring_is_rejected() -> None:
    """A ring whose first and last positions differ isn't a valid polygon and
    would either fail ST_GeomFromGeoJSON or silently misbehave in PostGIS."""
    unclosed = SQUARE_M[:-1]  # drop the closing position
    with pytest.raises(ValidationError):
        GeoJSONPolygon(type="Polygon", coordinates=[unclosed])


def test_ring_with_too_few_points_is_rejected() -> None:
    with pytest.raises(ValidationError):
        GeoJSONPolygon(type="Polygon", coordinates=[[[35.0, 31.0], [35.0, 31.0]]])


def test_wrong_geojson_type_is_rejected() -> None:
    with pytest.raises(ValidationError):
        GeoJSONPolygon(type="MultiPolygon", coordinates=[SQUARE_M])
