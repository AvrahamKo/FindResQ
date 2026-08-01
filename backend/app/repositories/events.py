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
