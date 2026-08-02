"""Join-code issuance/redemption and the membership approval lifecycle.

The flow is deliberately three separate calls, not one:

  1. POST /join                                  (volunteer's own account token)
     -> creates a 'pending' row. The volunteer's phone does NOT get a session
        yet -- it has no idea whether the Lead is even awake.
  2. POST /memberships/{id}/approve               (Lead or Commander)
     -> flips the row to 'approved'. This happens on the LEAD's phone, not the
        volunteer's -- there is no synchronous response path back to the
        person who is waiting.
  3. POST /memberships/{id}/session               (the SAME volunteer, polling)
     -> issues the session token and hands over the raw sector key, once,
        over TLS, for storage in the device's Secure Storage.

Splitting (2) and (3) is what makes approval possible without the volunteer's
device being reachable at approval time -- exactly the offline-first
constraint this app is built around.
"""

from __future__ import annotations

import base64
import logging
import uuid
from dataclasses import asdict
from datetime import datetime, timedelta, timezone

import asyncpg
from fastapi import APIRouter, status

from ..deps import ConnDep, CurrentUser, SettingsDep
from ..rbac import require_lead_or_commander
from .sectors import _to_out as _sector_to_out
from ..schemas.memberships import (
    JoinCodeCreate,
    JoinCodeOut,
    JoinRequest,
    JoinResponse,
    MembershipOut,
    SessionIssueResponse,
)
from ...errors import Conflict, Forbidden, NotFound, Unauthorized, ValidationFailed
from ...repositories import devices as devices_repo
from ...repositories import events as events_repo
from ...repositories import join_codes as join_codes_repo
from ...repositories import memberships as memberships_repo
from ...repositories import sector_keys as sector_keys_repo
from ...repositories import sectors as sectors_repo
from ...security import envelope
from ...security.tokens import issue_session_token

logger = logging.getLogger(__name__)

router = APIRouter(tags=["memberships"])


def _membership_to_out(m: memberships_repo.Membership) -> MembershipOut:
    return MembershipOut(**asdict(m))


# --- Join codes --------------------------------------------------------------


@router.post(
    "/sectors/{sector_id}/join-codes",
    response_model=JoinCodeOut,
    status_code=status.HTTP_201_CREATED,
)
async def create_join_code(
    sector_id: uuid.UUID, payload: JoinCodeCreate, user: CurrentUser, conn: ConnDep
) -> JoinCodeOut:
    await require_lead_or_commander(conn, sector_id, user)
    code = await join_codes_repo.create(
        conn,
        sector_id=sector_id,
        created_by=user.id,
        ttl_seconds=payload.ttl_seconds,
        max_uses=payload.max_uses,
    )
    logger.info("join code created sector_id=%s by=%s", sector_id, user.id)
    return JoinCodeOut(**asdict(code))


@router.delete(
    "/sectors/{sector_id}/join-codes/{code}",
    status_code=status.HTTP_204_NO_CONTENT,
    response_model=None,
)
async def revoke_join_code(
    sector_id: uuid.UUID, code: str, user: CurrentUser, conn: ConnDep
) -> None:
    await require_lead_or_commander(conn, sector_id, user)
    if not await join_codes_repo.revoke(conn, code, sector_id):
        raise NotFound("join code not found or already revoked")


# --- Joining -------------------------------------------------------------


