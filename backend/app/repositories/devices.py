"""Device and device-key-challenge persistence."""

from __future__ import annotations

import secrets
import uuid
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone

import asyncpg

NONCE_BYTES = 32


@dataclass(frozen=True, slots=True)
class Device:
    id: uuid.UUID
    user_id: uuid.UUID
    wire_id: int
    ed25519_public_key: bytes
    platform: str
    mesh_capable: bool
    label: str | None
    registered_at: datetime
    revoked_at: datetime | None


@dataclass(frozen=True, slots=True)
class KeyChallenge:
    id: uuid.UUID
    user_id: uuid.UUID
    nonce: bytes
    expires_at: datetime
    consumed_at: datetime | None


_DEVICE_COLUMNS = """
    id, user_id, wire_id, ed25519_public_key, platform,
    mesh_capable, label, registered_at, revoked_at
"""


def _to_device(row: asyncpg.Record) -> Device:
    return Device(**dict(row))


async def create_key_challenge(
    conn: asyncpg.Connection, user_id: uuid.UUID, ttl_seconds: int
) -> KeyChallenge:
    expires_at = datetime.now(timezone.utc) + timedelta(seconds=ttl_seconds)
    row = await conn.fetchrow(
        """
        INSERT INTO device_key_challenges (user_id, nonce, expires_at)
        VALUES ($1, $2, $3)
        RETURNING id, user_id, nonce, expires_at, consumed_at
        """,
        user_id,
        secrets.token_bytes(NONCE_BYTES),
        expires_at,
    )
    return KeyChallenge(**dict(row))


async def claim_key_challenge(
    conn: asyncpg.Connection, challenge_id: uuid.UUID, user_id: uuid.UUID
) -> KeyChallenge | None:
    """Atomically consume an unexpired, unconsumed challenge owned by this user.

    Single-statement so a replayed registration cannot consume it twice.
    """
    row = await conn.fetchrow(
        """
        UPDATE device_key_challenges
        SET consumed_at = now()
        WHERE id = $1
          AND user_id = $2
          AND consumed_at IS NULL
          AND expires_at > now()
        RETURNING id, user_id, nonce, expires_at, consumed_at
        """,
        challenge_id,
        user_id,
    )
    return KeyChallenge(**dict(row)) if row else None


async def get(conn: asyncpg.Connection, device_id: uuid.UUID) -> Device | None:
    row = await conn.fetchrow(
        f"SELECT {_DEVICE_COLUMNS} FROM devices WHERE id = $1", device_id
    )
    return _to_device(row) if row else None


async def get_by_public_key(
    conn: asyncpg.Connection, public_key: bytes
) -> Device | None:
    row = await conn.fetchrow(
        f"SELECT {_DEVICE_COLUMNS} FROM devices WHERE ed25519_public_key = $1",
        public_key,
    )
    return _to_device(row) if row else None


async def create(
    conn: asyncpg.Connection,
    *,
    user_id: uuid.UUID,
    public_key: bytes,
    platform: str,
    mesh_capable: bool,
    label: str | None,
) -> Device:
    row = await conn.fetchrow(
        f"""
        INSERT INTO devices (user_id, ed25519_public_key, platform,
                             mesh_capable, label)
        VALUES ($1, $2, $3, $4, $5)
        RETURNING {_DEVICE_COLUMNS}
        """,
        user_id,
        public_key,
        platform,
        mesh_capable,
        label,
    )
    return _to_device(row)


async def list_for_user(conn: asyncpg.Connection, user_id: uuid.UUID) -> list[Device]:
    rows = await conn.fetch(
        f"""
        SELECT {_DEVICE_COLUMNS}
        FROM devices
        WHERE user_id = $1
        ORDER BY registered_at DESC
        """,
        user_id,
    )
    return [_to_device(row) for row in rows]


async def revoke(
    conn: asyncpg.Connection, device_id: uuid.UUID, user_id: uuid.UUID
) -> Device | None:
    """Soft-revoke. Rows are never deleted: `track_points` references devices,
    and a revoked device's historical coverage must remain attributable."""
    row = await conn.fetchrow(
        f"""
        UPDATE devices
        SET revoked_at = COALESCE(revoked_at, now())
        WHERE id = $1 AND user_id = $2
        RETURNING {_DEVICE_COLUMNS}
        """,
        device_id,
        user_id,
    )
    return _to_device(row) if row else None
