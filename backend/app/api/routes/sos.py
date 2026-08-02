"""SOS: a searcher-triggered distress signal, explicit and immediate --
independent of Phase 4's passive correlated-silence presence heuristic.

Trigger/cancel use the device's own SECTOR SESSION token (`CurrentSession`,
same as `/ingest`): this is the searcher acting as themselves, from their
own device, exactly like uploading their own telemetry. Acknowledge/resolve
use the ACCOUNT token (`CurrentUser`) plus a Lead/Commander role check, same
as membership moderation in `routes/memberships.py` -- those actions happen
on a DIFFERENT device (the Sector Lead's), not the volunteer's.
"""

from __future__ import annotations

import logging
import uuid
from dataclasses import asdict

from fastapi import APIRouter, status

from ..deps import ConnDep, CurrentSession, CurrentUser
from ..rbac import require_lead_or_commander
from ..schemas.sos import SosOut, SosTriggerRequest
from ...errors import Conflict, Forbidden, NotFound
from ...repositories import presence as presence_repo
from ...repositories import sos as sos_repo

logger = logging.getLogger(__name__)

router = APIRouter(tags=["sos"])


def _to_out(alert: sos_repo.SosAlert) -> SosOut:
    return SosOut(**asdict(alert))


@router.post("/sos", response_model=SosOut, status_code=status.HTTP_201_CREATED)
async def trigger_sos(
    payload: SosTriggerRequest, session: CurrentSession, conn: ConnDep
) -> SosOut:
    lat, lng = payload.lat, payload.lng
    if lat is None or lng is None:
        # Falls back to the device's own last-known presence point rather
        # than requiring a fresh GPS fix before SOS can even be sent -- a
        # searcher hitting SOS is exactly the moment a fresh fix might not
        # have landed yet (canyon, indoors, dead zone), so this is the
        # expected path, not a rare edge case.
        presence = await presence_repo.get_for_device(conn, session.claims.device_id)
        if presence is not None:
            lat, lng = presence.last_lat, presence.last_lng

    alert = await sos_repo.trigger(
        conn,
        sector_id=session.sector.id,
        device_id=session.claims.device_id,
        user_id=session.claims.user_id,
        lat=lat,
        lng=lng,
    )
    logger.info(
        "SOS triggered id=%s sector_id=%s device_id=%s",
        alert.id, session.sector.id, session.claims.device_id,
    )
    return _to_out(alert)


@router.post("/sos/{alert_id}/cancel", response_model=SosOut)
async def cancel_sos(
    alert_id: uuid.UUID, session: CurrentSession, conn: ConnDep
) -> SosOut:
    existing = await sos_repo.get(conn, alert_id)
    if existing is None:
        raise NotFound("SOS alert not found")
    if existing.device_id != session.claims.device_id:
        raise Forbidden("only the device that triggered this SOS can cancel it")

    alert = await sos_repo.cancel(conn, alert_id)
    if alert is None:
        raise Conflict("this SOS alert is already resolved or cancelled")
    logger.info("SOS cancelled id=%s by device_id=%s", alert_id, session.claims.device_id)
    return _to_out(alert)


@router.get("/sectors/{sector_id}/sos", response_model=list[SosOut])
async def list_sector_sos(
    sector_id: uuid.UUID,
    user: CurrentUser,
    conn: ConnDep,
    status_filter: str | None = None,
) -> list[SosOut]:
    await require_lead_or_commander(conn, sector_id, user)
    rows = await sos_repo.list_for_sector(conn, sector_id, status_filter=status_filter)
    return [_to_out(r) for r in rows]


@router.post("/sos/{alert_id}/acknowledge", response_model=SosOut)
async def acknowledge_sos(alert_id: uuid.UUID, user: CurrentUser, conn: ConnDep) -> SosOut:
    existing = await sos_repo.get(conn, alert_id)
    if existing is None:
        raise NotFound("SOS alert not found")
    await require_lead_or_commander(conn, existing.sector_id, user)

    alert = await sos_repo.acknowledge(conn, alert_id, by_user_id=user.id)
    if alert is None:
        raise Conflict("this SOS alert is not active")
    logger.info("SOS acknowledged id=%s by=%s", alert_id, user.id)
    return _to_out(alert)


@router.post("/sos/{alert_id}/resolve", response_model=SosOut)
async def resolve_sos(alert_id: uuid.UUID, user: CurrentUser, conn: ConnDep) -> SosOut:
    existing = await sos_repo.get(conn, alert_id)
    if existing is None:
        raise NotFound("SOS alert not found")
    await require_lead_or_commander(conn, existing.sector_id, user)

    alert = await sos_repo.resolve(conn, alert_id, by_user_id=user.id)
    if alert is None:
        raise Conflict("this SOS alert is already resolved or cancelled")
    logger.info("SOS resolved id=%s by=%s", alert_id, user.id)
    return _to_out(alert)
