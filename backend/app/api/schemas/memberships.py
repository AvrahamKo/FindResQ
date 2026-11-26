from __future__ import annotations

import uuid
from datetime import datetime
from typing import Literal

from pydantic import BaseModel, Field

from .sectors import SectorOut

MovementMode = Literal["walker", "vehicle"]


class JoinCodeCreate(BaseModel):
    ttl_seconds: int = Field(default=12 * 3600, ge=60, le=48 * 3600)
    max_uses: int | None = Field(default=None, ge=1)


class JoinCodeOut(BaseModel):
    code: str
    sector_id: uuid.UUID
    expires_at: datetime
    max_uses: int | None
    uses: int


class JoinRequest(BaseModel):
    code: str = Field(min_length=6, max_length=6, pattern=r"^\d{6}$")
    device_id: uuid.UUID
    movement_mode: MovementMode
    battery_pct: int = Field(ge=0, le=100)
    powerbank_attested: bool = False


class JoinResponse(BaseModel):
    membership_id: uuid.UUID
    sector_id: uuid.UUID
    status: str
    battery_warning: str | None = Field(
        default=None,
        description="Non-blocking warning shown to the volunteer; null when battery is healthy",
    )


class MembershipOut(BaseModel):
    id: uuid.UUID
    sector_id: uuid.UUID
    user_id: uuid.UUID
    device_id: uuid.UUID
    role: str
    movement_mode: MovementMode
    status: str
    approved_by: uuid.UUID | None
    approved_at: datetime | None
    revoked_at: datetime | None
    session_expires_at: datetime | None
    battery_at_join: int | None
    powerbank_attested: bool
    created_at: datetime
    # Populated on leadership roster/list responses. Kept optional because
    # the volunteer-facing single-membership endpoint does not need to expose
    # a second copy of data the caller already owns.
    display_name: str | None = None
    phone_e164: str | None = None


class MembershipUpdate(BaseModel):
    movement_mode: MovementMode


class SessionIssueResponse(BaseModel):
    access_token: str
    token_type: str = "Bearer"
    expires_at: datetime
    key_epoch: int
    sector_key: str = Field(description="Base64-encoded 32-byte sector key. Delivered once.")
    sector: SectorOut
