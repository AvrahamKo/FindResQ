"""Segment lifecycle and point persistence.

The metric buffering (turning a path into a swath polygon) happens in SQL via
`ST_Buffer` on a `geography` value -- see ingest/coverage.py's docstring for
why that beats reprojecting in Python. This module is the only place that
touches `track_segments` / `track_points`.
"""

from __future__ import annotations

import json
import uuid
from dataclasses import dataclass
from datetime import datetime, timezone

import asyncpg


@dataclass(frozen=True, slots=True)
class OpenSegmentTail:
    segment_id: uuid.UUID
    started_at: datetime
    last_recorded_at: datetime
    last_lat: float
    last_lng: float


async def get_open_segment_tail(
    conn: asyncpg.Connection, device_id: uuid.UUID
) -> OpenSegmentTail | None:
    row = await conn.fetchrow(
        """
        SELECT id, started_at, last_recorded_at, last_lat, last_lng
        FROM track_segments
        WHERE device_id = $1 AND ended_at IS NULL
        """,
        device_id,
    )
    if row is None or row["last_recorded_at"] is None:
        return None
    return OpenSegmentTail(
        segment_id=row["id"],
        started_at=row["started_at"],
        last_recorded_at=row["last_recorded_at"],
        last_lat=row["last_lat"],
        last_lng=row["last_lng"],
    )


async def open_segment(
    conn: asyncpg.Connection,
    *,
    sector_id: uuid.UUID,
    device_id: uuid.UUID,
    user_id: uuid.UUID,
    movement_mode: str,
    is_valid: bool,
    plausibility_flags: tuple[str, ...],
    started_at: datetime,
    last_lat: float,
    last_lng: float,
) -> uuid.UUID:
    """Creates a segment already accounting for its first point (`point_count`
    starts at 1, `last_*` is that point's tail) -- the caller is responsible
    for calling `extend_segment` for any remaining points in the same run.

    The partial unique index `track_segments_open_idx` (migration 0004)
    guarantees at most one open segment per device; the pipeline always
    closes the prior one (`close_segment`) in the same transaction before
    opening a new one, so this insert never races that constraint."""
    return await conn.fetchval(
        """
        INSERT INTO track_segments (
            sector_id, device_id, user_id, movement_mode, started_at,
            is_valid, plausibility_flags, last_recorded_at, last_lat, last_lng,
            point_count
        )
        VALUES ($1, $2, $3, $4, $5, $6, $7, $5, $8, $9, 1)
        RETURNING id
        """,
        sector_id,
        device_id,
        user_id,
        movement_mode,
        started_at,
        is_valid,
        list(plausibility_flags),
        last_lat,
        last_lng,
    )


async def extend_segment(
    conn: asyncpg.Connection,
    segment_id: uuid.UUID,
    *,
    last_recorded_at: datetime,
    last_lat: float,
    last_lng: float,
    additional_points: int,
) -> None:
    await conn.execute(
        """
        UPDATE track_segments
        SET last_recorded_at = $2, last_lat = $3, last_lng = $4,
            point_count = point_count + $5
        WHERE id = $1
        """,
        segment_id,
        last_recorded_at,
        last_lat,
        last_lng,
        additional_points,
    )


async def close_segment(conn: asyncpg.Connection, segment_id: uuid.UUID) -> None:
    """Materializes `path`/`swath` once, from the segment's full point history,
    for the Commander dashboard's historical replay. A *live* (still-open)
    segment has no cached path -- the dashboard queries `track_points`
    directly for that, since it changes with every batch and caching it here
    would mean recomputing it on every single ingest call instead of once."""
    await conn.execute(
        """
        WITH pts AS (
            SELECT geom, recorded_at FROM track_points
            WHERE segment_id = $1
        ),
        line AS (
            SELECT CASE WHEN count(*) >= 2
                        THEN ST_MakeLine(geom::geometry ORDER BY recorded_at)
                        ELSE NULL END AS geom
            FROM pts
        )
        UPDATE track_segments s
        SET ended_at = now(),
            path = (SELECT geom::geography FROM line)
        WHERE s.id = $1
        """,
        segment_id,
    )


async def invalidate_segment(
    conn: asyncpg.Connection, segment_id: uuid.UUID, reason: str
) -> None:
    await conn.execute(
        """
        UPDATE track_segments
        SET is_valid = false,
            plausibility_flags = array_append(plausibility_flags, $2)
        WHERE id = $1 AND NOT ($2 = ANY(plausibility_flags))
        """,
        segment_id,
        reason,
    )


