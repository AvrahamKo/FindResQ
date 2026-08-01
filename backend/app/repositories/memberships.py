"""Sector membership lifecycle: pending -> approved/rejected, and revocation.

State transitions are guarded at the SQL level (`WHERE status = 'pending'`,
etc.) so two concurrent approve calls -- a Lead and a Commander clicking at
the same moment (Branch B) -- can't both succeed and double-issue a session.
"""

from __future__ import annotations

import uuid
from dataclasses import dataclass
from datetime import datetime

import asyncpg

_COLUMNS = """
    id, sector_id, user_id, device_id, role, movement_mode, status,
    key_epoch_issued, approved_by, approved_at, revoked_at,
    session_expires_at, battery_at_join, powerbank_attested, created_at
"""


@dataclass(frozen=True, slots=True)
class Membership:
    id: uuid.UUID
    sector_id: uuid.UUID
    user_id: uuid.UUID
    device_id: uuid.UUID
    role: str
    movement_mode: str
    status: str
    key_epoch_issued: int | None
    approved_by: uuid.UUID | None
    approved_at: datetime | None
    revoked_at: datetime | None
    session_expires_at: datetime | None
    battery_at_join: int | None
    powerbank_attested: bool
    created_at: datetime


def _to_membership(row: asyncpg.Record) -> Membership:
    return Membership(**dict(row))


async def create_pending(
    conn: asyncpg.Connection,
    *,
    sector_id: uuid.UUID,
    user_id: uuid.UUID,
    device_id: uuid.UUID,
    movement_mode: str,
    battery_at_join: int,
    powerbank_attested: bool,
) -> Membership:
    """UNIQUE(sector_id, device_id) makes re-joining with the same device
    idempotent-ish: a second attempt raises UniqueViolationError, which the
    route layer turns into "you already have a request for this sector"."""
    row = await conn.fetchrow(
        f"""
        INSERT INTO sector_memberships (
            sector_id, user_id, device_id, role, movement_mode,
            battery_at_join, powerbank_attested
        )
        VALUES ($1, $2, $3, 'volunteer', $4, $5, $6)
        RETURNING {_COLUMNS}
        """,
        sector_id,
        user_id,
        device_id,
        movement_mode,
        battery_at_join,
        powerbank_attested,
    )
    return _to_membership(row)


async def get(conn: asyncpg.Connection, membership_id: uuid.UUID) -> Membership | None:
    row = await conn.fetchrow(
        f"SELECT {_COLUMNS} FROM sector_memberships WHERE id = $1", membership_id
    )
    return _to_membership(row) if row else None


async def get_by_device(
    conn: asyncpg.Connection, sector_id: uuid.UUID, device_id: uuid.UUID
) -> Membership | None:
    row = await conn.fetchrow(
        f"""
        SELECT {_COLUMNS} FROM sector_memberships
        WHERE sector_id = $1 AND device_id = $2
        """,
        sector_id,
        device_id,
    )
    return _to_membership(row) if row else None


async def get_by_user(
    conn: asyncpg.Connection, sector_id: uuid.UUID, user_id: uuid.UUID
) -> Membership | None:
    """A user has at most one *approved* row per sector in practice (each
    device gets its own row, but a person typically searches with one phone).
    Prefers an approved row; falls back to the most recent otherwise, so a
    pending/rejected request doesn't hide an existing approved one."""
    row = await conn.fetchrow(
        f"""
        SELECT {_COLUMNS} FROM sector_memberships
        WHERE sector_id = $1 AND user_id = $2
        ORDER BY (status = 'approved') DESC, created_at DESC
        LIMIT 1
        """,
        sector_id,
        user_id,
    )
    return _to_membership(row) if row else None


async def get_current_lead_membership(
    conn: asyncpg.Connection, sector_id: uuid.UUID
) -> Membership | None:
    row = await conn.fetchrow(
        f"""
        SELECT {_COLUMNS} FROM sector_memberships
        WHERE sector_id = $1 AND role = 'lead' AND status = 'approved'
        """,
        sector_id,
    )
    return _to_membership(row) if row else None


