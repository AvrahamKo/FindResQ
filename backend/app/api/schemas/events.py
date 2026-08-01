from __future__ import annotations

import uuid
from datetime import datetime

from pydantic import BaseModel, Field, field_validator

PHONE_PATTERN = r"^\+[1-9]\d{7,14}$"


class EventCreate(BaseModel):
    name: str = Field(min_length=1, max_length=200)
    command_post_sms: str | None = Field(default=None, pattern=PHONE_PATTERN)
    session_ttl_hours: int = Field(default=14, ge=1, le=48)


class EventOut(BaseModel):
    id: uuid.UUID
    name: str
    commander_id: uuid.UUID
    status: str
    command_post_sms: str | None
    session_ttl_hours: int
    started_at: datetime | None
    ended_at: datetime | None
    created_at: datetime


class SubjectUpsert(BaseModel):
    display_name: str = Field(min_length=1, max_length=200)
    age_years: int | None = Field(default=None, ge=0, le=130)
    description: str | None = Field(default=None, max_length=2000)
    medical_notes: str | None = Field(default=None, max_length=2000)
    photo_object_key: str | None = Field(default=None, max_length=500)
    consent_basis: str = Field(
        min_length=1,
        max_length=500,
        description="Who consented and how, e.g. 'verbal, family, by phone'",
    )
    retention_days: int = Field(
        default=30,
        ge=1,
        le=180,
        description="Days after which this record must be purged",
    )

    @field_validator("display_name", "consent_basis")
    @classmethod
    def _strip(cls, v: str) -> str:
        return v.strip()


class SubjectOut(BaseModel):
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
