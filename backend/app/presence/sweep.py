"""Periodic presence sweep: the DB-touching half of the four-state system.

This is a periodic tick, not something triggered by ingest traffic --
the interesting transitions (active -> stale -> mia) happen precisely
because NO new data arrives, which a purely reactive design can't observe.
Started as a background task in main.py's lifespan.
"""

from __future__ import annotations

import logging
import uuid
from datetime import datetime, timezone

import asyncpg

from ..repositories import presence as presence_repo
from .classifier import DeviceSnapshot, PresenceThresholds, classify

logger = logging.getLogger(__name__)


async def sweep_sector(
    conn: asyncpg.Connection,
    sector_id: uuid.UUID,
    thresholds: PresenceThresholds,
    *,
    now: datetime | None = None,
) -> int:
    """Returns the number of devices whose presence_state actually changed."""
    now = now or datetime.now(timezone.utc)
    rows = await presence_repo.get_for_sector(conn, sector_id)

    snapshots = [
        DeviceSnapshot(
            device_id=row.device_id,
            last_point_at=row.last_point_at,
            last_lat=row.last_lat,
            last_lng=row.last_lng,
            last_battery_pct=row.last_battery_pct,
        )
        for row in rows
        if row.last_point_at is not None and row.last_lat is not None
    ]
    current_state = {row.device_id: row.presence_state for row in rows}

    new_states = classify(snapshots, now, thresholds)
    changed = {
        device_id: state
        for device_id, state in new_states.items()
        if state != current_state.get(device_id)
    }

    if changed:
        await presence_repo.update_states(conn, sector_id, changed)

    return len(changed)


async def sweep_all_open_sectors(
    conn: asyncpg.Connection, thresholds: PresenceThresholds | None = None
) -> int:
    thresholds = thresholds or PresenceThresholds()
    sector_ids = await conn.fetch("SELECT id FROM sectors WHERE status = 'open'")

    total_changed = 0
    for row in sector_ids:
        try:
            total_changed += await sweep_sector(conn, row["id"], thresholds)
        except Exception:
            logger.exception("presence sweep failed for sector_id=%s", row["id"])

    return total_changed