async def list_for_sector(
    conn: asyncpg.Connection, sector_id: uuid.UUID, status: str | None = None
) -> list[Membership]:
    if status is None:
        rows = await conn.fetch(
            f"SELECT {_COLUMNS} FROM sector_memberships WHERE sector_id = $1 "
            "ORDER BY created_at",
            sector_id,
        )
    else:
        rows = await conn.fetch(
            f"SELECT {_COLUMNS} FROM sector_memberships "
            "WHERE sector_id = $1 AND status = $2 ORDER BY created_at",
            sector_id,
            status,
        )
    return [_to_membership(row) for row in rows]


async def approve(
    conn: asyncpg.Connection,
    membership_id: uuid.UUID,
    *,
    approved_by: uuid.UUID,
    key_epoch: int,
    session_expires_at: datetime,
) -> Membership | None:
    row = await conn.fetchrow(
        f"""
        UPDATE sector_memberships
        SET status = 'approved', approved_by = $2, approved_at = now(),
            key_epoch_issued = $3, session_expires_at = $4
        WHERE id = $1 AND status = 'pending'
        RETURNING {_COLUMNS}
        """,
        membership_id,
        approved_by,
        key_epoch,
        session_expires_at,
    )
    return _to_membership(row) if row else None


async def reject(
    conn: asyncpg.Connection, membership_id: uuid.UUID
) -> Membership | None:
    row = await conn.fetchrow(
        f"""
        UPDATE sector_memberships
        SET status = 'rejected'
        WHERE id = $1 AND status = 'pending'
        RETURNING {_COLUMNS}
        """,
        membership_id,
    )
    return _to_membership(row) if row else None


async def revoke(
    conn: asyncpg.Connection, membership_id: uuid.UUID
) -> Membership | None:
    """Revokes an approved membership. Does not rotate the sector key --
    the revoked device retains it until the key epoch is bumped (parked P1:
    true revocation requires re-keying the whole sector). What this DOES do
    immediately is fail `current_membership`'s status check on the very next
    request, ending the device's ability to submit new telemetry or reports."""
    row = await conn.fetchrow(
        f"""
        UPDATE sector_memberships
        SET status = 'revoked', revoked_at = now()
        WHERE id = $1 AND status = 'approved'
        RETURNING {_COLUMNS}
        """,
        membership_id,
    )
    return _to_membership(row) if row else None


async def set_key_epoch(
    conn: asyncpg.Connection, membership_id: uuid.UUID, key_epoch: int
) -> None:
    """Keeps `key_epoch_issued` truthful if the sector is re-keyed between
    approval and the device actually claiming its session (see claim_session
    in routes/memberships.py)."""
    await conn.execute(
        "UPDATE sector_memberships SET key_epoch_issued = $2 WHERE id = $1",
        membership_id,
        key_epoch,
    )


async def user_has_membership_in_event(
    conn: asyncpg.Connection, event_id: uuid.UUID, user_id: uuid.UUID
) -> bool:
    return await conn.fetchval(
        """
        SELECT EXISTS (
            SELECT 1 FROM sector_memberships m
            JOIN sectors s ON s.id = m.sector_id
            WHERE s.event_id = $1 AND m.user_id = $2
        )
        """,
        event_id,
        user_id,
    )


async def set_role(
    conn: asyncpg.Connection, membership_id: uuid.UUID, role: str
) -> Membership | None:
    row = await conn.fetchrow(
        f"""
        UPDATE sector_memberships SET role = $2
        WHERE id = $1
        RETURNING {_COLUMNS}
        """,
        membership_id,
        role,
    )
    return _to_membership(row) if row else None


async def end_all_for_event(conn: asyncpg.Connection, event_id: uuid.UUID) -> None:
    """Event teardown: force every live session to fail its next status check,
    regardless of whether the device is online to receive the push (Q9)."""
    await conn.execute(
        """
        UPDATE sector_memberships m
        SET status = 'ended', session_expires_at = now()
        FROM sectors s
        WHERE m.sector_id = s.id AND s.event_id = $1 AND m.status = 'approved'
        """,
        event_id,
    )
