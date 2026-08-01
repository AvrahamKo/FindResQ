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


