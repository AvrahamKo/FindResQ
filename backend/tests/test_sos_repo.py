"""SOS state machine, at the repository layer, against a REAL Postgres --
the state transitions and the "one open alert per device" invariant are
enforced partly by SQL (migrations/0006_sos.sql's partial unique index), so
testing against a mocked connection would prove nothing about the actual
guarantee.

Skipped automatically if no database is reachable (see conftest.py's
`db_conn` fixture).
"""

from __future__ import annotations

import asyncpg
import pytest

from app.repositories import sos as sos_repo
from tests.conftest import DATABASE_URL
from tests.test_ingest_pipeline_db import _make_device, _make_sector, _make_user

pytestmark = pytest.mark.asyncio


async def _db_reachable() -> bool:
    try:
        conn = await asyncpg.connect(DATABASE_URL, timeout=5)
        await conn.close()
        return True
    except (OSError, asyncpg.PostgresError):
        return False


@pytest.fixture
async def real_conn():
    """Unlike `db_conn` (one big transaction, rolled back at teardown -- see
    conftest.py), this gives each statement its OWN implicit transaction, so
    `now()` (which Postgres freezes at transaction START, not per-statement)
    actually advances between calls. `TestListAndDeltaQueries` needs that:
    `db_conn`'s single-transaction `now()` made two sequential triggers land
    on the IDENTICAL `triggered_at`, which is a real bug in the TEST
    fixture's shape for this case, not in the repository code being tested.
    Cleanup is manual (FK cascades from the created event), same convention
    as `test_ws_dashboard.py`'s `real_conn`.
    """
    if not await _db_reachable():
        pytest.skip(f"no database reachable at {DATABASE_URL}")
    conn = await asyncpg.connect(DATABASE_URL)
    try:
        yield conn
    finally:
        await conn.close()


async def _make_searcher_and_device(conn):
    user_id = await _make_user(conn, "SOS Test Searcher")
    device_id, _wire_id, _key = await _make_device(conn, user_id)
    return user_id, device_id


class TestTrigger:
    async def test_creates_an_active_alert(self, db_conn):
        sector = await _make_sector(db_conn)
        user_id, device_id = await _make_searcher_and_device(db_conn)

        alert = await sos_repo.trigger(
            db_conn,
            sector_id=sector.id,
            device_id=device_id,
            user_id=user_id,
            lat=31.7715,
            lng=35.2170,
        )

        assert alert.status == "active"
        assert alert.sector_id == sector.id
        assert alert.device_id == device_id
        assert alert.user_id == user_id
        assert alert.triggered_at is not None
        assert alert.acknowledged_at is None
        assert alert.resolved_at is None
        assert alert.cancelled_at is None

    async def test_round_trips_lat_lng_through_geography(self, db_conn):
        sector = await _make_sector(db_conn)
        user_id, device_id = await _make_searcher_and_device(db_conn)

        alert = await sos_repo.trigger(
            db_conn, sector_id=sector.id, device_id=device_id, user_id=user_id,
            lat=31.771959, lng=35.217018,
        )

        assert alert.lat == pytest.approx(31.771959, abs=1e-6)
        assert alert.lng == pytest.approx(35.217018, abs=1e-6)

    async def test_a_missing_location_stores_null_geom(self, db_conn):
        sector = await _make_sector(db_conn)
        user_id, device_id = await _make_searcher_and_device(db_conn)

        alert = await sos_repo.trigger(
            db_conn, sector_id=sector.id, device_id=device_id, user_id=user_id,
            lat=None, lng=None,
        )

        assert alert.lat is None
        assert alert.lng is None

    async def test_a_second_trigger_from_the_same_device_is_idempotent(self, db_conn):
        sector = await _make_sector(db_conn)
        user_id, device_id = await _make_searcher_and_device(db_conn)

        first = await sos_repo.trigger(
            db_conn, sector_id=sector.id, device_id=device_id, user_id=user_id,
            lat=31.77, lng=35.21,
        )
        second = await sos_repo.trigger(
            db_conn, sector_id=sector.id, device_id=device_id, user_id=user_id,
            lat=31.99, lng=35.99,  # different coordinates -- must be IGNORED
        )

        assert second.id == first.id
        assert second.lat == pytest.approx(31.77, abs=1e-6), (
            "the SECOND trigger's coordinates must not overwrite the original alert"
        )

    async def test_a_new_sos_can_be_triggered_after_the_first_is_resolved(self, db_conn):
        sector = await _make_sector(db_conn)
        user_id, device_id = await _make_searcher_and_device(db_conn)

        first = await sos_repo.trigger(
            db_conn, sector_id=sector.id, device_id=device_id, user_id=user_id,
            lat=31.77, lng=35.21,
        )
        await sos_repo.resolve(db_conn, first.id, by_user_id=user_id)

        second = await sos_repo.trigger(
            db_conn, sector_id=sector.id, device_id=device_id, user_id=user_id,
            lat=31.77, lng=35.21,
        )

        assert second.id != first.id


