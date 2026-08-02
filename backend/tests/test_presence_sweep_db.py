"""The presence sweep orchestrator against a REAL Postgres: proves the pure
classifier's decisions actually get read from and written back to
`device_presence` correctly, and that a no-op re-sweep changes nothing.

Uses the standard rollback-safe `db_conn` fixture -- unlike the realtime
broadcast tests, sweep correctness doesn't depend on cross-connection NOTIFY
delivery (which requires a real commit); it's a straightforward
read-then-write within one connection.
"""

from __future__ import annotations

from datetime import datetime, timedelta, timezone

import pytest

from app.presence.classifier import ACTIVE, BATTERY_DEAD, DEAD_ZONE, MIA, STALE, PresenceThresholds
from app.presence.sweep import sweep_sector
from app.repositories import presence as presence_repo
from tests.test_ingest_pipeline_db import _make_device, _make_sector, _make_user

pytestmark = pytest.mark.asyncio

NOW = datetime.now(timezone.utc)
THRESHOLDS = PresenceThresholds()
BASE_LAT, BASE_LNG = 31.7700, 35.2200


async def _seed(conn, sector_id, seconds_ago: float, *, battery: int, lat=BASE_LAT, lng=BASE_LNG):
    user_id = await _make_user(conn, "Presence Test User")
    device_id, _, _ = await _make_device(conn, user_id)
    await presence_repo.upsert_active(
        conn,
        sector_id=sector_id,
        device_id=device_id,
        last_point_at=NOW - timedelta(seconds=seconds_ago),
        last_lat=lat,
        last_lng=lng,
        last_battery_pct=battery,
        last_delivery_path="direct",
    )
    return device_id


class TestSweepSector:
    async def test_recently_active_device_stays_active(self, db_conn) -> None:
        conn = db_conn
        sector = await _make_sector(conn)
        device_id = await _seed(conn, sector.id, 30, battery=80)

        await sweep_sector(conn, sector.id, THRESHOLDS, now=NOW)

        rows = await presence_repo.get_for_sector(conn, sector.id)
        assert rows[0].device_id == device_id
        assert rows[0].presence_state == ACTIVE

    async def test_moderately_silent_healthy_device_becomes_stale(self, db_conn) -> None:
        conn = db_conn
        sector = await _make_sector(conn)
        device_id = await _seed(conn, sector.id, 600, battery=50)

        changed = await sweep_sector(conn, sector.id, THRESHOLDS, now=NOW)

        assert changed == 1
        rows = await presence_repo.get_for_sector(conn, sector.id)
        assert rows[0].presence_state == STALE

    async def test_low_battery_device_becomes_battery_dead(self, db_conn) -> None:
        conn = db_conn
        sector = await _make_sector(conn)
        device_id = await _seed(conn, sector.id, 400, battery=3)

        await sweep_sector(conn, sector.id, THRESHOLDS, now=NOW)

        rows = await presence_repo.get_for_sector(conn, sector.id)
        assert rows[0].presence_state == BATTERY_DEAD

    async def test_isolated_long_silence_becomes_mia(self, db_conn) -> None:
        conn = db_conn
        sector = await _make_sector(conn)
        far_lat, far_lng = BASE_LAT + 0.5, BASE_LNG + 0.5
        device_id = await _seed(
            conn, sector.id, THRESHOLDS.mia_seconds + 60, battery=90, lat=far_lat, lng=far_lng
        )

        await sweep_sector(conn, sector.id, THRESHOLDS, now=NOW)

        rows = await presence_repo.get_for_sector(conn, sector.id)
        assert rows[0].presence_state == MIA

    async def test_three_correlated_devices_become_dead_zone_not_mia(self, db_conn) -> None:
        conn = db_conn
        sector = await _make_sector(conn)
        silent_for = THRESHOLDS.mia_seconds + 30

        device_ids = [
            await _seed(conn, sector.id, silent_for, battery=90, lat=BASE_LAT, lng=BASE_LNG),
            await _seed(
                conn, sector.id, silent_for - 10, battery=90,
                lat=BASE_LAT + 0.0001, lng=BASE_LNG + 0.0001,
            ),
            await _seed(
                conn, sector.id, silent_for - 20, battery=90,
                lat=BASE_LAT - 0.0001, lng=BASE_LNG - 0.0001,
            ),
        ]

        await sweep_sector(conn, sector.id, THRESHOLDS, now=NOW)

        rows = await presence_repo.get_for_sector(conn, sector.id)
        states = {row.device_id: row.presence_state for row in rows}
        assert all(states[d] == DEAD_ZONE for d in device_ids)

    async def test_resweeping_unchanged_state_reports_zero_changes(self, db_conn) -> None:
        """Idempotency: a device already correctly classified doesn't get
        re-flagged as 'changed' on every tick, which would otherwise spam the
        realtime broadcast with no-op updates every 30 seconds forever."""
        conn = db_conn
        sector = await _make_sector(conn)
        await _seed(conn, sector.id, 600, battery=50)  # -> stale

        first = await sweep_sector(conn, sector.id, THRESHOLDS, now=NOW)
        assert first == 1

        second = await sweep_sector(conn, sector.id, THRESHOLDS, now=NOW)
        assert second == 0

    async def test_device_recovering_moves_back_to_active_on_next_ingest(self, db_conn) -> None:
        """Simulates a device that went stale, then reconnected -- a fresh
        `upsert_active` call (as ingest would make) should let the next
        sweep bring it back to active."""
        conn = db_conn
        sector = await _make_sector(conn)
        device_id = await _seed(conn, sector.id, 600, battery=50)
        await sweep_sector(conn, sector.id, THRESHOLDS, now=NOW)

        rows = await presence_repo.get_for_sector(conn, sector.id)
        assert rows[0].presence_state == STALE

        # Device reconnects: ingest would call upsert_active with a fresh timestamp.
        await presence_repo.upsert_active(
            conn,
            sector_id=sector.id,
            device_id=device_id,
            last_point_at=NOW,
            last_lat=BASE_LAT,
            last_lng=BASE_LNG,
            last_battery_pct=60,
            last_delivery_path="direct",
        )
        changed = await sweep_sector(conn, sector.id, THRESHOLDS, now=NOW)
        assert changed == 1

        rows = await presence_repo.get_for_sector(conn, sector.id)
        assert rows[0].presence_state == ACTIVE