async def insert_point(
    conn: asyncpg.Connection,
    *,
    segment_id: uuid.UUID,
    sector_id: uuid.UUID,
    device_id: uuid.UUID,
    lat: float,
    lng: float,
    recorded_at: datetime,
    accuracy_m: float,
    speed_mps: float,
    battery_pct: int,
    is_mocked: bool,
    delivery_path: str,
    hop_count: int | None,
    signature: bytes,
) -> bool:
    """Returns False if `signature` already exists (replay/duplicate delivery)
    -- the UNIQUE index on track_points.signature is the pipeline's
    authoritative dedup, enforced here via ON CONFLICT DO NOTHING rather than
    a separate SELECT-then-INSERT (which would race under concurrent
    uploads of the same replayed packet)."""
    row = await conn.fetchrow(
        """
        INSERT INTO track_points (
            segment_id, sector_id, device_id, geom, recorded_at,
            accuracy_m, speed_mps, battery_pct, is_mocked, delivery_path,
            hop_count, signature
        )
        VALUES (
            $1, $2, $3,
            ST_SetSRID(ST_MakePoint($5, $4), 4326)::geography,
            $6, $7, $8, $9, $10, $11, $12, $13
        )
        ON CONFLICT (signature) DO NOTHING
        RETURNING id
        """,
        segment_id,
        sector_id,
        device_id,
        lat,
        lng,
        recorded_at,
        accuracy_m,
        speed_mps,
        battery_pct,
        is_mocked,
        delivery_path,
        hop_count,
        signature,
    )
    return row is not None


@dataclass(frozen=True, slots=True)
class TeamTrack:
    """One searcher's continuous traverse, as a simplified polyline."""

    segment_id: uuid.UUID
    user_id: uuid.UUID
    device_id: uuid.UUID
    movement_mode: str
    started_at: datetime
    ended_at: datetime | None
    is_valid: bool
    point_count: int
    # [(lat, lng), ...] in recorded order.
    points: list[tuple[float, float]]


# A closed segment caches `path`; a live one does not (see close_segment).
# Rather than branch, this reads points for both -- correctness over a micro-
# optimisation, since the live segments are exactly the ones a searcher in
# the field most needs to see moving.
#
# ST_Simplify runs in DEGREES because the geometry is WGS84 lon/lat. 1e-5 deg
# is ~1.1 m at the equator and less with latitude -- below the accuracy of
# any consumer GPS fix, so the rendered line is visually identical while the
# payload over a field LTE link drops by an order of magnitude on a long
# traverse. It is applied for TRANSPORT ONLY: coverage POD is computed from
# `hex_contributions`, never from this, so simplification here cannot move a
# hex or change anyone's search credit.
_TRACK_SIMPLIFY_DEGREES = 0.00001


async def get_team_tracks(
    conn: asyncpg.Connection,
    sector_id: uuid.UUID,
    *,
    since: datetime | None = None,
    limit: int = 200,
) -> list[TeamTrack]:
    """Every searcher's path in one sector -- the whole team, not one device.

    `since` filters on the segment's LAST point, not its first: an open
    segment started an hour ago but extended ten seconds ago is exactly what
    a polling client needs to receive again, and filtering on `started_at`
    would silently freeze every long traverse on the map at the position it
    held when the client first saw it.

    Invalid segments (plausibility-flagged, or retracted by a Commander) are
    excluded: they contribute nothing to coverage, so drawing them would
    show teammates ground that the POD map does not consider searched.
    """
    rows = await conn.fetch(
        """
        SELECT s.id AS segment_id, s.user_id, s.device_id, s.movement_mode,
               s.started_at, s.ended_at, s.is_valid, s.point_count,
               ST_AsGeoJSON(
                   ST_Simplify(
                       ST_MakeLine(p.geom::geometry ORDER BY p.recorded_at, p.id),
                       $4
                   )
               )::json AS line
        FROM track_segments s
        JOIN track_points p ON p.segment_id = s.id
        WHERE s.sector_id = $1
          AND s.is_valid
          AND ($2::timestamptz IS NULL OR s.last_recorded_at > $2)
        GROUP BY s.id
        HAVING count(p.id) >= 2
        ORDER BY s.started_at DESC
        LIMIT $3
        """,
        sector_id,
        since,
        limit,
        _TRACK_SIMPLIFY_DEGREES,
    )

    tracks: list[TeamTrack] = []
    for row in rows:
        line = row["line"]
        if isinstance(line, str):
            line = json.loads(line)
        if not line or line.get("type") != "LineString":
            # ST_MakeLine over collinear duplicates can degenerate to a
            # Point despite the >= 2 row guard. Nothing to draw.
            continue
        tracks.append(
            TeamTrack(
                segment_id=row["segment_id"],
                user_id=row["user_id"],
                device_id=row["device_id"],
                movement_mode=row["movement_mode"],
                started_at=row["started_at"],
                ended_at=row["ended_at"],
                is_valid=row["is_valid"],
                point_count=row["point_count"],
                # GeoJSON is [lng, lat]; every map widget in this project
                # wants (lat, lng). Swapped once, here.
                points=[(coord[1], coord[0]) for coord in line["coordinates"]],
            )
        )
    return tracks


async def buffer_wkt_to_geojson(
    conn: asyncpg.Connection, wkt: str, radius_m: float
) -> dict:
    """The core "swath" operation: build a geography from WKT and buffer it
    by `radius_m`. `ST_Buffer` on a `geography` argument computes true
    ground-distance meters (via a local azimuthal projection PostGIS applies
    internally), which is why this stays in SQL instead of shapely+pyproj in
    Python -- see ingest/coverage.py's module docstring."""
    value = await conn.fetchval(
        """
        SELECT ST_AsGeoJSON(
            ST_Buffer(ST_SetSRID(ST_GeomFromText($1), 4326)::geography, $2)
        )::json
        """,
        wkt,
        radius_m,
    )
    return value if isinstance(value, dict) else json.loads(value)