class TestGetOpenForDevice:
    async def test_none_when_no_alert_exists(self, db_conn):
        _sector = await _make_sector(db_conn)
        _user_id, device_id = await _make_searcher_and_device(db_conn)

        assert await sos_repo.get_open_for_device(db_conn, device_id) is None

    async def test_finds_an_active_alert(self, db_conn):
        sector = await _make_sector(db_conn)
        user_id, device_id = await _make_searcher_and_device(db_conn)
        triggered = await sos_repo.trigger(
            db_conn, sector_id=sector.id, device_id=device_id, user_id=user_id,
            lat=31.77, lng=35.21,
        )

        found = await sos_repo.get_open_for_device(db_conn, device_id)

        assert found is not None
        assert found.id == triggered.id

    async def test_finds_an_acknowledged_alert_too(self, db_conn):
        sector = await _make_sector(db_conn)
        user_id, device_id = await _make_searcher_and_device(db_conn)
        triggered = await sos_repo.trigger(
            db_conn, sector_id=sector.id, device_id=device_id, user_id=user_id,
            lat=31.77, lng=35.21,
        )
        await sos_repo.acknowledge(db_conn, triggered.id, by_user_id=user_id)

        found = await sos_repo.get_open_for_device(db_conn, device_id)

        assert found is not None
        assert found.status == "acknowledged"

    async def test_none_after_resolution(self, db_conn):
        sector = await _make_sector(db_conn)
        user_id, device_id = await _make_searcher_and_device(db_conn)
        triggered = await sos_repo.trigger(
            db_conn, sector_id=sector.id, device_id=device_id, user_id=user_id,
            lat=31.77, lng=35.21,
        )
        await sos_repo.resolve(db_conn, triggered.id, by_user_id=user_id)

        assert await sos_repo.get_open_for_device(db_conn, device_id) is None


class TestAcknowledge:
    async def test_moves_active_to_acknowledged(self, db_conn):
        sector = await _make_sector(db_conn)
        user_id, device_id = await _make_searcher_and_device(db_conn)
        lead_id = await _make_user(db_conn, "SOS Test Lead")
        triggered = await sos_repo.trigger(
            db_conn, sector_id=sector.id, device_id=device_id, user_id=user_id,
            lat=31.77, lng=35.21,
        )

        acked = await sos_repo.acknowledge(db_conn, triggered.id, by_user_id=lead_id)

        assert acked is not None
        assert acked.status == "acknowledged"
        assert acked.acknowledged_by == lead_id
        assert acked.acknowledged_at is not None

    async def test_acknowledging_an_already_acknowledged_alert_is_a_no_op(self, db_conn):
        sector = await _make_sector(db_conn)
        user_id, device_id = await _make_searcher_and_device(db_conn)
        lead_id = await _make_user(db_conn, "SOS Test Lead")
        triggered = await sos_repo.trigger(
            db_conn, sector_id=sector.id, device_id=device_id, user_id=user_id,
            lat=31.77, lng=35.21,
        )
        await sos_repo.acknowledge(db_conn, triggered.id, by_user_id=lead_id)

        result = await sos_repo.acknowledge(db_conn, triggered.id, by_user_id=lead_id)

        assert result is None


