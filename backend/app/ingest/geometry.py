"""Pure geometry helpers: no database, no PostGIS, no shapely.

Point-to-point distance uses plain Haversine rather than a PostGIS round trip
-- segmentation (deciding where to break a track into segments) needs this
for every consecutive pair of points in a batch, and there is no reason to
pay a database call for it.

WKT construction is deliberately manual string formatting rather than
shapely: the format is trivial (a flat list of lng/lat pairs) and manual
formatting keeps this module dependency-free. The actual metric buffering
(radius in meters around a path) is delegated to PostGIS's `ST_Buffer` on a
`geography` value in the ingest pipeline -- geography buffering computes
meters correctly over the spheroid without any manual UTM-zone reprojection,
which is what makes this module able to stay this simple.
"""

from __future__ import annotations

import math

EARTH_RADIUS_M = 6_371_008.8  # IUGG mean radius


def haversine_distance_m(lat1: float, lng1: float, lat2: float, lng2: float) -> float:
    phi1, phi2 = math.radians(lat1), math.radians(lat2)
    d_phi = math.radians(lat2 - lat1)
    d_lambda = math.radians(lng2 - lng1)

    a = (
        math.sin(d_phi / 2) ** 2
        + math.cos(phi1) * math.cos(phi2) * math.sin(d_lambda / 2) ** 2
    )
    return 2 * EARTH_RADIUS_M * math.asin(math.sqrt(a))


def point_wkt(lat: float, lng: float) -> str:
    return f"POINT({lng} {lat})"


def linestring_wkt(points: list[tuple[float, float]]) -> str:
    """`points` is a list of (lat, lng) pairs, in order. WKT/GeoJSON/PostGIS
    use (x, y) = (lng, lat) -- the swap happens here, once, so nothing else
    in the pipeline has to remember which order which library wants."""
    if len(points) < 2:
        raise ValueError("a LINESTRING needs at least 2 points")
    coords = ", ".join(f"{lng} {lat}" for lat, lng in points)
    return f"LINESTRING({coords})"
