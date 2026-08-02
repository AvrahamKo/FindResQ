"""`device_presence`: raw last-known facts (written by the ingest pipeline)
and derived state (written only by the presence sweep -- see
app/presence/sweep.py). Keeping those two writers separate means ingest and
the sweep never race to decide "what state is this device in" independently.
"""

from __future__ import annotations

import uuid
from dataclasses import dataclass
from datetime import datetime

import asyncpg


@dataclass(frozen=True, slots=True)
class PresenceRow:
    sector_id: uuid.UUID
    device_id: uuid.UUID
    user_id: uuid.UUID
    last_point_at: datetime | None
    last_lat: float | None
    last_lng: float | None
    last_battery_pct: int | None
    last_delivery_path: str | None
    presence_state: str
    state_changed_at: datetime
    updated_at: datetime


_SELECT_COLUMNS = """
    dp.sector_id, dp.device_id, d.user_id,
    dp.last_point_at,
    ST_Y(dp.last_geom::geometry) AS last_lat,
    ST_X(dp.last_geom::geometry) AS last_lng,
    dp.last_battery_pct, dp.last_delivery_path,
    dp.presence_state, dp.state_changed_at, dp.updated_at
"""


def _to_row(record: asyncpg.Record) -> PresenceRow:
    return PresenceRow(**dict(record))


async def upsert_active(
    conn: asyncpg.Connection,
    *,
    sector_id: uuid.UUID,
    device_id: uuid.UUID,
    last_point_at: datetime,
    last_lat: float,
    last_lng: float,
    last_battery_pct: int,
    last_delivery_path: str,
) -> None:
    """Records that a device transmitted, and when/where/how. Deliberately
    does NOT touch `presence_state`/`state_changed_at` on conflict -- the
    periodic sweep (app/presence/sweep.py) is the only writer of derived
    state, so ingest traffic and the sweep's classification never race."""
    await conn.execute(
        """
        INSERT INTO device_presence (
            sector_id, device_id, last_point_at, last_geom,
            last_battery_pct, last_delivery_path, presence_state,
            state_changed_at, updated_at
        )
        VALUES (
            $1, $2, $3, ST_SetSRID(ST_MakePoint($5, $4), 4326)::geography,
            $6, $7, 'active', now(), now()
        )
        ON CONFLICT (sector_id, device_id) DO UPDATE SET
            last_point_at = EXCLUDED.last_point_at,
            last_geom = EXCLUDED.last_geom,
            last_battery_pct = EXCLUDED.last_battery_pct,
            last_delivery_path = EXCLUDED.last_delivery_path,
            updated_at = now()
        """,
        sector_id,
        device_id,
        last_point_at,
        last_lat,
        last_lng,
        last_battery_pct,
        last_delivery_path,
    )


async def get_for_sector(
    conn: asyncpg.Connection, sector_id: uuid.UUID, since: datetime | None = None
) -> list[PresenceRow]:
    if since is None:
        rows = await conn.fetch(
            f"""
            SELECT {_SELECT_COLUMNS}
            FROM device_presence dp JOIN devices d ON d.id = dp.device_id
            WHERE dp.sector_id = $1
            """,
            sector_id,
        )
    else:
        rows = await conn.fetch(
            f"""
            SELECT {_SELECT_COLUMNS}
            FROM device_presence dp JOIN devices d ON d.id = dp.device_id
            WHERE dp.sector_id = $1 AND dp.updated_at > $2
            """,
            sector_id,
            since,
        )
    return [_to_row(r) for r in rows]


async def update_states(
    conn: asyncpg.Connection, sector_id: uuid.UUID, new_states: dict[uuid.UUID, str]
) -> None:
    """Bulk-updates only the devices whose computed state actually changed --
    the caller (presence/sweep.py) has already filtered out no-ops, so every
    row touched here is a real transition and legitimately bumps
    `state_changed_at`."""
    if not new_states:
        return
    await conn.executemany(
        """
        UPDATE device_presence
        SET presence_state = $3, state_changed_at = now(), updated_at = now()
        WHERE sector_id = $1 AND device_id = $2
        """,
        [(sector_id, device_id, state) for device_id, state in new_states.items()],
    )
