"""Event lifecycle: create, view, start, end (teardown), and subject (missing
person) record management.

Any authenticated user may create an event and becomes its Commander -- there
is no separate admin allowlist for the MVP. Everything else in this module is
gated by `require_commander` from api/rbac.py.
"""

from __future__ import annotations

import logging
import uuid
from dataclasses import asdict
from datetime import datetime, timedelta, timezone

from fastapi import APIRouter, status

from ..deps import ConnDep, CurrentUser
from ..rbac import require_commander
from ..schemas.events import EventCreate, EventOut, SubjectOut, SubjectUpsert
from ...errors import Conflict, Forbidden, NotFound
from ...repositories import events as events_repo
from ...repositories import memberships as memberships_repo
from ...repositories import sectors as sectors_repo
from ...repositories import subjects as subjects_repo

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/events", tags=["events"])


def _to_out(event: events_repo.Event) -> EventOut:
    return EventOut(**asdict(event))


def _subject_to_out(subject: subjects_repo.Subject) -> SubjectOut:
    fields = asdict(subject)
    fields.pop("purged_at")
    return SubjectOut(**fields)


@router.post("", response_model=EventOut, status_code=status.HTTP_201_CREATED)
async def create_event(
    payload: EventCreate, user: CurrentUser, conn: ConnDep
) -> EventOut:
    event = await events_repo.create(
        conn,
        name=payload.name,
        commander_id=user.id,
        command_post_sms=payload.command_post_sms,
        session_ttl_hours=payload.session_ttl_hours,
    )
    logger.info("event created id=%s commander=%s", event.id, user.id)
    return _to_out(event)


@router.get("", response_model=list[EventOut])
async def list_events(user: CurrentUser, conn: ConnDep) -> list[EventOut]:
    return [_to_out(e) for e in await events_repo.list_for_user(conn, user.id)]


async def _get_visible_event(
    conn: ConnDep, event_id: uuid.UUID, user: CurrentUser
) -> events_repo.Event:
    event = await events_repo.get(conn, event_id)
    if event is None:
        raise NotFound("event not found")
    if event.commander_id != user.id:
        has_membership = await memberships_repo.user_has_membership_in_event(
            conn, event_id, user.id
        )
        if not has_membership:
            raise Forbidden("you have no role in this event")
    return event


@router.get("/{event_id}", response_model=EventOut)
async def get_event(event_id: uuid.UUID, user: CurrentUser, conn: ConnDep) -> EventOut:
    return _to_out(await _get_visible_event(conn, event_id, user))


@router.post("/{event_id}/start", response_model=EventOut)
async def start_event(event_id: uuid.UUID, user: CurrentUser, conn: ConnDep) -> EventOut:
    await require_commander(conn, event_id, user)
    event = await events_repo.set_status(
        conn, event_id, from_statuses=("draft",), to_status="active",
        timestamp_column="started_at",
    )
    if event is None:
        raise Conflict("event is not in a state that can be started")
    logger.info("event started id=%s", event_id)
    return _to_out(event)


@router.post("/{event_id}/end", response_model=EventOut)
async def end_event(event_id: uuid.UUID, user: CurrentUser, conn: ConnDep) -> EventOut:
    """Online teardown trigger (Q9). Devices that never receive this -- because
    they are in a dead zone -- fall back to the client-side hard expiry
    (`session_expires_at`, enforced both on-device and by `current_membership`)
    or a Type A 'event terminated' mesh packet, built in a later phase."""
    await require_commander(conn, event_id, user)

    async with conn.transaction():
        event = await events_repo.set_status(
            conn, event_id, from_statuses=("draft", "active"), to_status="ended",
            timestamp_column="ended_at",
        )
        if event is None:
            raise Conflict("event has already ended")
        await sectors_repo.close_all_for_event(conn, event_id)
        await memberships_repo.end_all_for_event(conn, event_id)

    logger.info("event ended id=%s", event_id)
    return _to_out(event)


@router.put("/{event_id}/subject", response_model=SubjectOut)
async def upsert_subject(
    event_id: uuid.UUID, payload: SubjectUpsert, user: CurrentUser, conn: ConnDep
) -> SubjectOut:
    """Commander-only for the MVP. Field-facing visibility (an approved
    volunteer viewing this on their phone) is a mobile-client concern layered
    on top of the session token in a later phase -- this endpoint is where the
    Commander records it and the consent trail, not where volunteers read it."""
    await require_commander(conn, event_id, user)

    purge_after = datetime.now(timezone.utc) + timedelta(days=payload.retention_days)
    subject = await subjects_repo.upsert(
        conn,
        event_id=event_id,
        display_name=payload.display_name,
        age_years=payload.age_years,
        description=payload.description,
        medical_notes=payload.medical_notes,
        photo_object_key=payload.photo_object_key,
        consent_obtained_by=user.id,
        consent_basis=payload.consent_basis,
        purge_after=purge_after,
    )
    logger.info("subject upserted event_id=%s subject_id=%s", event_id, subject.id)
    return _subject_to_out(subject)


@router.get("/{event_id}/subject", response_model=SubjectOut)
async def get_subject(event_id: uuid.UUID, user: CurrentUser, conn: ConnDep) -> SubjectOut:
    await require_commander(conn, event_id, user)
    subject = await subjects_repo.get_for_event(conn, event_id)
    if subject is None:
        raise NotFound("no subject recorded for this event")
    return _subject_to_out(subject)
