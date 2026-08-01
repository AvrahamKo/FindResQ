"""Sector symmetric-key storage (envelope-encrypted; see security/envelope.py)."""

from __future__ import annotations

import uuid
from dataclasses import dataclass
from datetime import datetime

import asyncpg


@dataclass(frozen=True, slots=True)
class SectorKeyRow:
    sector_id: uuid.UUID
    epoch: int
    key_wrapped: bytes
    created_at: datetime
    retired_at: datetime | None


async def insert(
    conn: asyncpg.Connection, sector_id: uuid.UUID, epoch: int, key_wrapped: bytes
) -> SectorKeyRow:
    row = await conn.fetchrow(
        """
        INSERT INTO sector_keys (sector_id, epoch, key_wrapped)
        VALUES ($1, $2, $3)
        RETURNING sector_id, epoch, key_wrapped, created_at, retired_at
        """,
        sector_id,
        epoch,
        key_wrapped,
    )
    return SectorKeyRow(**dict(row))


async def get(
    conn: asyncpg.Connection, sector_id: uuid.UUID, epoch: int
) -> SectorKeyRow | None:
    row = await conn.fetchrow(
        """
        SELECT sector_id, epoch, key_wrapped, created_at, retired_at
        FROM sector_keys
        WHERE sector_id = $1 AND epoch = $2
        """,
        sector_id,
        epoch,
    )
    return SectorKeyRow(**dict(row)) if row else None
