"""SOS alerts: a searcher-triggered distress signal, explicit and immediate
-- independent of Phase 4's passive correlated-silence presence heuristic.

Status transitions: active -> acknowledged -> resolved, or active/acknowledged
-> cancelled (only by the triggering user -- a false alarm). See
migrations/0006_sos.sql for the full state diagram and the database-level
invariant (at most one open alert per device) this module relies on rather
than re-implementing itself.
"""

from __future__ import annotations

import uuid
from dataclasses import dataclass
from datetime import datetime

import asyncpg

OPEN_STATUSES = ("active", "acknowledged")


@dataclass(frozen=True, slots=True)
class SosAlert:
    id: uuid.UUID
    sector_id: uuid.UUID
    device_id: uuid.UUID
    user_id: uuid.UUID
    status: str
    lat: float | None
    lng: float | None
    triggered_at: datetime
    acknowledged_at: datetime | None
    acknowledged_by: uuid.UUID | None
    resolved_at: datetime | None
    resolved_by: uuid.UUID | None
    cancelled_at: datetime | None
    updated_at: datetime


_SELECT_COLUMNS = """
    id, sector_id, device_id, user_id, status,
    ST_Y(geom::geometry) AS lat, ST_X(geom::geometry) AS lng,
    triggered_at, acknowledged_at, acknowledged_by,
    resolved_at, resolved_by, cancelled_at, updated_at
"""


def _to_alert(record: asyncpg.Record) -> SosAlert:
    return SosAlert(**dict(record))


async def get(conn: asyncpg.Connection, alert_id: uuid.UUID) -> SosAlert | None:
    row = await conn.fetchrow(
        f"SELECT {_SELECT_COLUMNS} FROM sos_alerts WHERE id = $1", alert_id
    )
    return _to_alert(row) if row is not None else None


async def get_open_for_device(
    conn: asyncpg.Connection, device_id: uuid.UUID
) -> SosAlert | None:
    row = await conn.fetchrow(
        f"""
        SELECT {_SELECT_COLUMNS} FROM sos_alerts
        WHERE device_id = $1 AND status = ANY($2::text[])
        """,
        device_id,
        list(OPEN_STATUSES),
    )
    return _to_alert(row) if row is not None else None


async def trigger(
    conn: asyncpg.Connection,
    *,
    sector_id: uuid.UUID,
    device_id: uuid.UUID,
    user_id: uuid.UUID,
    lat: float | None,
    lng: float | None,
) -> SosAlert:
    """Idempotent: if this device already has an open alert, returns THAT
    one rather than creating a duplicate incident. A second press of the SOS
    button (a shaky hand, an app restart mid-emergency) must never silently
    fork into two concurrent alerts for what is the same emergency -- and
    the unique partial index in migrations/0006_sos.sql makes this safe even
    under a race between two near-simultaneous requests, not just a
    check-then-insert race in this function alone.
    """
    existing = await get_open_for_device(conn, device_id)
    if existing is not None:
        return existing

    try:
        row = await conn.fetchrow(
            f"""
            INSERT INTO sos_alerts (sector_id, device_id, user_id, geom)
            VALUES (
                $1, $2, $3,
                CASE WHEN $4::double precision IS NULL THEN NULL
                     ELSE ST_SetSRID(ST_MakePoint($5, $4), 4326)::geography END
            )
            RETURNING {_SELECT_COLUMNS}
            """,
            sector_id,
            device_id,
            user_id,
            lat,
            lng,
        )
    except asyncpg.UniqueViolationError:
        # Lost the race against a concurrent trigger from the same device
        # between the check above and this insert -- the other request won,
        # so hand back what it created instead of failing.
        existing = await get_open_for_device(conn, device_id)
        assert existing is not None  # the unique index guarantees this exists
        return existing

    assert row is not None
    return _to_alert(row)


async def acknowledge(
    conn: asyncpg.Connection, alert_id: uuid.UUID, *, by_user_id: uuid.UUID
) -> SosAlert | None:
    row = await conn.fetchrow(
        f"""
        UPDATE sos_alerts
        SET status = 'acknowledged', acknowledged_at = now(),
            acknowledged_by = $2, updated_at = now()
        WHERE id = $1 AND status = 'active'
        RETURNING {_SELECT_COLUMNS}
        """,
        alert_id,
        by_user_id,
    )
    return _to_alert(row) if row is not None else None


