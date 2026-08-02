"""Report ingest: decrypt -> verify -> dedup -> store. Mirrors
`app/ingest/pipeline.py`'s stage shape for track points, deliberately much
simpler -- a report has no segmentation, coverage, or presence side effects,
just a signed fact recorded once (or rejected/deduplicated).
"""

from __future__ import annotations

import uuid
from dataclasses import dataclass
from datetime import datetime, timezone

import asyncpg

from ..mesh import report_format
from ..repositories import reports as reports_repo
from ..repositories.sectors import Sector
from ..security import mesh_crypto, signatures


@dataclass
class ReportOutcome:
    accepted: int = 0
    duplicate: int = 0
    decrypt_failed: int = 0
    signature_invalid: int = 0
    wrong_device: int = 0
    malformed: int = 0


def _to_datetime(ms: int) -> datetime:
    return datetime.fromtimestamp(ms / 1000, tz=timezone.utc)


async def ingest_reports(
    conn: asyncpg.Connection,
    *,
    sector: Sector,
    device_id: uuid.UUID,
    device_wire_id: int,
    device_public_key: bytes,
    user_id: uuid.UUID,
    sector_key: bytes,
    blobs: list[bytes],
) -> ReportOutcome:
    outcome = ReportOutcome()

    for blob in blobs:
        try:
            plaintext = mesh_crypto.decrypt(sector_key, blob)
        except mesh_crypto.MeshCryptoError:
            outcome.decrypt_failed += 1
            continue

        if len(plaintext) < report_format.HEADER_BYTES + signatures.ED25519_SIGNATURE_BYTES:
            outcome.malformed += 1
            continue

        try:
            note_len = report_format.peek_note_length(plaintext)
        except report_format.ReportWireFormatError:
            outcome.malformed += 1
            continue

        payload_len = report_format.HEADER_BYTES + note_len
        if len(plaintext) != payload_len + signatures.ED25519_SIGNATURE_BYTES:
            outcome.malformed += 1
            continue

        payload_bytes = plaintext[:payload_len]
        signature = plaintext[payload_len:]

        try:
            payload = report_format.unpack(payload_bytes)
        except report_format.ReportWireFormatError:
            outcome.malformed += 1
            continue

        # Direct-upload scope, same as location ingest: a device may only
        # submit reports signed as itself.
        if payload.wire_id != device_wire_id:
            outcome.wrong_device += 1
            continue

        if not signatures.verify(device_public_key, payload_bytes, signature):
            outcome.signature_invalid += 1
            continue

        try:
            await reports_repo.create(
                conn,
                sector_id=sector.id,
                device_id=device_id,
                user_id=user_id,
                kind=payload.kind,
                lat=payload.lat,
                lng=payload.lng,
                note=payload.note or None,
                recorded_at=_to_datetime(payload.recorded_at_ms),
                delivery_path="direct",
                signature=signature,
            )
            outcome.accepted += 1
        except asyncpg.UniqueViolationError:
            outcome.duplicate += 1

    return outcome
