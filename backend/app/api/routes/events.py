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
from ..schemas.events import (
    EventCreate,
    EventDeleteResult,
    EventOut,
    MemberRemovalResult,
    SubjectOut,
    SubjectUpsert,
)
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
    """Read access to an event: its Commander, or anyone holding a
    membership that still grants visibility.

    `user_has_membership_in_event` filters on status (see its docstring):
    a revoked or rejected membership is not a role, so a removed user loses
    the event -- and with it the sector list and the WebSocket ticket, both
    of which funnel through here -- on their very next request.
    """
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


@router.delete("/{event_id}", response_model=EventDeleteResult)
async def delete_event(event_id: uuid.UUID, user: CurrentUser, conn: ConnDep) -> EventDeleteResult:
    """Commander-only, irreversible, total.

    Unlike `/end` -- which closes an event but keeps every record for the
    after-action review -- this destroys the callout: sectors and their
    boundaries, sector keys, memberships, join codes, track segments and
    points, the coverage ledger and derived POD state, reports, device
    presence, SOS alerts, and the subject's PII record.

    The purge runs on three layers, because deleting rows alone is not
    enough:

      * DATABASE -- one `DELETE FROM events`. Every child table declares
        `ON DELETE CASCADE` (migration 0001), so the schema itself defines
        the closure; see `events_repo.delete` for why this is not an
        application-side delete list.
      * IN-MEMORY -- the `events_notify_deleted` trigger (migration 0008)
        fires the `event_deleted_channel` NOTIFY, and the realtime listener
        closes every dashboard socket for the event, purges its outstanding
        WS tickets, and prunes the now-dangling per-sector checkpoints it
        was holding. Skipping this leaks a socket group and four checkpoint
        entries per deleted sector for the process's whole lifetime.
      * DEVICES -- field handsets are not reachable to be told. They are
        cut off structurally instead: `current_membership` re-checks the
        membership row on every request (api/deps.py), and that row is gone,
        so the very next call from a device in the field fails closed. A
        phone that is in a dead zone at delete time simply finds this out
        when it comes back.

    The count of what was removed is read back before the delete so the
    response can state plainly what was destroyed.
    """
    event = await require_commander(conn, event_id, user)

    async with conn.transaction():
        summary = await events_repo.summarize_for_deletion(conn, event_id)
        sector_ids = await events_repo.delete(conn, event_id)
        if sector_ids is None:
            # Lost a race with another commander session doing the same
            # thing; the end state is the one that was asked for either way.
            raise NotFound("event not found")

    logger.warning(
        "EVENT DELETED id=%s name=%r by=%s sectors=%d memberships=%d "
        "track_points=%d contributions=%d reports=%d sos=%d",
        event_id, event.name, user.id, len(sector_ids),
        summary.memberships, summary.track_points, summary.hex_contributions,
        summary.reports, summary.sos_alerts,
    )
    return EventDeleteResult(
        event_id=event_id,
        sectors_deleted=len(sector_ids),
        memberships_deleted=summary.memberships,
        track_segments_deleted=summary.track_segments,
        track_points_deleted=summary.track_points,
        hex_contributions_deleted=summary.hex_contributions,
        reports_deleted=summary.reports,
        sos_alerts_deleted=summary.sos_alerts,
    )


@router.delete("/{event_id}/members/{user_id}", response_model=MemberRemovalResult)
async def remove_event_member(
    event_id: uuid.UUID, user_id: uuid.UUID, user: CurrentUser, conn: ConnDep
) -> MemberRemovalResult:
    """Removes a user from an event entirely: every sector, every device.

    Two properties this deliberately holds, which pull in opposite
    directions and are the whole reason this endpoint is not a plain DELETE:

    ACCESS ENDS IMMEDIATELY. Every live membership goes to 'revoked' with
    `session_expires_at = now()`, which `current_membership` rejects on the
    device's next request -- no telemetry, no reports, no SOS, and (since
    `user_has_membership_in_event` is status-filtered) no read access to the
    event either. The `membership_revoked` trigger simultaneously hangs up
    any dashboard socket they hold, so a removed user watching a live map
    does not keep watching it.

    HISTORY SURVIVES. Nothing is deleted. Their track segments, points, hex
    contributions, reports and past alerts all stay exactly where they are,
    still attributed to them. That is not an oversight to tidy up later: the
    coverage map's central claim is "this ground was searched, by someone,
    at this time", and silently retracting a removed volunteer's tracks
    would re-open ground that really was walked -- turning a personnel
    decision into a search-planning lie. Removing a person from the team is
    not the same act as retracting their work, and only the latter belongs
    to `track_segments.is_valid`.

    The Commander cannot be removed from their own event -- there would be
    nobody left who could administer it.
    """
    await require_commander(conn, event_id, user)

    if user_id == user.id:
        raise Conflict("you cannot remove yourself from an event you command")

    memberships = await memberships_repo.list_for_event_user(conn, event_id, user_id)
    if not memberships:
        raise NotFound("this user holds no membership in this event")

    async with conn.transaction():
        revoked = await memberships_repo.revoke_all_for_user_in_event(
            conn, event_id, user_id
        )
        # A removed member must not stay listed as a sector's Lead: the
        # sectors row is a separate pointer from the membership row, and a
        # stale one would keep passing `require_lead_or_commander`.
        cleared_leads = await sectors_repo.clear_lead_for_user(conn, event_id, user_id)

    logger.warning(
        "member removed from event event_id=%s user_id=%s by=%s "
        "memberships_revoked=%d lead_roles_cleared=%d (history retained)",
        event_id, user_id, user.id, revoked, cleared_leads,
    )
    return MemberRemovalResult(
        event_id=event_id,
        user_id=user_id,
        memberships_revoked=revoked,
        lead_roles_cleared=cleared_leads,
        history_retained=True,
    )


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
