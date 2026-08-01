from __future__ import annotations

import uuid
from datetime import datetime

from pydantic import BaseModel, Field, field_validator

E164 = Field(pattern=r"^\+[1-9]\d{7,14}$", examples=["+972501234567"])


class OtpRequest(BaseModel):
    phone_e164: str = E164


class OtpRequestResponse(BaseModel):
    challenge_id: uuid.UUID
    expires_at: datetime
    # Populated only when ENV=local, so the flow is testable without an SMS
    # provider. Always null elsewhere.
    dev_code: str | None = None


class OtpVerify(BaseModel):
    challenge_id: uuid.UUID
    code: str = Field(min_length=6, max_length=6, pattern=r"^\d{6}$")
    display_name: str = Field(default="", max_length=120)

    @field_validator("display_name")
    @classmethod
    def _strip(cls, v: str) -> str:
        return v.strip()


class UserOut(BaseModel):
    id: uuid.UUID
    phone_e164: str
    display_name: str
    verification_status: str
    verified_org: str | None


class AuthTokenResponse(BaseModel):
    access_token: str
    token_type: str = "Bearer"
    expires_at: datetime
    user: UserOut
