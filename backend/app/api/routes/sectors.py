"""Sector CRUD, tuning overrides, and Lead (re)assignment.

RBAC split, per the architecture review (Branch B): a sector's Lead may tune
their own sector; only the event's Commander can create sectors or reassign
who leads one -- and the Commander can do both of those things in ANY sector
of their event, which is what lets them route around a Lead whose phone died
mid-callout.
"""

from __future__ import annotations

import logging
import uuid
from dataclasses import asdict

from fastapi import APIRouter, status

from ..deps import ConnDep, CurrentUser, SettingsDep
from ..rbac import require_commander, require_lead_or_commander
from .events import _get_visible_event
from ..schemas.sectors import (
    SectorCreate,
    SectorLeadAssign,
    SectorOut,
    SectorTuningUpdate,
)
from ...errors import Conflict, Forbidden, NotFound
from ...repositories import memberships as memberships_repo
from ...repositories import sector_keys as sector_keys_repo
from ...repositories import sectors as sectors_repo
from ...security import envelope

logger = logging.getLogger(__name__)

router = APIRouter(tags=["sectors"])


async def _to_out(conn: ConnDep, sector: sectors_repo.Sector) -> SectorOut:
    boundary = await sectors_repo.get_boundary_geojson(conn, sector.id)
    return SectorOut(**asdict(sector), boundary=boundary)


@router.post(
    "/events/{event_id}/sectors",
    response_model=SectorOut,
    status_code=status.HTTP_201_CREATED,
)
async def create_sector(
    event_id: uuid.UUID,
    payload: SectorCreate,
    user: CurrentUser,
    conn: ConnDep,
    settings: SettingsDep,
) -> SectorOut:
    await require_commander(conn, event_id, user)

    async with conn.transaction():
        sector = await sectors_repo.create(
            conn,
            event_id=event_id,
            name=payload.name,
            boundary_geojson=payload.boundary.model_dump(),
        )
        raw_key = envelope.generate_sector_key()
        wrapped = envelope.wrap(settings.sector_key_wrap_secret, raw_key)
        await sector_keys_repo.insert(conn, sector.id, sector.key_epoch, wrapped)

    logger.info("sector created id=%s event_id=%s", sector.id, event_id)
    return await _to_out(conn, sector)


@router.get("/events/{event_id}/sectors", response_model=list[SectorOut])
async def list_sectors(
    event_id: uuid.UUID, user: CurrentUser, conn: ConnDep
) -> list[SectorOut]:
    await _get_visible_event(conn, event_id, user)
    sectors = await sectors_repo.list_for_event(conn, event_id)
    return [await _to_out(conn, s) for s in sectors]


async def _require_sector_visibility(
    conn: ConnDep, sector_id: uuid.UUID, user: CurrentUser
) -> sectors_repo.SectorWithEvent:
    swe = await sectors_repo.get_with_event(conn, sector_id)
    if swe is None:
        raise NotFound("sector not found")

    is_staff = swe.event_commander_id == user.id or swe.sector.lead_user_id == user.id
    if not is_staff:
        membership = await memberships_repo.get_by_user(conn, sector_id, user.id)
        if membership is None:
            raise Forbidden("you have no role in this sector")
    return swe


@router.get("/sectors/{sector_id}", response_model=SectorOut)
async def get_sector(sector_id: uuid.UUID, user: CurrentUser, conn: ConnDep) -> SectorOut:
    swe = await _require_sector_visibility(conn, sector_id, user)
    return await _to_out(conn, swe.sector)


@router.patch("/sectors/{sector_id}/tuning", response_model=SectorOut)
async def update_tuning(
    sector_id: uuid.UUID, payload: SectorTuningUpdate, user: CurrentUser, conn: ConnDep
) -> SectorOut:
    await require_lead_or_commander(conn, sector_id, user)

    # Keys come only from SectorTuningUpdate's own declared fields, so this is
    # safe to interpolate as SQL identifiers in the repository layer -- never
    # widen this to forward a caller-supplied key set instead.
    fields = payload.model_dump(exclude_unset=True)
    sector = await sectors_repo.update_tuning(conn, sector_id, fields)
    if sector is None:
        raise NotFound("sector not found")

    logger.info(
        "sector tuning updated id=%s by=%s fields=%s", sector_id, user.id, list(fields)
    )
    return await _to_out(conn, sector)


@router.post("/sectors/{sector_id}/lead", response_model=SectorOut)
async def assign_lead(
    sector_id: uuid.UUID, payload: SectorLeadAssign, user: CurrentUser, conn: ConnDep
) -> SectorOut:
    """Promotes an already-approved member of this sector to Lead.

    The appointee must already hold an approved membership -- they join
    through the same code-and-approval flow as any volunteer; this only
    elevates their role. That keeps a single onboarding path instead of a
    parallel one for Leads, and it's exactly the Branch B mechanism: the
    Commander can do this in any sector, at any time, including one whose
    current Lead has gone dark.
    """
    swe = await sectors_repo.get_with_event(conn, sector_id)
    if swe is None:
        raise NotFound("sector not found")
    await require_commander(conn, swe.sector.event_id, user)

    target = await memberships_repo.get_by_user(conn, sector_id, payload.user_id)
    if target is None or target.status != "approved":
        raise Conflict(
            "the target user must already hold an approved membership in this sector"
        )

    async with conn.transaction():
        previous_lead = await memberships_repo.get_current_lead_membership(conn, sector_id)
        if previous_lead is not None and previous_lead.id != target.id:
            await memberships_repo.set_role(conn, previous_lead.id, "volunteer")

        await memberships_repo.set_role(conn, target.id, "lead")
        sector = await sectors_repo.set_lead(conn, sector_id, payload.user_id)

    logger.info(
        "sector lead reassigned sector_id=%s new_lead=%s by=%s",
        sector_id, payload.user_id, user.id,
    )
    return await _to_out(conn, sector)
