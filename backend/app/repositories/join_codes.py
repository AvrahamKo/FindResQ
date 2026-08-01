"""Short numeric join-code issuance and redemption."""

from __future__ import annotations

import secrets
import uuid
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone

import asyncpg

CODE_LENGTH = 6
_MAX_GENERATION_ATTEMPTS = 5


@dataclass(frozen=True, slots=True)
class JoinCode:
    code: str
    sector_id: uuid.UUID
    created_by: uuid.UUID
    expires_at: datetime
    max_uses: int | None
    uses: int
    revoked_at: datetime | None


def _to_join_code(row: asyncpg.Record) -> JoinCode:
    return JoinCode(**dict(row))


def _generate_code() -> str:
    return str(secrets.randbelow(10**CODE_LENGTH)).zfill(CODE_LENGTH)


async def create(
    conn: asyncpg.Connection,
    *,
    sector_id: uuid.UUID,
    created_by: uuid.UUID,
    ttl_seconds: int,
    max_uses: int | None,
) -> JoinCode:
    expires_at = datetime.now(timezone.utc) + timedelta(seconds=ttl_seconds)

    # `code` is the PK; a collision is astronomically unlikely at 10^6 codes
    # but not impossible, so retry a few times on conflict rather than crash.
    for _ in range(_MAX_GENERATION_ATTEMPTS):
        code = _generate_code()
        try:
            row = await conn.fetchrow(
                """
                INSERT INTO join_codes (code, sector_id, created_by, expires_at, max_uses)
                VALUES ($1, $2, $3, $4, $5)
                RETURNING code, sector_id, created_by, expires_at, max_uses, uses, revoked_at
                """,
                code,
                sector_id,
                created_by,
                expires_at,
                max_uses,
            )
        except asyncpg.UniqueViolationError:
            continue
        return _to_join_code(row)

    raise RuntimeError("could not generate a unique join code")


async def redeem(conn: asyncpg.Connection, code: str) -> JoinCode | None:
    """Atomically validate and increment use count in one statement, so two
    volunteers redeeming the same single-use code cannot both succeed."""
    row = await conn.fetchrow(
        """
        UPDATE join_codes
        SET uses = uses + 1
        WHERE code = $1
          AND revoked_at IS NULL
          AND expires_at > now()
          AND (max_uses IS NULL OR uses < max_uses)
        RETURNING code, sector_id, created_by, expires_at, max_uses, uses, revoked_at
        """,
        code,
    )
    return _to_join_code(row) if row else None


async def revoke(conn: asyncpg.Connection, code: str, sector_id: uuid.UUID) -> bool:
    result = await conn.execute(
        """
        UPDATE join_codes SET revoked_at = now()
        WHERE code = $1 AND sector_id = $2 AND revoked_at IS NULL
        """,
        code,
        sector_id,
    )
    return result.endswith("1")
