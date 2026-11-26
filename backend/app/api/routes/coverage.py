"""Read-only coverage queries against the derived `hex_coverage_state` /
`hex_contributions` tables -- never against raw `track_points`, which would
mean recomputing the search-theory aggregation on every dashboard refresh
instead of reading Phase 0's already-materialized state."""

from __future__ import annotations

import uuid
from dataclasses import asdict
from datetime import datetime

import h3
from fastapi import APIRouter

from ..deps import ConnDep, CurrentUser
from ..rbac import require_lead_or_commander
from .sectors import _require_sector_visibility
from ..schemas.coverage import ContributorOut, CoverageResponse, HexCoverageOut
from ...errors import ValidationFailed
from ...repositories import hex_contributions as hex_contrib_repo

router = APIRouter(tags=["coverage"])


def _parse_hex_id(value: str) -> int:
    """Accept canonical H3 strings and legacy decimal wire values.

    Coverage responses now use the canonical hexadecimal representation
    expected by h3-js. Keeping decimal parsing here avoids breaking callers
    that saved an id returned by an older server version.
    """
    try:
        if h3.is_valid_cell(value):
            return h3.str_to_int(value)
    except (ValueError, OverflowError):
        # A legacy decimal bigint is not an H3 string and may overflow the
        # string API before it can simply return False. Fall through to the
        # compatibility parser below.
        pass

    try:
        candidate = int(value)
        canonical = h3.int_to_str(candidate)
    except (ValueError, OverflowError) as exc:
        raise ValidationFailed("hex_id must be a valid H3 cell id") from exc

    if not h3.is_valid_cell(canonical):
        raise ValidationFailed("hex_id must be a valid H3 cell id")
    return candidate


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
    # Capture PostgreSQL's time BEFORE the delta query and cap the query at
    # that checkpoint. A row updated concurrently after this instant is then
    # guaranteed to appear in the next request instead of falling into a
    # query/checkpoint race window.
    server_time = await conn.fetchval("SELECT now()")
    rows = await hex_contrib_repo.get_coverage_for_sector(
        conn,
        sector_id,
        since,
        until=server_time,
    )
    return CoverageResponse(
        sector_id=sector_id,
        resolution=swe.sector.h3_resolution,
        hexes=[HexCoverageOut(**asdict(row)) for row in rows],
        server_time=server_time,
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

    hex_id_int = _parse_hex_id(hex_id)

    rows = await hex_contrib_repo.get_contributors_for_hex(conn, sector_id, hex_id_int)
    return [ContributorOut(**asdict(row)) for row in rows]
