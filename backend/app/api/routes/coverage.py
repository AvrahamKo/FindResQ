"""Read-only coverage queries against the derived `hex_coverage_state` /
`hex_contributions` tables -- never against raw `track_points`, which would
mean recomputing the search-theory aggregation on every dashboard refresh
instead of reading Phase 0's already-materialized state."""

from __future__ import annotations

import uuid
from dataclasses import asdict
from datetime import datetime

from fastapi import APIRouter

from ..deps import ConnDep, CurrentUser
from ..rbac import require_lead_or_commander
from .sectors import _require_sector_visibility
from ..schemas.coverage import ContributorOut, CoverageResponse, HexCoverageOut
from ...errors import ValidationFailed
from ...repositories import hex_contributions as hex_contrib_repo

router = APIRouter(tags=["coverage"])


@router.get("/sectors/{sector_id}/hexes", response_model=CoverageResponse)
async def get_sector_coverage(
    sector_id: uuid.UUID,
    user: CurrentUser,
    conn: ConnDep,
    since: datetime | None = None,
) -> CoverageResponse:
    """`since` supports delta polling: a live dashboard passes back the
    newest `last_contribution_at`/timestamp it has already rendered instead
    of re-fetching every hex in the sector on each refresh."""
    swe = await _require_sector_visibility(conn, sector_id, user)
    rows = await hex_contrib_repo.get_coverage_for_sector(conn, sector_id, since)
    return CoverageResponse(
        sector_id=sector_id,
        resolution=swe.sector.h3_resolution,
        hexes=[HexCoverageOut(**asdict(row)) for row in rows],
    )


@router.get(
    "/sectors/{sector_id}/hexes/{hex_id}/contributors",
    response_model=list[ContributorOut],
)
async def get_hex_contributors(
    sector_id: uuid.UUID, hex_id: str, user: CurrentUser, conn: ConnDep
) -> list[ContributorOut]:
    """Staff-only (Lead or Commander): "who covered this hex, and when" is
    exactly the drill-down a Commander needs before deciding to invalidate a
    volunteer's track (Q5) -- rank-and-file volunteers only see the
    aggregated POD, not the attribution behind it."""
    await require_lead_or_commander(conn, sector_id, user)

    try:
        hex_id_int = int(hex_id)
    except ValueError as exc:
        raise ValidationFailed("hex_id must be a numeric H3 cell id") from exc

    rows = await hex_contrib_repo.get_contributors_for_hex(conn, sector_id, hex_id_int)
    return [ContributorOut(**asdict(row)) for row in rows]
