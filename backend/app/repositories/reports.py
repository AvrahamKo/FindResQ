"""Field reports: created via the encrypted/signed ingest-style pipeline
(`app/reports/pipeline.py`), visible to the whole sector team (not just
leadership -- unlike SOS, a "subject found" or "hazard" report is exactly
the kind of information every searcher benefits from seeing), and
acknowledgeable by a Lead/Commander as a lightweight triage signal.
"""

from __future__ import annotations

import uuid
from dataclasses import dataclass
from datetime import datetime

import asyncpg


@dataclass(frozen=True, slots=True)
class Report:
    id: uuid.UUID
    sector_id: uuid.UUID
    device_id: uuid.UUID
    user_id: uuid.UUID
    kind: str
    lat: float
    lng: float
    note: str | None
    recorded_at: datetime
    received_at: datetime
    delivery_path: str
    status: str
    acknowledged_by: uuid.UUID | None
    acknowledged_at: datetime | None
    updated_at: datetime


_SELECT_COLUMNS = """
    id, sector_id, device_id, user_id, kind,
    ST_Y(geom::geometry) AS lat, ST_X(geom::geometry) AS lng,
    note, recorded_at, received_at, delivery_path, status,
    acknowledged_by, acknowledged_at, updated_at
"""


def _to_report(record: asyncpg.Record) -> Report:
    return Report(**dict(record))


async def create(
    conn: asyncpg.Connection,
    *,
    sector_id: uuid.UUID,
    device_id: uuid.UUID,
    user_id: uuid.UUID,
    kind: str,
    lat: float,
    lng: float,
    note: str | None,
    recorded_at: datetime,
    delivery_path: str,
    signature: bytes,
) -> Report:
    """Raises `asyncpg.UniqueViolationError` on a duplicate `signature` --
    the same replay-defence invariant `track_points` uses, enforced by the
    database (`reports_signature_key`), not re-implemented here. The
    pipeline layer (`app/reports/pipeline.py`) is the one place that catches
    this and turns it into a `duplicate` count instead of a hard failure."""
    row = await conn.fetchrow(
        f"""
        INSERT INTO reports (
            sector_id, device_id, user_id, kind, geom, note,
            recorded_at, delivery_path, signature
        )
        VALUES (
            $1, $2, $3, $4,
            ST_SetSRID(ST_MakePoint($6, $5), 4326)::geography,
            $7, $8, $9, $10
        )
        RETURNING {_SELECT_COLUMNS}
        """,
        sector_id,
        device_id,
        user_id,
        kind,
        lat,
        lng,
        note,
        recorded_at,
        delivery_path,
        signature,
    )
    assert row is not None
    return _to_report(row)


async def get(conn: asyncpg.Connection, report_id: uuid.UUID) -> Report | None:
    row = await conn.fetchrow(
        f"SELECT {_SELECT_COLUMNS} FROM reports WHERE id = $1", report_id
    )
    return _to_report(row) if row is not None else None


async def list_for_sector(
    conn: asyncpg.Connection,
    sector_id: uuid.UUID,
    *,
    kind: str | None = None,
) -> list[Report]:
    if kind is None:
        rows = await conn.fetch(
            f"""
            SELECT {_SELECT_COLUMNS} FROM reports
            WHERE sector_id = $1
            ORDER BY received_at DESC
            """,
            sector_id,
        )
    else:
        rows = await conn.fetch(
            f"""
            SELECT {_SELECT_COLUMNS} FROM reports
            WHERE sector_id = $1 AND kind = $2
            ORDER BY received_at DESC
            """,
            sector_id,
            kind,
        )
    return [_to_report(r) for r in rows]


async def acknowledge(
    conn: asyncpg.Connection, report_id: uuid.UUID, *, by_user_id: uuid.UUID
) -> Report | None:
    row = await conn.fetchrow(
        f"""
        UPDATE reports
        SET status = 'acknowledged', acknowledged_by = $2, acknowledged_at = now(),
            updated_at = now()
        WHERE id = $1 AND status = 'open'
        RETURNING {_SELECT_COLUMNS}
        """,
        report_id,
        by_user_id,
    )
    return _to_report(row) if row is not None else None


async def get_for_sector(
    conn: asyncpg.Connection, sector_id: uuid.UUID, since: datetime | None = None
) -> list[Report]:
    """Delta-since-checkpoint read for the realtime listener -- same shape
    as `presence_repo`/`sos_repo`'s equivalents."""
    if since is None:
        rows = await conn.fetch(
            f"SELECT {_SELECT_COLUMNS} FROM reports WHERE sector_id = $1",
            sector_id,
        )
    else:
        rows = await conn.fetch(
            f"""
            SELECT {_SELECT_COLUMNS} FROM reports
            WHERE sector_id = $1 AND updated_at > $2
            """,
            sector_id,
            since,
        )
    return [_to_report(r) for r in rows]
