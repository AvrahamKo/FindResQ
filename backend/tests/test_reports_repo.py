"""Reports repository: list/acknowledge/delta-query behavior, against a REAL
Postgres. `create()` itself is already exercised thoroughly by
`test_reports_pipeline_db.py` (through the encrypted pipeline); this file
covers what happens to a report AFTER it exists.

Skipped automatically if no database is reachable (see conftest.py's
`db_conn` fixture).
"""

from __future__ import annotations

import os
from datetime import datetime, timezone

import asyncpg
import pytest

from app.repositories import reports as reports_repo
from tests.conftest import DATABASE_URL
from tests.test_ingest_pipeline_db import _make_device, _make_sector, _make_user

pytestmark = pytest.mark.asyncio


async def _make_report(conn, sector, *, user_id, device_id, kind="hazard", note="test"):
    return await reports_repo.create(
        conn,
        sector_id=sector.id,
        device_id=device_id,
        user_id=user_id,
        kind=kind,
        lat=31.7715,
        lng=35.2170,
        note=note,
        recorded_at=datetime.now(timezone.utc),
        delivery_path="direct",
        # `signature` is UNIQUE (replay defence) -- a fresh random 64 bytes
        # per call, since several tests create more than one report.
        signature=os.urandom(64),
    )


class TestGetAndList:
    async def test_get_returns_none_for_an_unknown_id(self, db_conn) -> None:
        import uuid

        assert await reports_repo.get(db_conn, uuid.uuid4()) is None

    async def test_get_returns_a_created_report(self, db_conn) -> None:
        sector = await _make_sector(db_conn)
        user_id = await _make_user(db_conn, "Reporter")
        device_id, _wire_id, _key = await _make_device(db_conn, user_id)
        created = await _make_report(db_conn, sector, user_id=user_id, device_id=device_id)

        found = await reports_repo.get(db_conn, created.id)

        assert found is not None
        assert found.id == created.id
        assert found.status == "open"

    async def test_list_for_sector_respects_kind_filter(self, db_conn) -> None:
        sector = await _make_sector(db_conn)
        user_id = await _make_user(db_conn, "Reporter2")
        device_id, _wire_id, _key = await _make_device(db_conn, user_id)
        await _make_report(db_conn, sector, user_id=user_id, device_id=device_id, kind="hazard")
        await _make_report(db_conn, sector, user_id=user_id, device_id=device_id, kind="medical")

        hazards = await reports_repo.list_for_sector(db_conn, sector.id, kind="hazard")

        assert len(hazards) == 1
        assert hazards[0].kind == "hazard"

    async def test_list_for_sector_only_returns_that_sector(self, db_conn) -> None:
        sector_a = await _make_sector(db_conn)
        sector_b = await _make_sector(db_conn)
        user_id = await _make_user(db_conn, "Reporter3")
        device_id, _wire_id, _key = await _make_device(db_conn, user_id)
        await _make_report(db_conn, sector_a, user_id=user_id, device_id=device_id)

        assert len(await reports_repo.list_for_sector(db_conn, sector_a.id)) == 1
        assert len(await reports_repo.list_for_sector(db_conn, sector_b.id)) == 0


class TestAcknowledge:
    async def test_moves_open_to_acknowledged(self, db_conn) -> None:
        sector = await _make_sector(db_conn)
        user_id = await _make_user(db_conn, "Reporter4")
        device_id, _wire_id, _key = await _make_device(db_conn, user_id)
        lead_id = await _make_user(db_conn, "Lead4")
        created = await _make_report(db_conn, sector, user_id=user_id, device_id=device_id)

        acked = await reports_repo.acknowledge(db_conn, created.id, by_user_id=lead_id)

        assert acked is not None
        assert acked.status == "acknowledged"
        assert acked.acknowledged_by == lead_id
        assert acked.acknowledged_at is not None

    async def test_acknowledging_an_already_acknowledged_report_is_a_no_op(self, db_conn) -> None:
        sector = await _make_sector(db_conn)
        user_id = await _make_user(db_conn, "Reporter5")
        device_id, _wire_id, _key = await _make_device(db_conn, user_id)
        lead_id = await _make_user(db_conn, "Lead5")
        created = await _make_report(db_conn, sector, user_id=user_id, device_id=device_id)
        await reports_repo.acknowledge(db_conn, created.id, by_user_id=lead_id)

        result = await reports_repo.acknowledge(db_conn, created.id, by_user_id=lead_id)

        assert result is None


async def _db_reachable() -> bool:
    try:
        conn = await asyncpg.connect(DATABASE_URL, timeout=5)
        await conn.close()
        return True
    except (OSError, asyncpg.PostgresError):
        return False


@pytest.fixture
async def real_conn():
    """See `test_sos_repo.py`'s identical fixture docstring: `db_conn` wraps
    the whole test in one transaction, and Postgres freezes `now()` at
    transaction START -- so a delta-since-checkpoint query needs a
    connection where each statement gets its OWN implicit transaction and
    `now()` actually advances between them."""
    if not await _db_reachable():
        pytest.skip(f"no database reachable at {DATABASE_URL}")
    conn = await asyncpg.connect(DATABASE_URL)
    try:
        yield conn
    finally:
        await conn.close()


class TestDeltaQuery:
    async def test_get_for_sector_since_a_checkpoint_only_returns_later_changes(self, real_conn):
        sector = await _make_sector(real_conn)
        user_id = await _make_user(real_conn, "Reporter6")
        device_id, _wire_id, _key = await _make_device(real_conn, user_id)
        lead_id = await _make_user(real_conn, "Lead6")
        try:
            created = await _make_report(
                real_conn, sector, user_id=user_id, device_id=device_id
            )
            checkpoint = created.updated_at

            immediately_after = await reports_repo.get_for_sector(
                real_conn, sector.id, checkpoint
            )
            assert immediately_after == []

            await reports_repo.acknowledge(real_conn, created.id, by_user_id=lead_id)
            after_ack = await reports_repo.get_for_sector(real_conn, sector.id, checkpoint)

            assert len(after_ack) == 1
            assert after_ack[0].status == "acknowledged"
        finally:
            await real_conn.execute("DELETE FROM events WHERE id = $1", sector.event_id)
            await real_conn.execute(
                "DELETE FROM users WHERE id = ANY($1::uuid[])", [user_id, lead_id]
            )
