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
from ..rbac import require_alert_moderator, require_lead_or_commander
from ..schemas.sos import SosDeleteResult, SosOut, SosTriggerRequest
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
    """Sector Manager (Lead) or event Commander ONLY -- never a field user.

    An acknowledgement is not a read receipt, it is a claim of
    responsibility: it moves the alert out of 'active' on every screen in
    the event, which is the signal command uses to decide the emergency is
    being handled. A searcher who taps it -- to be helpful, or by accident on
    a phone in a pocket -- silences the alarm for everyone while nobody has
    actually taken it on. Hence `require_alert_moderator` rather than mere
    sector membership.
    """
    existing = await sos_repo.get(conn, alert_id)
    if existing is None:
        raise NotFound("SOS alert not found")
    await require_alert_moderator(conn, existing.sector_id, user)

    alert = await sos_repo.acknowledge(conn, alert_id, by_user_id=user.id)
    if alert is None:
        raise Conflict("this SOS alert is not active")
    logger.info("SOS acknowledged id=%s by=%s", alert_id, user.id)
    return _to_out(alert)


@router.post("/sos/{alert_id}/resolve", response_model=SosOut)
async def resolve_sos(alert_id: uuid.UUID, user: CurrentUser, conn: ConnDep) -> SosOut:
    """Same gate as acknowledge, for the same reason -- resolving is the
    stronger claim of the two."""
    existing = await sos_repo.get(conn, alert_id)
    if existing is None:
        raise NotFound("SOS alert not found")
    await require_alert_moderator(conn, existing.sector_id, user)

    alert = await sos_repo.resolve(conn, alert_id, by_user_id=user.id)
    if alert is None:
        raise Conflict("this SOS alert is already resolved or cancelled")
    logger.info("SOS resolved id=%s by=%s", alert_id, user.id)
    return _to_out(alert)


@router.delete("/sos/{alert_id}", response_model=SosDeleteResult)
async def delete_sos(alert_id: uuid.UUID, user: CurrentUser, conn: ConnDep) -> SosDeleteResult:
    """Permanently clears one obsolete alert off the board.

    Refuses while the alert is still OPEN (active or acknowledged). An open
    SOS is someone asking for help who has not been stood down; the way to
    take it off the board is to `resolve` it (it was handled) or for the
    originating device to `cancel` it (false alarm) -- both of which record
    WHY it ended and by whom. Deletion is for tidying a list of alerts that
    are already over, and making it the shortcut for an inconvenient live
    alarm is exactly the affordance a life-safety tool must not offer.

    Removal reaches every connected client in realtime: the
    `sos_alerts_notify_deleted` trigger (migration 0008) fires a NOTIFY that
    the listener turns into a `sos_deleted` WebSocket message, because a
    deleted row cannot appear in the delta query every other update rides on.
    """
    existing = await sos_repo.get(conn, alert_id)
    if existing is None:
        raise NotFound("SOS alert not found")
    await require_alert_moderator(conn, existing.sector_id, user)

    if existing.status in sos_repo.OPEN_STATUSES:
        raise Conflict(
            f"this SOS alert is still {existing.status}; resolve it (or have the "
            "originating device cancel it) before clearing it"
        )

    deleted = await sos_repo.delete(conn, alert_id)
    if deleted is None:
        raise NotFound("SOS alert not found")

    logger.info(
        "SOS deleted id=%s sector_id=%s status=%s by=%s",
        alert_id, existing.sector_id, existing.status, user.id,
    )
    return SosDeleteResult(sector_id=existing.sector_id, deleted_ids=[alert_id])


@router.delete("/sectors/{sector_id}/sos", response_model=SosDeleteResult)
async def clear_closed_sos(
    sector_id: uuid.UUID, user: CurrentUser, conn: ConnDep
) -> SosDeleteResult:
    """Bulk 'clear the list': deletes every CLOSED alert in the sector.

    Open alerts are excluded in SQL, not filtered here -- see
    `sos_repo.delete_closed_for_sector`. Each deletion fires its own NOTIFY,
    so connected clients see the list empty out item by item without any
    special bulk message type.
    """
    await require_alert_moderator(conn, sector_id, user)

    deleted_ids = await sos_repo.delete_closed_for_sector(conn, sector_id)
    logger.info(
        "SOS list cleared sector_id=%s removed=%d by=%s",
        sector_id, len(deleted_ids), user.id,
    )
    return SosDeleteResult(sector_id=sector_id, deleted_ids=deleted_ids)
