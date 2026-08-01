"""User and OTP-challenge persistence."""

from __future__ import annotations

import uuid
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone

import asyncpg


@dataclass(frozen=True, slots=True)
class User:
    id: uuid.UUID
    phone_e164: str
    display_name: str
    verification_status: str
    verified_org: str | None
    disabled_at: datetime | None


@dataclass(frozen=True, slots=True)
class OtpChallenge:
    id: uuid.UUID
    phone_e164: str
    salt: bytes
    code_hash: bytes
    attempts: int
    expires_at: datetime
    consumed_at: datetime | None


def _to_user(row: asyncpg.Record) -> User:
    return User(
        id=row["id"],
        phone_e164=row["phone_e164"],
        display_name=row["display_name"],
        verification_status=row["verification_status"],
        verified_org=row["verified_org"],
        disabled_at=row["disabled_at"],
    )


async def get_by_id(conn: asyncpg.Connection, user_id: uuid.UUID) -> User | None:
    row = await conn.fetchrow(
        """
        SELECT id, phone_e164, display_name, verification_status,
               verified_org, disabled_at
        FROM users
        WHERE id = $1
        """,
        user_id,
    )
    return _to_user(row) if row else None


async def upsert_by_phone(
    conn: asyncpg.Connection, phone_e164: str, display_name: str
) -> tuple[User, bool]:
    """Return (user, created). Idempotent: re-verifying an OTP is not an error."""
    row = await conn.fetchrow(
        """
        INSERT INTO users (phone_e164, display_name)
        VALUES ($1, $2)
        ON CONFLICT (phone_e164) DO UPDATE
            SET display_name = COALESCE(NULLIF(EXCLUDED.display_name, ''),
                                        users.display_name)
        RETURNING id, phone_e164, display_name, verification_status,
                  verified_org, disabled_at,
                  (xmax = 0) AS created
        """,
        phone_e164,
        display_name,
    )
    return _to_user(row), row["created"]


async def seconds_since_last_challenge(
    conn: asyncpg.Connection, phone_e164: str
) -> float | None:
    """None when the number has never requested a code."""
    return await conn.fetchval(
        """
        SELECT EXTRACT(EPOCH FROM (now() - max(created_at)))
        FROM otp_challenges
        WHERE phone_e164 = $1
        """,
        phone_e164,
    )


async def create_otp_challenge(
    conn: asyncpg.Connection,
    phone_e164: str,
    salt: bytes,
    code_hash: bytes,
    ttl_seconds: int,
) -> OtpChallenge:
    expires_at = datetime.now(timezone.utc) + timedelta(seconds=ttl_seconds)

    # Requesting a new code invalidates any outstanding one for this number, so
    # an attacker cannot keep several guessable challenges alive at once.
    await conn.execute(
        """
        UPDATE otp_challenges
        SET consumed_at = now()
        WHERE phone_e164 = $1 AND consumed_at IS NULL
        """,
        phone_e164,
    )

    row = await conn.fetchrow(
        """
        INSERT INTO otp_challenges (phone_e164, salt, code_hash, expires_at)
        VALUES ($1, $2, $3, $4)
        RETURNING id, phone_e164, salt, code_hash, attempts, expires_at, consumed_at
        """,
        phone_e164,
        salt,
        code_hash,
        expires_at,
    )
    return OtpChallenge(**dict(row))


async def lock_otp_challenge(
    conn: asyncpg.Connection, challenge_id: uuid.UUID
) -> OtpChallenge | None:
    """Row-lock the challenge so concurrent guesses cannot share an attempt budget.

    Must be called inside a transaction.
    """
    row = await conn.fetchrow(
        """
        SELECT id, phone_e164, salt, code_hash, attempts, expires_at, consumed_at
        FROM otp_challenges
        WHERE id = $1
        FOR UPDATE
        """,
        challenge_id,
    )
    return OtpChallenge(**dict(row)) if row else None


async def record_failed_attempt(conn: asyncpg.Connection, challenge_id: uuid.UUID) -> int:
    return await conn.fetchval(
        """
        UPDATE otp_challenges
        SET attempts = attempts + 1
        WHERE id = $1
        RETURNING attempts
        """,
        challenge_id,
    )


async def consume_otp_challenge(conn: asyncpg.Connection, challenge_id: uuid.UUID) -> None:
    await conn.execute(
        "UPDATE otp_challenges SET consumed_at = now() WHERE id = $1",
        challenge_id,
    )
