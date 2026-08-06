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


# A membership in one of these statuses is over: the volunteer was turned
# down, removed, or swept up by event teardown. None of them is a reason to
# refuse a NEW request -- see create_or_reopen_pending.
TERMINAL_STATUSES = ("rejected", "revoked", "ended")

# The complement: a row in one of these represents a request that is still
# live, and a second one would be a genuine duplicate.
LIVE_STATUSES = ("pending", "approved")


async def create_or_reopen_pending(
    conn: asyncpg.Connection,
    *,
    sector_id: uuid.UUID,
    user_id: uuid.UUID,
    device_id: uuid.UUID,
    movement_mode: str,
    battery_at_join: int,
    powerbank_attested: bool,
) -> Membership | None:
    """Creates a pending request, or REOPENS a terminal one for the same
    (sector, device). Returns None if a live request already exists.

    UNIQUE(sector_id, device_id) is the right invariant -- one row per device
    per sector -- but a plain INSERT against it meant a rejection was
    permanent: the leftover 'rejected' row collided with every future
    attempt, so a volunteer turned away once (a mis-tap by a Lead, a wrong
    movement mode, a removal that was later reconsidered) could never ask
    again, from that handset, for the rest of the callout. That is the exact
    opposite of what a rejection should mean in a search where people arrive,
    leave and come back.

    So the conflict is resolved rather than raised, and the reopened row is
    reset to a genuinely fresh request: the previous approval trail
    (`approved_by`/`approved_at`/`revoked_at`), the issued key epoch and the
    old session window are all cleared, so nothing from the previous
    membership can be mistaken for a current grant. `role` resets to
    'volunteer' too -- a re-applying ex-Lead is re-approved as a volunteer
    and re-promoted deliberately, never silently.

    The `WHERE ... status = ANY(TERMINAL)` guard on the DO UPDATE is what
    keeps this from being a way to overwrite a LIVE request: a pending or
    approved row makes the upsert match nothing and return no row, which the
    route turns into the same 409 as before.
    """
    row = await conn.fetchrow(
        f"""
        INSERT INTO sector_memberships (
            sector_id, user_id, device_id, role, movement_mode,
            battery_at_join, powerbank_attested
        )
        VALUES ($1, $2, $3, 'volunteer', $4, $5, $6)
        ON CONFLICT (sector_id, device_id) DO UPDATE SET
            user_id            = EXCLUDED.user_id,
            role               = 'volunteer',
            movement_mode      = EXCLUDED.movement_mode,
            battery_at_join    = EXCLUDED.battery_at_join,
            powerbank_attested = EXCLUDED.powerbank_attested,
            status             = 'pending',
            key_epoch_issued   = NULL,
            approved_by        = NULL,
            approved_at        = NULL,
            revoked_at         = NULL,
            session_expires_at = NULL,
            created_at         = now()
        WHERE sector_memberships.status = ANY($7::text[])
        RETURNING {_COLUMNS}
        """,
        sector_id,
        user_id,
        device_id,
        movement_mode,
        battery_at_join,
        powerbank_attested,
        list(TERMINAL_STATUSES),
    )
    return _to_membership(row) if row else None


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


# Statuses that still grant READ access to an event/sector's data.
#
# 'approved' is the obvious one. 'ended' is included because event teardown
# sweeps every approved membership to 'ended' (see end_all_for_event), and a
# searcher who worked a callout should not lose the ability to look back at
# the sector they searched the moment the Commander closes it.
#
# Conspicuously absent: 'pending' (never approved -- nothing has been granted
# yet), 'rejected' and 'revoked'. Those last two are the whole point of
# removing someone: a revoked volunteer must lose visibility of the event's
# live data on their very next request, not merely lose the ability to write
# to it.
VISIBILITY_STATUSES = ("approved", "ended")


async def user_has_membership_in_event(
    conn: asyncpg.Connection, event_id: uuid.UUID, user_id: uuid.UUID
) -> bool:
    """Whether the user still has any access-granting membership in the event.

    Deliberately status-filtered. This gates `GET /events/{id}`, the sector
    list, and the WebSocket ticket, so a status-blind check here would leave
    a removed volunteer able to keep watching the event they were removed
    from -- which is precisely the access that revocation is supposed to end.
    """
    return await conn.fetchval(
        """
        SELECT EXISTS (
            SELECT 1 FROM sector_memberships m
            JOIN sectors s ON s.id = m.sector_id
            WHERE s.event_id = $1 AND m.user_id = $2
              AND m.status = ANY($3::text[])
        )
        """,
        event_id,
        user_id,
        list(VISIBILITY_STATUSES),
    )


async def list_for_event_user(
    conn: asyncpg.Connection, event_id: uuid.UUID, user_id: uuid.UUID
) -> list[Membership]:
    """Every membership this user holds anywhere in the event, any status --
    a user may be in several sectors, and removing them from the event has
    to reach all of them, not just the one the Commander happened to be
    looking at."""
    rows = await conn.fetch(
        f"""
        SELECT {_COLUMNS} FROM sector_memberships m
        WHERE m.user_id = $2
          AND m.sector_id IN (SELECT id FROM sectors WHERE event_id = $1)
        ORDER BY m.created_at
        """,
        event_id,
        user_id,
    )
    return [_to_membership(row) for row in rows]


async def revoke_all_for_user_in_event(
    conn: asyncpg.Connection, event_id: uuid.UUID, user_id: uuid.UUID
) -> int:
    """Removes a user from an entire event in one statement. Returns the
    number of memberships actually ended.

    The row is UPDATEd, never DELETEd. `track_segments`, `track_points`,
    `hex_contributions`, `reports` and `sos_alerts` all reference
    `users(id)`, and the coverage map's core question -- "who covered this
    hex, and when?" -- must stay answerable about someone who was removed.
    Removal ends access; it does not rewrite the search record.

    `session_expires_at = now()` is belt-and-braces alongside the status
    flip: `current_membership` (api/deps.py) rejects on either, so a session
    token stops working on its very next request even if some future code
    path learns to tolerate a non-'approved' status.
    """
    return await conn.fetchval(
        """
        WITH revoked AS (
            UPDATE sector_memberships m
            SET status = 'revoked', revoked_at = now(), session_expires_at = now()
            FROM sectors s
            WHERE m.sector_id = s.id
              AND s.event_id = $1
              AND m.user_id = $2
              AND m.status = ANY($3::text[])
            RETURNING m.id
        )
        SELECT count(*) FROM revoked
        """,
        event_id,
        user_id,
        list(LIVE_STATUSES),
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