async def resolve(
    conn: asyncpg.Connection, alert_id: uuid.UUID, *, by_user_id: uuid.UUID
) -> SosAlert | None:
    row = await conn.fetchrow(
        f"""
        UPDATE sos_alerts
        SET status = 'resolved', resolved_at = now(),
            resolved_by = $2, updated_at = now()
        WHERE id = $1 AND status = ANY($3::text[])
        RETURNING {_SELECT_COLUMNS}
        """,
        alert_id,
        by_user_id,
        list(OPEN_STATUSES),
    )
    return _to_alert(row) if row is not None else None


async def cancel(conn: asyncpg.Connection, alert_id: uuid.UUID) -> SosAlert | None:
    row = await conn.fetchrow(
        f"""
        UPDATE sos_alerts
        SET status = 'cancelled', cancelled_at = now(), updated_at = now()
        WHERE id = $1 AND status = ANY($2::text[])
        RETURNING {_SELECT_COLUMNS}
        """,
        alert_id,
        list(OPEN_STATUSES),
    )
    return _to_alert(row) if row is not None else None


async def delete(conn: asyncpg.Connection, alert_id: uuid.UUID) -> SosAlert | None:
    """Permanently removes ONE alert, returning what was removed (so the
    caller can log and broadcast it) or None if it was already gone.

    A hard DELETE, not a soft 'dismissed' flag. An SOS that has been
    resolved or cancelled has already served its entire purpose -- unlike a
    membership, nothing downstream references `sos_alerts`, so there is no
    attribution to preserve and a tombstone would only be clutter with extra
    steps. The `sos_alerts_notify_deleted` trigger (migration 0008) is what
    turns this into a realtime removal on every connected dashboard.
    """
    row = await conn.fetchrow(
        f"DELETE FROM sos_alerts WHERE id = $1 RETURNING {_SELECT_COLUMNS}", alert_id
    )
    return _to_alert(row) if row is not None else None


async def delete_closed_for_sector(
    conn: asyncpg.Connection, sector_id: uuid.UUID
) -> list[uuid.UUID]:
    """Bulk 'clear the list': deletes every CLOSED (resolved/cancelled)
    alert in one sector, returning the ids removed.

    Open alerts are excluded at the SQL level rather than filtered by the
    caller. This is the operation most likely to be run in a hurry on a
    cluttered screen, and the one place where "clear everything" must never
    be able to mean "including the one someone is still waiting on".
    """
    rows = await conn.fetch(
        """
        DELETE FROM sos_alerts
        WHERE sector_id = $1 AND NOT (status = ANY($2::text[]))
        RETURNING id
        """,
        sector_id,
        list(OPEN_STATUSES),
    )
    return [row["id"] for row in rows]


async def list_for_sector(
    conn: asyncpg.Connection,
    sector_id: uuid.UUID,
    *,
    status_filter: str | None = None,
) -> list[SosAlert]:
    if status_filter is None:
        rows = await conn.fetch(
            f"""
            SELECT {_SELECT_COLUMNS} FROM sos_alerts
            WHERE sector_id = $1
            ORDER BY triggered_at DESC
            """,
            sector_id,
        )
    else:
        rows = await conn.fetch(
            f"""
            SELECT {_SELECT_COLUMNS} FROM sos_alerts
            WHERE sector_id = $1 AND status = $2
            ORDER BY triggered_at DESC
            """,
            sector_id,
            status_filter,
        )
    return [_to_alert(r) for r in rows]


async def get_for_sector(
    conn: asyncpg.Connection, sector_id: uuid.UUID, since: datetime | None = None
) -> list[SosAlert]:
    """Delta-since-checkpoint read for the realtime listener -- same shape
    as `presence_repo.get_for_sector`/`hex_contributions_repo.get_coverage_for_sector`."""
    if since is None:
        rows = await conn.fetch(
            f"SELECT {_SELECT_COLUMNS} FROM sos_alerts WHERE sector_id = $1",
            sector_id,
        )
    else:
        rows = await conn.fetch(
            f"""
            SELECT {_SELECT_COLUMNS} FROM sos_alerts
            WHERE sector_id = $1 AND updated_at > $2
            """,
            sector_id,
            since,
        )
    return [_to_alert(r) for r in rows]
