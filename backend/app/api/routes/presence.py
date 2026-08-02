"""Read-only presence queries against `device_presence` -- the same
snapshot-or-delta pattern as GET /sectors/{id}/hexes (Phase 3), and the
dashboard's bootstrap source before it starts relying on WS `presence_delta`
messages for anything that changes after the initial load."""

from __future__ import annotations

import uuid
from dataclasses import asdict
from datetime import datetime

from fastapi import APIRouter

from ..deps import ConnDep, CurrentUser
from .sectors import _require_sector_visibility
from ..schemas.presence import PresenceOut
from ...repositories import presence as presence_repo

router = APIRouter(tags=["presence"])


@router.get("/sectors/{sector_id}/presence", response_model=list[PresenceOut])
async def get_sector_presence(
    sector_id: uuid.UUID,
    user: CurrentUser,
    conn: ConnDep,
    since: datetime | None = None,
) -> list[PresenceOut]:
    await _require_sector_visibility(conn, sector_id, user)
    rows = await presence_repo.get_for_sector(conn, sector_id, since)
    return [PresenceOut(**asdict(row)) for row in rows]