class TestResolve:
    async def test_resolves_from_active(self, db_conn):
        sector = await _make_sector(db_conn)
        user_id, device_id = await _make_searcher_and_device(db_conn)
        lead_id = await _make_user(db_conn, "SOS Test Lead")
        triggered = await sos_repo.trigger(
            db_conn, sector_id=sector.id, device_id=device_id, user_id=user_id,
            lat=31.77, lng=35.21,
        )

        resolved = await sos_repo.resolve(db_conn, triggered.id, by_user_id=lead_id)

        assert resolved is not None
        assert resolved.status == "resolved"
        assert resolved.resolved_by == lead_id

    async def test_resolves_from_acknowledged(self, db_conn):
        sector = await _make_sector(db_conn)
        user_id, device_id = await _make_searcher_and_device(db_conn)
        lead_id = await _make_user(db_conn, "SOS Test Lead")
        triggered = await sos_repo.trigger(
            db_conn, sector_id=sector.id, device_id=device_id, user_id=user_id,
            lat=31.77, lng=35.21,
        )
        await sos_repo.acknowledge(db_conn, triggered.id, by_user_id=lead_id)

        resolved = await sos_repo.resolve(db_conn, triggered.id, by_user_id=lead_id)

        assert resolved is not None
        assert resolved.status == "resolved"

    async def test_resolving_an_already_resolved_alert_is_a_no_op(self, db_conn):
        sector = await _make_sector(db_conn)
        user_id, device_id = await _make_searcher_and_device(db_conn)
        lead_id = await _make_user(db_conn, "SOS Test Lead")
        triggered = await sos_repo.trigger(
            db_conn, sector_id=sector.id, device_id=device_id, user_id=user_id,
            lat=31.77, lng=35.21,
        )
        await sos_repo.resolve(db_conn, triggered.id, by_user_id=lead_id)

        result = await sos_repo.resolve(db_conn, triggered.id, by_user_id=lead_id)

        assert result is None


class TestCancel:
    async def test_cancels_from_active(self, db_conn):
        sector = await _make_sector(db_conn)
        user_id, device_id = await _make_searcher_and_device(db_conn)
        triggered = await sos_repo.trigger(
            db_conn, sector_id=sector.id, device_id=device_id, user_id=user_id,
            lat=31.77, lng=35.21,
        )

        cancelled = await sos_repo.cancel(db_conn, triggered.id)

        assert cancelled is not None
        assert cancelled.status == "cancelled"
        assert cancelled.cancelled_at is not None

    async def test_cancels_from_acknowledged(self, db_conn):
        sector = await _make_sector(db_conn)
        user_id, device_id = await _make_searcher_and_device(db_conn)
        lead_id = await _make_user(db_conn, "SOS Test Lead")
        triggered = await sos_repo.trigger(
            db_conn, sector_id=sector.id, device_id=device_id, user_id=user_id,
            lat=31.77, lng=35.21,
        )
        await sos_repo.acknowledge(db_conn, triggered.id, by_user_id=lead_id)

        cancelled = await sos_repo.cancel(db_conn, triggered.id)

        assert cancelled is not None
        assert cancelled.status == "cancelled"

    async def test_cannot_cancel_an_already_resolved_alert(self, db_conn):
        sector = await _make_sector(db_conn)
        user_id, device_id = await _make_searcher_and_device(db_conn)
        lead_id = await _make_user(db_conn, "SOS Test Lead")
        triggered = await sos_repo.trigger(
            db_conn, sector_id=sector.id, device_id=device_id, user_id=user_id,
            lat=31.77, lng=35.21,
        )
        await sos_repo.resolve(db_conn, triggered.id, by_user_id=lead_id)

        result = await sos_repo.cancel(db_conn, triggered.id)

        assert result is None


