from __future__ import annotations

import uuid
from datetime import datetime

from pydantic import BaseModel, Field


class ReportIngestRequest(BaseModel):
    blobs: list[str] = Field(
        min_length=1,
        max_length=200,
        description=(
            "Base64-encoded XChaCha20-Poly1305 blobs: nonce(24) || ciphertext || tag(16), "
            "each decrypting to a report_format payload || 64-byte Ed25519 signature."
        ),
    )


class ReportIngestResponse(BaseModel):
    accepted: int
    duplicate: int
    decrypt_failed: int
    signature_invalid: int
    wrong_device: int
    malformed: int


class ReportOut(BaseModel):
    id: uuid.UUID
    sector_id: uuid.UUID
    device_id: uuid.UUID
    user_id: uuid.UUID
    kind: str
    lat: float
    lng: float
    note: str | None
    recorded_at: datetime
    received_at: datetime
    delivery_path: str
    status: str
    acknowledged_by: uuid.UUID | None
    acknowledged_at: datetime | None
    updated_at: datetime
