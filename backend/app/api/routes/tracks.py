"""Team scan paths: where everyone in a sector has actually walked.

Distinct from `/sectors/{id}/hexes`, and both are needed. The hex layer is
the DERIVED answer to "how thoroughly has this ground been searched?" -- POD
per cell, aggregated across the whole team, with no notion of who or when.
This is the RAW answer to "where has each of us been?": one polyline per
traverse, attributed and time-ordered.

A searcher in the field needs the second to make sense of the first. A hex
map alone shows a region as covered without showing the shape of the sweep
through it, so it cannot answer the questions that actually come up on the
ground -- has anyone been down that draw, is my teammate working toward me
or away, did that line stop because the terrain stopped or because the
person did.

Visibility matches every other sector read (`_require_sector_visibility`):
any current member of the sector, plus the Lead and the Commander. Coverage
is a shared team artefact -- restricting a searcher to their own trail is
precisely the bug this endpoint exists to fix.
"""

from __future__ import annotations

import uuid
from dataclasses import asdict
from datetime import datetime, timezone

from fastapi import APIRouter, Query

from ..deps import ConnDep, CurrentUser
from .sectors import _require_sector_visibility
from ..schemas.tracks import TeamTracksResponse, TeamTrackOut
from ...repositories import track_points as track_points_repo

router = APIRouter(tags=["tracks"])

# A hard ceiling on segments per response. A long callout with many
# searchers accumulates segments without bound, and an unbounded response
# here would eventually be delivered over a field LTE link to a phone that
# is also busy holding a GPS lock. Newest-first ordering means the cap drops
# the oldest traverses, which are the ones the hex layer already represents.
_MAX_TRACKS = 200


@router.get("/sectors/{sector_id}/tracks", response_model=TeamTracksResponse)
async def get_sector_tracks(
    sector_id: uuid.UUID,
    user: CurrentUser,
    conn: ConnDep,
    since: datetime | None = None,
    limit: int = Query(default=_MAX_TRACKS, ge=1, le=_MAX_TRACKS),
) -> TeamTracksResponse:
    """Every team member's path in this sector.

    `since` filters on each segment's most recent point, so an in-progress
    traverse keeps being returned as it grows -- see
    `get_team_tracks`. Clients should pass back the `server_time` from their
    previous response rather than their own clock.

    Note that a delta response REPLACES the segments it names (each carries
    its full current polyline) rather than appending to them; segments are
    keyed by `segment_id`, so a client merges by id.
    """
    await _require_sector_visibility(conn, sector_id, user)

    # Read the timestamp BEFORE the query. Taking it afterwards would leave
    # a window in which a point landed mid-query, was excluded from these
    # results, and then also fell before the next `since` -- silently lost
    # from that client's map until the segment happened to be touched again.
    server_time = datetime.now(timezone.utc)
    tracks = await track_points_repo.get_team_tracks(
        conn, sector_id, since=since, limit=limit
    )

    return TeamTracksResponse(
        sector_id=sector_id,
        tracks=[
            TeamTrackOut(**{k: v for k, v in asdict(t).items() if k != "is_valid"})
            for t in tracks
        ],
        server_time=server_time,
    )
