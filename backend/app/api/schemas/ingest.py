from __future__ import annotations

from pydantic import BaseModel, Field


class IngestRequest(BaseModel):
    blobs: list[str] = Field(
        min_length=1,
        max_length=2000,
        description=(
            "Base64-encoded XChaCha20-Poly1305 blobs: nonce(24) || ciphertext || tag(16). "
            "A large offline backlog should be sent as several batches rather than one huge one."
        ),
    )


class IngestResponse(BaseModel):
    accepted: int
    duplicate: int
    decrypt_failed: int
    signature_invalid: int
    wrong_device: int
    malformed: int
    segments_opened: int
    segments_extended: int
    segments_closed: int
    hexes_touched: int
