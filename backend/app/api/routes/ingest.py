"""POST /ingest -- the direct-upload path for a device's own buffered points.

Authenticated by the device's own session token (`CurrentSession`), which is
what makes this the *direct* path rather than a mesh-relay path: the
uploading device is always the originating device, never a relay carrying
someone else's traffic. See mesh/reassembly.py's module docstring for why the
relay case is intentionally out of scope for this phase.
"""

from __future__ import annotations

import base64
import logging

from fastapi import APIRouter, status

from ..deps import ConnDep, CurrentSession, SettingsDep
from ..schemas.ingest import IngestRequest, IngestResponse
from ...errors import Conflict, ValidationFailed
from ...ingest.pipeline import ingest_batch
from ...repositories import devices as devices_repo
from ...repositories import sector_keys as sector_keys_repo
from ...security import envelope

logger = logging.getLogger(__name__)

router = APIRouter(tags=["ingest"])


@router.post("/ingest", response_model=IngestResponse, status_code=status.HTTP_200_OK)
async def ingest(
    payload: IngestRequest, session: CurrentSession, conn: ConnDep, settings: SettingsDep
) -> IngestResponse:
    try:
        blobs = [base64.b64decode(b, validate=True) for b in payload.blobs]
    except Exception as exc:  # noqa: BLE001 - any malformed base64 is a client error
        raise ValidationFailed("one or more blobs are not valid base64") from exc

    device = await devices_repo.get(conn, session.claims.device_id)
    if device is None or device.revoked_at is not None:
        raise Conflict("device is no longer valid")

    key_row = await sector_keys_repo.get(conn, session.sector.id, session.sector.key_epoch)
    if key_row is None:
        raise Conflict("sector has no active key material")
    sector_key = envelope.unwrap(settings.sector_key_wrap_secret, key_row.key_wrapped)

    async with conn.transaction():
        result = await ingest_batch(
            conn,
            sector=session.sector,
            device_id=device.id,
            device_wire_id=device.wire_id,
            device_public_key=device.ed25519_public_key,
            user_id=session.claims.user_id,
            # Operational mode is live membership state, not a stale JWT
            # snapshot. A Lead may correct walker/vehicle from the dashboard
            # while the search is active; that edit closes the prior segment.
            movement_mode=session.membership.movement_mode,
            sector_key=sector_key,
            blobs=blobs,
        )

    logger.info(
        "ingest batch device_id=%s sector_id=%s accepted=%d duplicate=%d rejected=%d hexes=%d",
        device.id,
        session.sector.id,
        result.packets.accepted,
        result.packets.duplicate,
        result.packets.decrypt_failed
        + result.packets.signature_invalid
        + result.packets.wrong_device
        + result.packets.malformed,
        result.hexes_touched,
    )

    return IngestResponse(
        accepted=result.packets.accepted,
        duplicate=result.packets.duplicate,
        decrypt_failed=result.packets.decrypt_failed,
        signature_invalid=result.packets.signature_invalid,
        wrong_device=result.packets.wrong_device,
        malformed=result.packets.malformed,
        segments_opened=result.segments_opened,
        segments_extended=result.segments_extended,
        segments_closed=result.segments_closed,
        hexes_touched=result.hexes_touched,
    )
