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
    SectorUpdate,
)
from ...errors import Conflict, Forbidden, NotFound
from ...repositories import hex_contributions as hex_contrib_repo
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


@router.patch("/sectors/{sector_id}", response_model=SectorOut)
async def update_sector(
    sector_id: uuid.UUID, payload: SectorUpdate, user: CurrentUser, conn: ConnDep
) -> SectorOut:
    """Recruitment on/off switch and/or a redrawn boundary.

    `status` is independent of the event's own 'draft' -> 'active' status: a
    sector being 'open' does NOT let anyone join unless its parent event is
    also 'active' (see routes/memberships.py's join_sector), and this
    endpoint has no effect on that.

    `boundary` replaces the outline WITHOUT recalculating coverage, which is
    deliberate -- see sectors_repo.update_boundary for the full reasoning.
    Short version: contributions record where searchers physically walked
    and are never clipped to the polygon, so a redrawn outline cannot change
    any hex's POD.
    """
    await require_lead_or_commander(conn, sector_id, user)

    sector = None
    async with conn.transaction():
        if payload.boundary is not None:
            sector = await sectors_repo.update_boundary(
                conn, sector_id, payload.boundary.model_dump()
            )
            if sector is None:
                raise NotFound("sector not found")
        if payload.status is not None:
            sector = await sectors_repo.set_status(conn, sector_id, payload.status)

    if sector is None:
        raise NotFound("sector not found")

    logger.info(
        "sector updated id=%s by=%s status=%s boundary_changed=%s",
        sector_id, user.id, payload.status, payload.boundary is not None,
    )
    return await _to_out(conn, sector)


# Changing this retroactively re-weights every existing contribution, because
# `recalc_hex_coverage` reads `repeat_discount` live from the sectors row.
# The other tuning fields do NOT: `base_pod_day`/`base_pod_night` are
# snapshotted into `hex_contributions.base_pod` at ingest time, so they only
# affect FUTURE traversals.
_POD_AFFECTING_TUNING_FIELDS = frozenset({"repeat_discount"})


@router.patch("/sectors/{sector_id}/tuning", response_model=SectorOut)
async def update_tuning(
    sector_id: uuid.UUID, payload: SectorTuningUpdate, user: CurrentUser, conn: ConnDep
) -> SectorOut:
    await require_lead_or_commander(conn, sector_id, user)

    existing = await sectors_repo.get(conn, sector_id)
    if existing is None:
        raise NotFound("sector not found")

    # Keys come only from SectorTuningUpdate's own declared fields, so this is
    # safe to interpolate as SQL identifiers in the repository layer -- never
    # widen this to forward a caller-supplied key set instead.
    fields = payload.model_dump(exclude_unset=True)

    # h3_resolution is not retroactively fixable: every existing hex_id was
    # computed at the OLD resolution, so the stored cell ids -- not just
    # their POD -- would be wrong. Recalculation cannot repair that, so this
    # is refused outright rather than silently corrupting the ledger.
    new_resolution = fields.get("h3_resolution")
    if new_resolution is not None and new_resolution != existing.h3_resolution:
        contributions = await hex_contrib_repo.count_for_sector(conn, sector_id)
        if contributions > 0:
            raise Conflict(
                f"cannot change h3_resolution: this sector already has "
                f"{contributions} coverage contribution(s) recorded at resolution "
                f"{existing.h3_resolution}. Create a new sector instead."
            )

    pod_changed = any(
        key in _POD_AFFECTING_TUNING_FIELDS and fields[key] != getattr(existing, key)
        for key in fields
    )

    async with conn.transaction():
        sector = await sectors_repo.update_tuning(conn, sector_id, fields)
        if sector is None:
            raise NotFound("sector not found")
        if pod_changed:
            # Without this, every already-computed cumulative_pod stays stale
            # until some future ingest happens to touch that hex again.
            hex_ids = await hex_contrib_repo.list_hex_ids_for_sector(conn, sector_id)
            await hex_contrib_repo.recalc(conn, sector_id, hex_ids)
            logger.info(
                "sector tuning recalculated id=%s hexes=%d", sector_id, len(hex_ids)
            )

    logger.info(
        "sector tuning updated id=%s by=%s fields=%s pod_recalc=%s",
        sector_id, user.id, list(fields), pod_changed,
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