class TestListAndDeltaQueries:
    """Uses `real_conn`, not `db_conn` -- see that fixture's docstring.
    `db_conn` wraps the whole test in one transaction, and Postgres freezes
    `now()` at transaction START, so two sequential inserts under `db_conn`
    would get the IDENTICAL `triggered_at`/`updated_at`, making these
    ordering/delta assertions meaningless regardless of whether the
    repository code is correct.
    """

    async def test_list_for_sector_returns_newest_first(self, real_conn):
        sector = await _make_sector(real_conn)
        user_a = await _make_searcher_and_device(real_conn)
        user_b = await _make_searcher_and_device(real_conn)
        try:
            first = await sos_repo.trigger(
                real_conn, sector_id=sector.id, device_id=user_a[1], user_id=user_a[0],
                lat=31.77, lng=35.21,
            )
            second = await sos_repo.trigger(
                real_conn, sector_id=sector.id, device_id=user_b[1], user_id=user_b[0],
                lat=31.78, lng=35.22,
            )

            rows = await sos_repo.list_for_sector(real_conn, sector.id)

            assert [r.id for r in rows] == [second.id, first.id]
        finally:
            await real_conn.execute("DELETE FROM events WHERE id = $1", sector.event_id)
            await real_conn.execute(
                "DELETE FROM users WHERE id = ANY($1::uuid[])", [user_a[0], user_b[0]]
            )

    async def test_list_for_sector_respects_status_filter(self, real_conn):
        sector = await _make_sector(real_conn)
        user_a = await _make_searcher_and_device(real_conn)
        user_b = await _make_searcher_and_device(real_conn)
        try:
            active = await sos_repo.trigger(
                real_conn, sector_id=sector.id, device_id=user_a[1], user_id=user_a[0],
                lat=31.77, lng=35.21,
            )
            to_resolve = await sos_repo.trigger(
                real_conn, sector_id=sector.id, device_id=user_b[1], user_id=user_b[0],
                lat=31.78, lng=35.22,
            )
            await sos_repo.resolve(real_conn, to_resolve.id, by_user_id=user_b[0])

            active_only = await sos_repo.list_for_sector(
                real_conn, sector.id, status_filter="active"
            )

            assert [r.id for r in active_only] == [active.id]
        finally:
            await real_conn.execute("DELETE FROM events WHERE id = $1", sector.event_id)
            await real_conn.execute(
                "DELETE FROM users WHERE id = ANY($1::uuid[])", [user_a[0], user_b[0]]
            )

    async def test_get_for_sector_with_no_checkpoint_returns_everything(self, real_conn):
        sector = await _make_sector(real_conn)
        user_id, device_id = await _make_searcher_and_device(real_conn)
        try:
            await sos_repo.trigger(
                real_conn, sector_id=sector.id, device_id=device_id, user_id=user_id,
                lat=31.77, lng=35.21,
            )

            rows = await sos_repo.get_for_sector(real_conn, sector.id)

            assert len(rows) == 1
        finally:
            await real_conn.execute("DELETE FROM events WHERE id = $1", sector.event_id)
            await real_conn.execute("DELETE FROM users WHERE id = $1", user_id)

    async def test_get_for_sector_since_a_checkpoint_only_returns_later_changes(self, real_conn):
        sector = await _make_sector(real_conn)
        user_id, device_id = await _make_searcher_and_device(real_conn)
        try:
            triggered = await sos_repo.trigger(
                real_conn, sector_id=sector.id, device_id=device_id, user_id=user_id,
                lat=31.77, lng=35.21,
            )

            checkpoint = triggered.updated_at

            rows_immediately_after = await sos_repo.get_for_sector(
                real_conn, sector.id, checkpoint
            )
            assert rows_immediately_after == []

            await sos_repo.resolve(real_conn, triggered.id, by_user_id=user_id)
            rows_after_resolve = await sos_repo.get_for_sector(real_conn, sector.id, checkpoint)
            assert len(rows_after_resolve) == 1
            assert rows_after_resolve[0].status == "resolved"
        finally:
            await real_conn.execute("DELETE FROM events WHERE id = $1", sector.event_id)
            await real_conn.execute("DELETE FROM users WHERE id = $1", user_id)
