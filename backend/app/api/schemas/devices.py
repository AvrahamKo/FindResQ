from __future__ import annotations

import uuid
from datetime import datetime
from typing import Literal

from pydantic import BaseModel, Field

Platform = Literal["android", "ios"]


class KeyChallengeResponse(BaseModel):
    challenge_id: uuid.UUID
    # Base64 nonce the device must sign with its Ed25519 private key.
    nonce: str
    expires_at: datetime


class DeviceRegister(BaseModel):
    challenge_id: uuid.UUID
    public_key: str = Field(description="Base64-encoded 32-byte Ed25519 public key")
    signature: str = Field(description="Base64-encoded 64-byte signature over the raw nonce")
    platform: Platform
    label: str | None = Field(default=None, max_length=80)


class DeviceOut(BaseModel):
    id: uuid.UUID
    wire_id: int = Field(description="Compact 4-byte identifier used in mesh packets")
    public_key: str
    platform: Platform
    mesh_capable: bool
    label: str | None
    registered_at: datetime
    revoked_at: datetime | None
