from __future__ import annotations

import uuid
from datetime import datetime

from pydantic import BaseModel, Field


class TeamTrackOut(BaseModel):
    """One searcher's traverse, as a drawable polyline.

    `points` is `[[lat, lng], ...]` in recorded order -- native map order,
    NOT GeoJSON's `[lng, lat]`. The swap happens once, server-side, in
    `track_points_repo.get_team_tracks`, because a silently transposed pair
    does not throw; it just draws the team in the wrong hemisphere.
    """

    segment_id: uuid.UUID
    user_id: uuid.UUID
    device_id: uuid.UUID
    movement_mode: str
    started_at: datetime
    ended_at: datetime | None = Field(
        default=None,
        description="Null while the searcher is still walking this segment.",
    )
    point_count: int = Field(
        description=(
            "Raw points recorded for this segment. May exceed len(points): "
            "the polyline is simplified for transport, the count is not."
        )
    )
    points: list[tuple[float, float]]


class TeamTracksResponse(BaseModel):
    sector_id: uuid.UUID
    tracks: list[TeamTrackOut]
    # Echoed back so a polling client can pass it as the next `since`
    # without needing a synchronized clock of its own -- a device whose
    # clock is minutes off would otherwise silently skip or re-fetch
    # everything, forever.
    server_time: datetime
