"""Sector persistence, including the sector+event join RBAC checks lean on."""

from __future__ import annotations

import json
import uuid
from dataclasses import dataclass
from datetime import datetime
from decimal import Decimal

import asyncpg

_COLUMNS = """
    id, event_id, name, lead_user_id, status, key_epoch,
    h3_resolution, walker_radius_m, vehicle_base_radius_m,
    base_pod_day, base_pod_night, repeat_discount,
    max_gap_seconds, max_gap_meters, min_accuracy_m, max_walker_speed_mps,
    created_at
"""


@dataclass(frozen=True, slots=True)
class Sector:
    id: uuid.UUID
    event_id: uuid.UUID
    name: str
    lead_user_id: uuid.UUID | None
    status: str
    key_epoch: int
    h3_resolution: int
    walker_radius_m: Decimal
    vehicle_base_radius_m: Decimal
    base_pod_day: Decimal
    base_pod_night: Decimal
    repeat_discount: Decimal
    max_gap_seconds: int
    max_gap_meters: int
    min_accuracy_m: int
    max_walker_speed_mps: Decimal
    created_at: datetime


@dataclass(frozen=True, slots=True)
class SectorWithEvent:
    """Sector plus the fields RBAC checks need from its parent event, without
    a second round trip on every permission check."""

    sector: Sector
    event_commander_id: uuid.UUID
    event_status: str


def _to_sector(row: asyncpg.Record) -> Sector:
    return Sector(**{k: row[k] for k in Sector.__dataclass_fields__})


async def create(
    conn: asyncpg.Connection,
    *,
    event_id: uuid.UUID,
    name: str,
    boundary_geojson: dict,
) -> Sector:
    row = await conn.fetchrow(
        f"""
        INSERT INTO sectors (event_id, name, boundary)
        VALUES (
            $1, $2,
            ST_SetSRID(ST_GeomFromGeoJSON($3), 4326)::geography
        )
        RETURNING {_COLUMNS}
        """,
        event_id,
        name,
        json.dumps(boundary_geojson),
    )
    return _to_sector(row)


async def get(conn: asyncpg.Connection, sector_id: uuid.UUID) -> Sector | None:
    row = await conn.fetchrow(f"SELECT {_COLUMNS} FROM sectors WHERE id = $1", sector_id)
    return _to_sector(row) if row else None


async def get_with_event(
    conn: asyncpg.Connection, sector_id: uuid.UUID
) -> SectorWithEvent | None:
    cols = ", ".join(f"s.{c.strip()}" for c in _COLUMNS.strip().split(",") if c.strip())
    row = await conn.fetchrow(
        f"""
        SELECT {cols}, e.commander_id AS event_commander_id, e.status AS event_status
        FROM sectors s
        JOIN events e ON e.id = s.event_id
        WHERE s.id = $1
        """,
        sector_id,
    )
    if row is None:
        return None
    d = dict(row)
    event_commander_id = d.pop("event_commander_id")
    event_status = d.pop("event_status")
    return SectorWithEvent(
        sector=Sector(**d),
        event_commander_id=event_commander_id,
        event_status=event_status,
    )


async def get_boundary_geojson(conn: asyncpg.Connection, sector_id: uuid.UUID) -> dict | None:
    value = await conn.fetchval(
        "SELECT ST_AsGeoJSON(boundary)::json FROM sectors WHERE id = $1", sector_id
    )
    if value is None:
        return None
    # asyncpg returns json/jsonb columns as raw text unless a codec is
    # registered on the connection; no codec is registered, so parse here.
    return value if isinstance(value, dict) else json.loads(value)


async def list_for_event(conn: asyncpg.Connection, event_id: uuid.UUID) -> list[Sector]:
    rows = await conn.fetch(
        f"SELECT {_COLUMNS} FROM sectors WHERE event_id = $1 ORDER BY created_at",
        event_id,
    )
    return [_to_sector(row) for row in rows]


async def update_boundary(
    conn: asyncpg.Connection, sector_id: uuid.UUID, boundary_geojson: dict
) -> Sector | None:
    """Replaces the sector's outline.

    Deliberately does NOT touch the coverage ledger. `hex_contributions`
    records where searchers physically walked -- the ingest pipeline buffers
    the track and hexifies it without ever intersecting the sector polygon
    (see ingest/pipeline.py stages 9-10) -- and `recalc_hex_coverage()` reads
    only that ledger plus `repeat_discount`. So a redrawn boundary cannot
    change any hex's POD, and calling recalc here would burn CPU to write
    back identical numbers. Verified empirically: moving a boundary entirely
    off a covered hex and re-running recalc leaves its POD unchanged.

    That is also the behaviour a callout wants: "we searched here" is ground
    truth about the terrain, and redrawing an administrative outline must not
    silently erase it.
    """
    row = await conn.fetchrow(
        f"""
        UPDATE sectors
        SET boundary = ST_SetSRID(ST_GeomFromGeoJSON($2), 4326)::geography
        WHERE id = $1
        RETURNING {_COLUMNS}
        """,
        sector_id,
        json.dumps(boundary_geojson),
    )
    return _to_sector(row) if row else None


async def update_tuning(
    conn: asyncpg.Connection,
    sector_id: uuid.UUID,
    fields: dict,
) -> Sector | None:
    """`fields` contains only keys the caller actually supplied (partial update)."""
    if not fields:
        return await get(conn, sector_id)

    set_clause = ", ".join(f"{key} = ${i + 2}" for i, key in enumerate(fields))
    row = await conn.fetchrow(
        f"""
        UPDATE sectors SET {set_clause}
        WHERE id = $1
        RETURNING {_COLUMNS}
        """,
        sector_id,
        *fields.values(),
    )
    return _to_sector(row) if row else None


async def set_lead(
    conn: asyncpg.Connection, sector_id: uuid.UUID, lead_user_id: uuid.UUID | None
) -> Sector | None:
    row = await conn.fetchrow(
        f"""
        UPDATE sectors SET lead_user_id = $2
        WHERE id = $1
        RETURNING {_COLUMNS}
        """,
        sector_id,
        lead_user_id,
    )
    return _to_sector(row) if row else None


async def set_status(
    conn: asyncpg.Connection, sector_id: uuid.UUID, status: str
) -> Sector | None:
    row = await conn.fetchrow(
        f"""
        UPDATE sectors SET status = $2
        WHERE id = $1
        RETURNING {_COLUMNS}
        """,
        sector_id,
        status,
    )
    return _to_sector(row) if row else None


async def close_all_for_event(conn: asyncpg.Connection, event_id: uuid.UUID) -> None:
    """Event teardown: no sector in an ended event should accept new joins."""
    await conn.execute(
        "UPDATE sectors SET status = 'closed' WHERE event_id = $1 AND status != 'closed'",
        event_id,
    )
