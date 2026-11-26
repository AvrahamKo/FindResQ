"""The coverage ledger: writing contributions and reading back derived state.

`recalc_hex_coverage` is the Phase 0 SQL function -- the search-theory math
(`POD_total = 1 - prod(1 - POD_i)`) lives there, once, as the single source of
truth. Nothing in this module or in Python re-implements that formula; a
second implementation would risk drifting from the SQL one.
"""

from __future__ import annotations

import uuid
from dataclasses import dataclass
from datetime import datetime
from decimal import Decimal

import asyncpg


async def insert_contributions(
    conn: asyncpg.Connection,
    *,
    sector_id: uuid.UUID,
    hex_ids: set[int],
    user_id: uuid.UUID,
    device_id: uuid.UUID,
    segment_id: uuid.UUID,
    segment_started_at: datetime,
    base_pod: Decimal,
) -> None:
    """`ON CONFLICT DO NOTHING` on (hex_id, segment_id) is what makes
    re-processing a segment's swath across multiple batches idempotent: a
    hex the segment already touched in an earlier batch simply doesn't get a
    second row, matching the "one contribution per traverse episode"
    invariant even though the episode's swath was computed incrementally."""
    if not hex_ids:
        return
    await conn.executemany(
        """
        INSERT INTO hex_contributions (
            sector_id, hex_id, user_id, device_id, segment_id,
            segment_started_at, base_pod
        )
        VALUES ($1, $2, $3, $4, $5, $6, $7)
        ON CONFLICT (hex_id, segment_id) DO NOTHING
        """,
        [
            (sector_id, hex_id, user_id, device_id, segment_id, segment_started_at, base_pod)
            for hex_id in hex_ids
        ],
    )


async def recalc(conn: asyncpg.Connection, sector_id: uuid.UUID, hex_ids: set[int]) -> None:
    if not hex_ids:
        return
    await conn.fetchval(
        "SELECT recalc_hex_coverage($1, $2)", sector_id, list(hex_ids)
    )


async def list_hex_ids_for_sector(
    conn: asyncpg.Connection, sector_id: uuid.UUID
) -> set[int]:
    """Every hex this sector has any contribution for -- the recalc set when
    something sector-wide changes the POD math (currently only
    `repeat_discount`; see routes/sectors.py's update_tuning)."""
    rows = await conn.fetch(
        "SELECT DISTINCT hex_id FROM hex_contributions WHERE sector_id = $1",
        sector_id,
    )
    return {row["hex_id"] for row in rows}


async def count_for_sector(conn: asyncpg.Connection, sector_id: uuid.UUID) -> int:
    """Used to gate `h3_resolution` changes: once contributions exist they are
    all recorded at the OLD resolution, and no recalculation can convert them
    -- the cell ids themselves would be wrong."""
    return await conn.fetchval(
        "SELECT count(*) FROM hex_contributions WHERE sector_id = $1", sector_id
    )


@dataclass(frozen=True, slots=True)
class HexCoverage:
    hex_id: int
    cumulative_pod: Decimal
    valid_contributions: int
    distinct_searchers: int
    last_contribution_at: datetime | None


async def get_coverage_for_sector(
    conn: asyncpg.Connection,
    sector_id: uuid.UUID,
    since: datetime | None,
    until: datetime | None = None,
) -> list[HexCoverage]:
    """Powers `GET /sectors/{id}/hexes`. `since` supports delta polling from
    a live dashboard instead of re-fetching the whole sector every refresh."""
    if since is None:
        rows = await conn.fetch(
            """
            SELECT hex_id, cumulative_pod, valid_contributions,
                   distinct_searchers, last_contribution_at
            FROM hex_coverage_state
            WHERE sector_id = $1
            """,
            sector_id,
        )
    elif until is None:
        rows = await conn.fetch(
            """
            SELECT hex_id, cumulative_pod, valid_contributions,
                   distinct_searchers, last_contribution_at
            FROM hex_coverage_state
            WHERE sector_id = $1 AND updated_at > $2
            """,
            sector_id,
            since,
        )
    else:
        rows = await conn.fetch(
            """
            SELECT hex_id, cumulative_pod, valid_contributions,
                   distinct_searchers, last_contribution_at
            FROM hex_coverage_state
            WHERE sector_id = $1
              AND updated_at > $2
              AND updated_at <= $3
            """,
            sector_id,
            since,
            until,
        )
    return [HexCoverage(**dict(row)) for row in rows]


@dataclass(frozen=True, slots=True)
class HexContributor:
    user_id: uuid.UUID
    segment_id: uuid.UUID
    segment_started_at: datetime
    base_pod: Decimal
    is_valid: bool


async def get_contributors_for_hex(
    conn: asyncpg.Connection, sector_id: uuid.UUID, hex_id: int
) -> list[HexContributor]:
    """Powers the Commander's "who covered this?" drill-down (Q5)."""
    rows = await conn.fetch(
        """
        SELECT user_id, segment_id, segment_started_at, base_pod, is_valid
        FROM hex_contributions
        WHERE sector_id = $1 AND hex_id = $2
        ORDER BY segment_started_at
        """,
        sector_id,
        hex_id,
    )
    return [HexContributor(**dict(row)) for row in rows]