@router.post("/join", response_model=JoinResponse, status_code=status.HTTP_201_CREATED)
async def join_sector(
    payload: JoinRequest, user: CurrentUser, conn: ConnDep, settings: SettingsDep
) -> JoinResponse:
    device = await devices_repo.get(conn, payload.device_id)
    if device is None or device.user_id != user.id:
        raise Forbidden("this device is not registered to you")
    if device.revoked_at is not None:
        raise Forbidden("this device has been revoked; register a new one")

    # Q8 join-time enforcement: hard block below the low threshold unless the
    # volunteer explicitly attests to a power bank. A dead phone mid-sector is
    # worse than one that never deployed -- its track just stops with no
    # explanation on the coverage map.
    if (
        payload.battery_pct <= settings.battery_block_threshold_pct
        and not payload.powerbank_attested
    ):
        raise ValidationFailed(
            f"battery is at or below {settings.battery_block_threshold_pct}%; "
            "connect a power bank and confirm to proceed"
        )

    join_code = await join_codes_repo.redeem(conn, payload.code)
    if join_code is None:
        # One opaque error for every rejection reason, same as the OTP flow --
        # a caller must not learn whether the code never existed, expired, or
        # is used up.
        raise Unauthorized("invalid or expired join code")

    swe = await sectors_repo.get_with_event(conn, join_code.sector_id)
    if swe is None or swe.sector.status != "open" or swe.event_status != "active":
        raise Conflict("this sector is not currently accepting volunteers")

    try:
        membership = await memberships_repo.create_pending(
            conn,
            sector_id=swe.sector.id,
            user_id=user.id,
            device_id=device.id,
            movement_mode=payload.movement_mode,
            battery_at_join=payload.battery_pct,
            powerbank_attested=payload.powerbank_attested,
        )
    except asyncpg.UniqueViolationError as exc:
        raise Conflict("you already have a request for this sector on this device") from exc

    warning = None
    if payload.battery_pct <= settings.battery_warn_threshold_pct:
        warning = f"Battery is at {payload.battery_pct}%. Consider a power bank."

    logger.info(
        "join request created membership_id=%s sector_id=%s user=%s",
        membership.id, swe.sector.id, user.id,
    )
    return JoinResponse(
        membership_id=membership.id,
        sector_id=swe.sector.id,
        status=membership.status,
        battery_warning=warning,
    )


# --- Membership visibility & moderation --------------------------------------


async def _require_membership_visibility(
    conn: ConnDep, membership_id: uuid.UUID, user: CurrentUser
) -> memberships_repo.Membership:
    membership = await memberships_repo.get(conn, membership_id)
    if membership is None:
        raise NotFound("membership not found")
    if membership.user_id == user.id:
        return membership
    # Raises Forbidden/NotFound itself if the caller is neither the sector's
    # lead nor the event's commander.
    await require_lead_or_commander(conn, membership.sector_id, user)
    return membership


@router.get("/memberships/{membership_id}", response_model=MembershipOut)
async def get_membership(
    membership_id: uuid.UUID, user: CurrentUser, conn: ConnDep
) -> MembershipOut:
    membership = await _require_membership_visibility(conn, membership_id, user)
    return _membership_to_out(membership)


@router.get("/sectors/{sector_id}/memberships", response_model=list[MembershipOut])
async def list_memberships(
    sector_id: uuid.UUID,
    user: CurrentUser,
    conn: ConnDep,
    status_filter: str | None = None,
) -> list[MembershipOut]:
    await require_lead_or_commander(conn, sector_id, user)
    rows = await memberships_repo.list_for_sector(conn, sector_id, status_filter)
    return [_membership_to_out(m) for m in rows]


@router.post("/memberships/{membership_id}/approve", response_model=MembershipOut)
async def approve_membership(
    membership_id: uuid.UUID, user: CurrentUser, conn: ConnDep
) -> MembershipOut:
    pending = await memberships_repo.get(conn, membership_id)
    if pending is None:
        raise NotFound("membership not found")

    swe = await require_lead_or_commander(conn, pending.sector_id, user)

    event = await events_repo.get(conn, swe.sector.event_id)
    if event is None:
        raise NotFound("event not found")  # unreachable: get_with_event already joined it
    session_expires_at = datetime.now(timezone.utc) + timedelta(hours=event.session_ttl_hours)

    membership = await memberships_repo.approve(
        conn,
        membership_id,
        approved_by=user.id,
        key_epoch=swe.sector.key_epoch,
        session_expires_at=session_expires_at,
    )
    if membership is None:
        raise Conflict("membership is not pending")

    logger.info("membership approved id=%s by=%s", membership_id, user.id)
    return _membership_to_out(membership)


