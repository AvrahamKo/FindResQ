"""Event persistence."""

from __future__ import annotations

import uuid
from dataclasses import dataclass
from datetime import datetime

import asyncpg

_COLUMNS = """
    id, name, commander_id, status, command_post_sms,
    session_ttl_hours, started_at, ended_at, created_at
"""


@dataclass(frozen=True, slots=True)
class Event:
    id: uuid.UUID
    name: str
    commander_id: uuid.UUID
    status: str
    command_post_sms: str | None
    session_ttl_hours: int
    started_at: datetime | None
    ended_at: datetime | None
    created_at: datetime


def _to_event(row: asyncpg.Record) -> Event:
    return Event(**dict(row))


async def create(
    conn: asyncpg.Connection,
    *,
    name: str,
    commander_id: uuid.UUID,
    command_post_sms: str | None,
    session_ttl_hours: int,
) -> Event:
    row = await conn.fetchrow(
        f"""
        INSERT INTO events (name, commander_id, command_post_sms, session_ttl_hours)
        VALUES ($1, $2, $3, $4)
        RETURNING {_COLUMNS}
        """,
        name,
        commander_id,
        command_post_sms,
        session_ttl_hours,
    )
    return _to_event(row)


async def get(conn: asyncpg.Connection, event_id: uuid.UUID) -> Event | None:
    row = await conn.fetchrow(f"SELECT {_COLUMNS} FROM events WHERE id = $1", event_id)
    return _to_event(row) if row else None


async def list_for_user(conn: asyncpg.Connection, user_id: uuid.UUID) -> list[Event]:
    """Events the user commands, plus events where they hold any membership."""
    rows = await conn.fetch(
        """
        SELECT DISTINCT
            e.id, e.name, e.commander_id, e.status, e.command_post_sms,
            e.session_ttl_hours, e.started_at, e.ended_at, e.created_at
        FROM events e
        LEFT JOIN sectors s ON s.event_id = e.id
        LEFT JOIN sector_memberships m ON m.sector_id = s.id AND m.user_id = $1
        WHERE e.commander_id = $1 OR m.user_id = $1
        ORDER BY e.created_at DESC
        """,
        user_id,
    )
    return [_to_event(row) for row in rows]


@dataclass(frozen=True, slots=True)
class DeletionSummary:
    """What a cascade delete is about to destroy, counted before it runs."""

    sectors: int
    memberships: int
    track_segments: int
    track_points: int
    hex_contributions: int
    reports: int
    sos_alerts: int


async def summarize_for_deletion(
    conn: asyncpg.Connection, event_id: uuid.UUID
) -> DeletionSummary:
    """Counts the rows an event's cascade delete will take with it.

    Must run before the delete, inside the same transaction -- afterwards
    there is nothing left to count. This is what lets the API answer "what
    did I just destroy?" with real numbers instead of an empty 204, which
    matters for the audit log of an irreversible operation.
    """
    row = await conn.fetchrow(
        """
        WITH s AS (SELECT id FROM sectors WHERE event_id = $1)
        SELECT
            (SELECT count(*) FROM s)                                          AS sectors,
            (SELECT count(*) FROM sector_memberships
              WHERE sector_id IN (SELECT id FROM s))                          AS memberships,
            (SELECT count(*) FROM track_segments
              WHERE sector_id IN (SELECT id FROM s))                          AS track_segments,
            (SELECT count(*) FROM track_points
              WHERE sector_id IN (SELECT id FROM s))                          AS track_points,
            (SELECT count(*) FROM hex_contributions
              WHERE sector_id IN (SELECT id FROM s))                          AS hex_contributions,
            (SELECT count(*) FROM reports
              WHERE sector_id IN (SELECT id FROM s))                          AS reports,
            (SELECT count(*) FROM sos_alerts
              WHERE sector_id IN (SELECT id FROM s))                          AS sos_alerts
        """,
        event_id,
    )
    return DeletionSummary(**dict(row))


async def delete(conn: asyncpg.Connection, event_id: uuid.UUID) -> list[uuid.UUID] | None:
    """Hard-deletes an event and, by FK cascade, everything under it.

    Returns the ids of the sectors that were destroyed (so the caller can
    purge per-sector in-memory state), or None if no such event existed.

    Every child table declares `ON DELETE CASCADE` back to `events` or to
    `sectors` (migration 0001), so this single statement purges sectors,
    sector keys, memberships, join codes, track segments/points, hex
    contributions, derived hex coverage, reports, device presence, SOS
    alerts and the subject record. That is deliberate: an application-side
    delete list would be a second, silently-drifting copy of the schema's
    own parent/child structure, and the failure mode of it drifting is
    orphaned rows nobody ever looks for again.

    The sector ids are read INSIDE the caller's transaction, before the
    delete, because afterwards there is nowhere left to read them from.
    """
    sector_ids = [
        row["id"]
        for row in await conn.fetch("SELECT id FROM sectors WHERE event_id = $1", event_id)
    ]
    deleted = await conn.fetchval(
        "DELETE FROM events WHERE id = $1 RETURNING id", event_id
    )
    return sector_ids if deleted is not None else None


async def set_status(
    conn: asyncpg.Connection,
    event_id: uuid.UUID,
    *,
    from_statuses: tuple[str, ...],
    to_status: str,
    timestamp_column: str | None = None,
) -> Event | None:
    """Guarded transition: only applies if the row is currently in `from_statuses`.

    Prevents e.g. double-teardown from racing two commander taps into two
    "event ended" pushes, and prevents starting an already-ended event.
    """
    ts_clause = f", {timestamp_column} = now()" if timestamp_column else ""
    row = await conn.fetchrow(
        f"""
        UPDATE events
        SET status = $2 {ts_clause}
        WHERE id = $1 AND status = ANY($3::text[])
        RETURNING {_COLUMNS}
        """,
        event_id,
        to_status,
        list(from_statuses),
    )
    return _to_event(row) if row else None
