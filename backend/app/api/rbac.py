"""Authorization checks shared across the events/sectors/memberships routes.

Two roles matter here: the event's Commander (`events.commander_id`) and a
sector's Lead (`sectors.lead_user_id`). Per Branch B, the Commander can always
act wherever a Lead can -- there is no sector a Commander is locked out of,
including one whose Lead's phone died at 2am.
"""

from __future__ import annotations

import uuid

import asyncpg

from ..errors import Forbidden, NotFound
from ..repositories import events as events_repo
from ..repositories import sectors as sectors_repo
from ..repositories.users import User


async def require_commander(
    conn: asyncpg.Connection, event_id: uuid.UUID, user: User
) -> events_repo.Event:
    event = await events_repo.get(conn, event_id)
    if event is None:
        raise NotFound("event not found")
    if event.commander_id != user.id:
        raise Forbidden("only the event's commander can do this")
    return event


async def require_lead_or_commander(
    conn: asyncpg.Connection, sector_id: uuid.UUID, user: User
) -> sectors_repo.SectorWithEvent:
    swe = await sectors_repo.get_with_event(conn, sector_id)
    if swe is None:
        raise NotFound("sector not found")
    is_commander = swe.event_commander_id == user.id
    is_lead = swe.sector.lead_user_id == user.id
    if not (is_commander or is_lead):
        raise Forbidden("only this sector's lead or the event's commander can do this")
    return swe


async def require_alert_moderator(
    conn: asyncpg.Connection, sector_id: uuid.UUID, user: User
) -> sectors_repo.SectorWithEvent:
    """Gate for acting on an alert: acknowledge, resolve, or clear.

    Same two roles as `require_lead_or_commander` -- the sector's Lead (the
    Sector Manager) and the event's Commander -- but named for the decision
    it guards rather than for the roles that happen to satisfy it today.
    Acknowledging an SOS is a claim that command has SEEN it and is acting;
    a rank-and-file searcher tapping it silences the alarm for the whole
    team while nobody has actually taken responsibility, which is the
    failure this separation exists to prevent. Distinguishing that from
    ordinary sector administration means the two can be given different
    answers later without hunting for which call sites meant which.
    """
    swe = await sectors_repo.get_with_event(conn, sector_id)
    if swe is None:
        raise NotFound("sector not found")
    if not (swe.event_commander_id == user.id or swe.sector.lead_user_id == user.id):
        raise Forbidden(
            "only this sector's manager (lead) or the event's commander "
            "can acknowledge or clear alerts"
        )
    return swe


