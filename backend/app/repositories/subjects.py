"""Missing-person (subject) persistence.

This is third-party PII about someone who did not consent to the app, so every
row records who obtained consent and when, and a mandatory purge deadline. See
`purge_after` -- a background job (Phase 8, teardown) is responsible for
actually deleting rows past that timestamp; this module only enforces that the
field can never be null.
"""

from __future__ import annotations

import uuid
from dataclasses import dataclass
from datetime import datetime

import asyncpg

_COLUMNS = """
    id, event_id, display_name, age_years, description, medical_notes,
    photo_object_key, consent_obtained_by, consent_recorded_at,
    consent_basis, purge_after, purged_at
"""


@dataclass(frozen=True, slots=True)
class Subject:
    id: uuid.UUID
    event_id: uuid.UUID
    display_name: str
    age_years: int | None
    description: str | None
    medical_notes: str | None
    photo_object_key: str | None
    consent_obtained_by: uuid.UUID | None
    consent_recorded_at: datetime | None
    consent_basis: str | None
    purge_after: datetime
    purged_at: datetime | None


def _to_subject(row: asyncpg.Record) -> Subject:
    return Subject(**dict(row))


async def upsert(
    conn: asyncpg.Connection,
    *,
    event_id: uuid.UUID,
    display_name: str,
    age_years: int | None,
    description: str | None,
    medical_notes: str | None,
    photo_object_key: str | None,
    consent_obtained_by: uuid.UUID,
    consent_basis: str,
    purge_after: datetime,
) -> Subject:
    """One subject per event for the MVP -- multi-subject searches are a v2 concern."""
    row = await conn.fetchrow(
        f"""
        INSERT INTO subjects (
            event_id, display_name, age_years, description, medical_notes,
            photo_object_key, consent_obtained_by, consent_recorded_at,
            consent_basis, purge_after
        )
        VALUES ($1, $2, $3, $4, $5, $6, $7, now(), $8, $9)
        ON CONFLICT (event_id) DO UPDATE SET
            display_name = EXCLUDED.display_name,
            age_years = EXCLUDED.age_years,
            description = EXCLUDED.description,
            medical_notes = EXCLUDED.medical_notes,
            photo_object_key = EXCLUDED.photo_object_key,
            consent_obtained_by = EXCLUDED.consent_obtained_by,
            consent_recorded_at = now(),
            consent_basis = EXCLUDED.consent_basis,
            purge_after = EXCLUDED.purge_after
        RETURNING {_COLUMNS}
        """,
        event_id,
        display_name,
        age_years,
        description,
        medical_notes,
        photo_object_key,
        consent_obtained_by,
        consent_basis,
        purge_after,
    )
    return _to_subject(row)


async def get_for_event(conn: asyncpg.Connection, event_id: uuid.UUID) -> Subject | None:
    row = await conn.fetchrow(
        f"SELECT {_COLUMNS} FROM subjects WHERE event_id = $1 AND purged_at IS NULL",
        event_id,
    )
    return _to_subject(row) if row else None