@router.post("/memberships/{membership_id}/reject", response_model=MembershipOut)
async def reject_membership(
    membership_id: uuid.UUID, user: CurrentUser, conn: ConnDep
) -> MembershipOut:
    pending = await memberships_repo.get(conn, membership_id)
    if pending is None:
        raise NotFound("membership not found")
    await require_lead_or_commander(conn, pending.sector_id, user)

    membership = await memberships_repo.reject(conn, membership_id)
    if membership is None:
        raise Conflict("membership is not pending")
    return _membership_to_out(membership)


@router.post("/memberships/{membership_id}/revoke", response_model=MembershipOut)
async def revoke_membership(
    membership_id: uuid.UUID, user: CurrentUser, conn: ConnDep
) -> MembershipOut:
    existing = await memberships_repo.get(conn, membership_id)
    if existing is None:
        raise NotFound("membership not found")
    await require_lead_or_commander(conn, existing.sector_id, user)

    membership = await memberships_repo.revoke(conn, membership_id)
    if membership is None:
        raise Conflict("membership is not approved")

    logger.info("membership revoked id=%s by=%s", membership_id, user.id)
    return _membership_to_out(membership)


# --- Session claim -----------------------------------------------------------


@router.post("/memberships/{membership_id}/session", response_model=SessionIssueResponse)
async def claim_session(
    membership_id: uuid.UUID, user: CurrentUser, conn: ConnDep, settings: SettingsDep
) -> SessionIssueResponse:
    """Called by the volunteer's own device after polling `GET /memberships/{id}`
    and seeing `status: "approved"`. Idempotent while the membership stays
    approved and unexpired -- a lost local copy can always be re-claimed."""
    membership = await memberships_repo.get(conn, membership_id)
    if membership is None:
        raise NotFound("membership not found")
    if membership.user_id != user.id:
        raise Forbidden("this is not your membership")
    if membership.status != "approved":
        raise Conflict("membership is not approved")

    if membership.session_expires_at is None:
        # Unreachable: `approve()` always sets this in the same statement
        # that flips status to 'approved'.
        raise Conflict("membership has no session window; ask your sector lead to re-approve")

    now = datetime.now(timezone.utc)
    if membership.session_expires_at <= now:
        raise Conflict("this approval has expired; ask your sector lead to re-approve")

    sector = await sectors_repo.get(conn, membership.sector_id)
    if sector is None or sector.status == "closed":
        raise Conflict("sector is no longer active")

    key_row = await sector_keys_repo.get(conn, sector.id, sector.key_epoch)
    if key_row is None:
        # Should be unreachable: every sector gets epoch 1 at creation, and
        # this module is the only writer of new epochs (future re-key work).
        raise Conflict("sector has no active key material")
    raw_key = envelope.unwrap(settings.sector_key_wrap_secret, key_row.key_wrapped)

    if membership.key_epoch_issued != sector.key_epoch:
        await memberships_repo.set_key_epoch(conn, membership.id, sector.key_epoch)

    token = issue_session_token(
        settings,
        user_id=user.id,
        device_id=membership.device_id,
        sector_id=sector.id,
        membership_id=membership.id,
        role=membership.role,
        key_epoch=sector.key_epoch,
        movement_mode=membership.movement_mode,
        expires_at=membership.session_expires_at,
    )

    logger.info(
        "session issued membership_id=%s sector_id=%s epoch=%d",
        membership.id, sector.id, sector.key_epoch,
    )
    return SessionIssueResponse(
        access_token=token,
        expires_at=membership.session_expires_at,
        key_epoch=sector.key_epoch,
        sector_key=base64.b64encode(raw_key).decode("ascii"),
        sector=await _sector_to_out(conn, sector),
    )
