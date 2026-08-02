"""Stage 10 (the hexify half): turn a buffered swath polygon into H3 cell ids.

The swath polygon itself is computed in SQL via `ST_Buffer` on a `geography`
value (see repositories/track_points.py) rather than in Python with
shapely+pyproj. `geography` buffering computes true meters over the spheroid
directly -- doing this in Python would mean picking a local UTM zone,
reprojecting, buffering in projected meters, and reprojecting back, entirely
to reinvent what PostGIS already does correctly for exactly this case (a
buffer local to one small search sector, never spanning a UTM zone boundary
or a large fraction of the globe).

The one thing that must not be forgotten at this seam: GeoJSON/PostGIS order
coordinates (lng, lat); H3 orders them (lat, lng). Swapping it wrong produces
a "valid" but wildly wrong set of hexes -- silently, since nothing raises.
"""

from __future__ import annotations

from datetime import datetime, timezone
from decimal import Decimal

import h3


class CoverageGeometryError(ValueError):
    pass


def select_base_pod(
    *, base_pod_day: Decimal, base_pod_night: Decimal, recorded_at_ms: int
) -> Decimal:
    """MVP day/night heuristic: 06:00-18:00 UTC counts as daylight. This is a
    fixed UTC window, not a real sunrise/sunset calculation for the sector's
    actual location -- proper solar-position math is a legitimate future
    improvement, not attempted here. A Commander who finds this heuristic
    wrong for their sector's latitude/season can already override
    `base_pod_day`/`base_pod_night` directly."""
    hour_utc = datetime.fromtimestamp(recorded_at_ms / 1000, tz=timezone.utc).hour
    is_daylight = 6 <= hour_utc < 18
    return base_pod_day if is_daylight else base_pod_night


def _ring_to_latlng(ring: list[list[float]]) -> list[tuple[float, float]]:
    return [(lat, lng) for lng, lat in ring]


def polygon_geojson_to_hex_ids(geojson: dict, resolution: int) -> set[int]:
    """Accepts the `dict` produced by `ST_AsGeoJSON(...)::json` for a
    Polygon or MultiPolygon and returns the set of H3 cell ids (as ints,
    matching `hex_contributions.hex_id BIGINT`) it covers."""
    geom_type = geojson.get("type")

    if geom_type == "Polygon":
        polygons = [geojson["coordinates"]]
    elif geom_type == "MultiPolygon":
        polygons = geojson["coordinates"]
    else:
        raise CoverageGeometryError(f"expected Polygon or MultiPolygon, got {geom_type!r}")

    hex_ids: set[int] = set()
    for rings in polygons:
        if not rings:
            continue
        outer, *holes = (_ring_to_latlng(ring) for ring in rings)
        shape = h3.LatLngPoly(outer, *holes)
        hex_ids.update(h3.str_to_int(h) for h in h3.polygon_to_cells(shape, resolution))

    return hex_ids
