"""Phase 7 moderation, against a REAL Postgres: cascade deletion, user
removal with history retention, alert clearing, and re-application after a
rejection.

Every guarantee under test here is enforced by SQL -- FK `ON DELETE CASCADE`
closures, an `ON CONFLICT ... WHERE` upsert guard, a partial-status UPDATE --
so a mocked connection would verify only that this file's own assumptions
agree with themselves. These run against the real schema or they are skipped
(see conftest.py's `db_conn`).
"""

from __future__ import annotations

import uuid
from datetime import datetime, timedelta, timezone

import pytest

from app.repositories import events as events_repo
from app.repositories import memberships as memberships_repo
from app.repositories import sectors as sectors_repo
from app.repositories import sos as sos_repo
from app.repositories import track_points as track_points_repo
from tests.test_ingest_pipeline_db import _make_device, _make_user

pytestmark = pytest.mark.asyncio

SECTOR_BOUNDARY_GEOJSON = (
    '{"type":"Polygon","coordinates":[[[35.20,31.76],[35.20,31.78],'
    '[35.24,31.78],[35.24,31.76],[35.20,31.76]]]}'
)


async def _make_event(conn, name: str = "Moderation Callout"):
    commander_id = await _make_user(conn, "Moderation Commander")
    event_id = await conn.fetchval(
        "INSERT INTO events (name, commander_id, status) VALUES ($1, $2, 'active') "
        "RETURNING id",
        name,
        commander_id,
    )
    return event_id, commander_id


async def _make_sector_in(conn, event_id, name: str = "Sector A"):
    return await conn.fetchval(
        """
        INSERT INTO sectors (event_id, name, boundary)
        VALUES ($1, $2, ST_SetSRID(ST_GeomFromGeoJSON($3::json), 4326)::geography)
        RETURNING id
        """,
        event_id,
        name,
        SECTOR_BOUNDARY_GEOJSON,
    )


async def _approved_membership(conn, sector_id, user_id, device_id, *, role="volunteer"):
    return await conn.fetchval(
        """
        INSERT INTO sector_memberships (
            sector_id, user_id, device_id, role, status, approved_at,
            session_expires_at
        )
        VALUES ($1, $2, $3, $4, 'approved', now(), now() + interval '10 hours')
        RETURNING id
        """,
        sector_id,
        user_id,
        device_id,
        role,
    )


async def _make_segment_with_points(conn, sector_id, device_id, user_id, points):
    """A closed segment plus its points -- the searcher's scan history."""
    started = datetime.now(timezone.utc) - timedelta(minutes=30)
    segment_id = await conn.fetchval(
        """
        INSERT INTO track_segments (
            sector_id, device_id, user_id, movement_mode, started_at,
            last_recorded_at, last_lat, last_lng, point_count
        )
        VALUES ($1, $2, $3, 'walker', $4, $4, $5, $6, $7)
        RETURNING id
        """,
        sector_id,
        device_id,
        user_id,
        started,
        points[0][0],
        points[0][1],
        len(points),
    )
    for index, (lat, lng) in enumerate(points):
        await conn.execute(
            """
            INSERT INTO track_points (
                segment_id, sector_id, device_id, geom, recorded_at,
                accuracy_m, speed_mps, battery_pct, delivery_path, signature
            )
            VALUES ($1, $2, $3, ST_SetSRID(ST_MakePoint($5, $4), 4326)::geography,
                    $6, 5.0, 1.2, 80, 'direct', $7)
            """,
            segment_id,
            sector_id,
            device_id,
            lat,
            lng,
            started + timedelta(seconds=10 * index),
            uuid.uuid4().bytes + uuid.uuid4().bytes * 3,  # 64 unique bytes
        )
    await conn.execute(
        "UPDATE track_segments SET last_recorded_at = $2 WHERE id = $1",
        segment_id,
        started + timedelta(seconds=10 * (len(points) - 1)),
    )
    return segment_id


# ===========================================================================
# 1. Event cascade delete
# ===========================================================================


class TestEventCascadeDelete:
    async def test_purges_every_child_table(self, db_conn):
        """The point of the FK-cascade design: one DELETE, nothing orphaned."""
        event_id, commander_id = await _make_event(db_conn)
        sector_id = await _make_sector_in(db_conn, event_id)
        user_id = await _make_user(db_conn, "Cascade Searcher")
        device_id, _wire, _key = await _make_device(db_conn, user_id)
        await _approved_membership(db_conn, sector_id, user_id, device_id)
        segment_id = await _make_segment_with_points(
            db_conn, sector_id, device_id, user_id,
            [(31.770, 35.210), (31.771, 35.211)],
        )
        await db_conn.execute(
            "INSERT INTO hex_contributions (sector_id, hex_id, user_id, device_id, "
            "segment_id, segment_started_at, base_pod) "
            "VALUES ($1, 12345, $2, $3, $4, now(), 0.4)",
            sector_id, user_id, device_id, segment_id,
        )
        await db_conn.execute(
            "INSERT INTO hex_coverage_state (sector_id, hex_id, cumulative_pod) "
            "VALUES ($1, 12345, 0.4)",
            sector_id,
        )
        await sos_repo.trigger(
            db_conn, sector_id=sector_id, device_id=device_id, user_id=user_id,
            lat=31.77, lng=35.21,
        )
        await db_conn.execute(
            "INSERT INTO join_codes (code, sector_id, created_by, expires_at) "
            "VALUES ($1, $2, $3, now() + interval '1 hour')",
            f"{uuid.uuid4().int % 1_000_000:06d}", sector_id, commander_id,
        )
        await db_conn.execute(
            "INSERT INTO subjects (event_id, display_name, purge_after) "
            "VALUES ($1, 'Missing Person', now() + interval '30 days')",
            event_id,
        )
        await db_conn.execute(
            "INSERT INTO device_presence (sector_id, device_id) VALUES ($1, $2)",
            sector_id, device_id,
        )

        summary = await events_repo.summarize_for_deletion(db_conn, event_id)
        assert summary.sectors == 1
        assert summary.memberships == 1
        assert summary.track_points == 2
        assert summary.sos_alerts == 1

        sector_ids = await events_repo.delete(db_conn, event_id)
        assert sector_ids == [sector_id]

        for table in (
            "sector_memberships", "sector_keys", "join_codes",
            "track_segments", "track_points", "hex_contributions",
            "hex_coverage_state", "reports", "device_presence", "sos_alerts",
        ):
            remaining = await db_conn.fetchval(
                f"SELECT count(*) FROM {table} WHERE sector_id = $1", sector_id
            )
            assert remaining == 0, f"{table} still holds rows for a deleted event"

        assert await db_conn.fetchval(
            "SELECT count(*) FROM sectors WHERE id = $1", sector_id
        ) == 0

        assert await db_conn.fetchval(
            "SELECT count(*) FROM subjects WHERE event_id = $1", event_id
        ) == 0
        assert await db_conn.fetchval(
            "SELECT count(*) FROM events WHERE id = $1", event_id
        ) == 0

    async def test_leaves_users_and_devices_intact(self, db_conn):
        """Deleting a callout must not delete the volunteers who worked it --
        they belong to the system, not to one event."""
        event_id, _commander = await _make_event(db_conn)
        sector_id = await _make_sector_in(db_conn, event_id)
        user_id = await _make_user(db_conn, "Surviving Searcher")
        device_id, _wire, _key = await _make_device(db_conn, user_id)
        await _approved_membership(db_conn, sector_id, user_id, device_id)

        await events_repo.delete(db_conn, event_id)

        assert await db_conn.fetchval("SELECT count(*) FROM users WHERE id = $1", user_id) == 1
        assert await db_conn.fetchval(
            "SELECT count(*) FROM devices WHERE id = $1", device_id
        ) == 1

    async def test_returns_none_for_a_missing_event(self, db_conn):
        assert await events_repo.delete(db_conn, uuid.uuid4()) is None


# ===========================================================================
# 2. User removal: access ends, history survives
# ===========================================================================


class TestEventMemberRemoval:
    async def test_revokes_across_every_sector_of_the_event(self, db_conn):
        event_id, _commander = await _make_event(db_conn)
        sector_a = await _make_sector_in(db_conn, event_id, "A")
        sector_b = await _make_sector_in(db_conn, event_id, "B")
        user_id = await _make_user(db_conn, "Removed Searcher")
        device_a, _w, _k = await _make_device(db_conn, user_id)
        device_b, _w, _k = await _make_device(db_conn, user_id)
        await _approved_membership(db_conn, sector_a, user_id, device_a)
        await _approved_membership(db_conn, sector_b, user_id, device_b)

        revoked = await memberships_repo.revoke_all_for_user_in_event(
            db_conn, event_id, user_id
        )
        assert revoked == 2

        rows = await memberships_repo.list_for_event_user(db_conn, event_id, user_id)
        assert [row.status for row in rows] == ["revoked", "revoked"]

        # The session window was slammed shut -- the second, independent
        # reason `current_membership` rejects the token, alongside the status.
        #
        # Compared against the DATABASE's clock, not the Python process's.
        # Those are two different clocks (the server can sit a few hundred
        # milliseconds off the host), and a `datetime.now()` here made this
        # assertion a coin flip that happened to land the right way in
        # isolation and the wrong way under a longer run.
        db_now = await db_conn.fetchval("SELECT clock_timestamp()")
        assert all(row.session_expires_at <= db_now for row in rows)
        # Emphatically not the 10-hour window it was approved with.
        assert all(
            row.session_expires_at < row.approved_at + timedelta(hours=1)
            for row in rows
        )

    async def test_retains_scan_history(self, db_conn):
        """The load-bearing guarantee: removal ends access, it does not
        rewrite the search record."""
        event_id, _commander = await _make_event(db_conn)
        sector_id = await _make_sector_in(db_conn, event_id)
        user_id = await _make_user(db_conn, "Historical Searcher")
        device_id, _wire, _key = await _make_device(db_conn, user_id)
        await _approved_membership(db_conn, sector_id, user_id, device_id)
        segment_id = await _make_segment_with_points(
            db_conn, sector_id, device_id, user_id,
            [(31.770, 35.210), (31.771, 35.211), (31.772, 35.212)],
        )
        await db_conn.execute(
            "INSERT INTO hex_contributions (sector_id, hex_id, user_id, device_id, "
            "segment_id, segment_started_at, base_pod) "
            "VALUES ($1, 999, $2, $3, $4, now(), 0.4)",
            sector_id, user_id, device_id, segment_id,
        )

        await memberships_repo.revoke_all_for_user_in_event(db_conn, event_id, user_id)

        assert await db_conn.fetchval(
            "SELECT count(*) FROM track_points WHERE segment_id = $1", segment_id
        ) == 3
        # Still attributed to them, and still counted as valid coverage --
        # the ground really was walked.
        assert await db_conn.fetchval(
            "SELECT count(*) FROM hex_contributions WHERE user_id = $1 AND is_valid",
            user_id,
        ) == 1
        assert await db_conn.fetchval(
            "SELECT count(*) FROM track_segments WHERE user_id = $1 AND is_valid",
            user_id,
        ) == 1

    async def test_removed_user_loses_event_and_sector_visibility(self, db_conn):
        event_id, _commander = await _make_event(db_conn)
        sector_id = await _make_sector_in(db_conn, event_id)
        user_id = await _make_user(db_conn, "Visibility Searcher")
        device_id, _wire, _key = await _make_device(db_conn, user_id)
        await _approved_membership(db_conn, sector_id, user_id, device_id)

        assert await memberships_repo.user_has_membership_in_event(
            db_conn, event_id, user_id
        )

        await memberships_repo.revoke_all_for_user_in_event(db_conn, event_id, user_id)

        # The row still exists -- and must NOT be mistaken for a role.
        assert not await memberships_repo.user_has_membership_in_event(
            db_conn, event_id, user_id
        )
        membership = await memberships_repo.get_by_user(db_conn, sector_id, user_id)
        assert membership is not None
        assert membership.status not in memberships_repo.VISIBILITY_STATUSES

    async def test_ended_event_keeps_members_visibility(self, db_conn):
        """Teardown sweeps memberships to 'ended'; that is not a removal, and
        must not cost a searcher access to the callout they just worked."""
        event_id, _commander = await _make_event(db_conn)
        sector_id = await _make_sector_in(db_conn, event_id)
        user_id = await _make_user(db_conn, "Post-callout Searcher")
        device_id, _wire, _key = await _make_device(db_conn, user_id)
        await _approved_membership(db_conn, sector_id, user_id, device_id)

        await memberships_repo.end_all_for_event(db_conn, event_id)

        assert await memberships_repo.user_has_membership_in_event(
            db_conn, event_id, user_id
        )

    async def test_clearing_the_lead_pointer_strips_lead_authority(self, db_conn):
        event_id, _commander = await _make_event(db_conn)
        sector_id = await _make_sector_in(db_conn, event_id)
        lead_id = await _make_user(db_conn, "Departing Lead")
        device_id, _wire, _key = await _make_device(db_conn, lead_id)
        await _approved_membership(db_conn, sector_id, lead_id, device_id, role="lead")
        await sectors_repo.set_lead(db_conn, sector_id, lead_id)

        cleared = await sectors_repo.clear_lead_for_user(db_conn, event_id, lead_id)
        assert cleared == 1

        sector = await sectors_repo.get(db_conn, sector_id)
        assert sector.lead_user_id is None


# ===========================================================================
# 3. Re-application after rejection / removal
# ===========================================================================


class TestReapplyAfterRejection:
    async def _join(self, conn, sector_id, user_id, device_id, mode="walker"):
        return await memberships_repo.create_or_reopen_pending(
            conn,
            sector_id=sector_id,
            user_id=user_id,
            device_id=device_id,
            movement_mode=mode,
            battery_at_join=90,
            powerbank_attested=False,
        )

    async def test_rejected_volunteer_can_apply_again(self, db_conn):
        """The bug: one rejection used to lock a device out of a sector for
        the rest of the callout."""
        event_id, _commander = await _make_event(db_conn)
        sector_id = await _make_sector_in(db_conn, event_id)
        user_id = await _make_user(db_conn, "Re-applying Searcher")
        device_id, _wire, _key = await _make_device(db_conn, user_id)

        first = await self._join(db_conn, sector_id, user_id, device_id)
        assert first is not None and first.status == "pending"

        rejected = await memberships_repo.reject(db_conn, first.id)
        assert rejected.status == "rejected"

        second = await self._join(db_conn, sector_id, user_id, device_id, mode="vehicle")
        assert second is not None
        assert second.status == "pending"
        # A genuinely fresh request, not the old one wearing a new status.
        assert second.movement_mode == "vehicle"
        assert second.approved_at is None
        assert second.approved_by is None
        assert second.revoked_at is None
        assert second.session_expires_at is None
        assert second.key_epoch_issued is None
        assert second.role == "volunteer"

    async def test_removed_volunteer_can_apply_again(self, db_conn):
        event_id, _commander = await _make_event(db_conn)
        sector_id = await _make_sector_in(db_conn, event_id)
        user_id = await _make_user(db_conn, "Returning Searcher")
        device_id, _wire, _key = await _make_device(db_conn, user_id)

        first = await self._join(db_conn, sector_id, user_id, device_id)
        await memberships_repo.approve(
            db_conn, first.id,
            approved_by=user_id, key_epoch=1,
            session_expires_at=datetime.now(timezone.utc) + timedelta(hours=8),
        )
        await memberships_repo.revoke(db_conn, first.id)

        again = await self._join(db_conn, sector_id, user_id, device_id)
        assert again is not None and again.status == "pending"

    async def test_after_event_teardown_the_device_can_join_a_new_run(self, db_conn):
        event_id, _commander = await _make_event(db_conn)
        sector_id = await _make_sector_in(db_conn, event_id)
        user_id = await _make_user(db_conn, "Next Callout Searcher")
        device_id, _wire, _key = await _make_device(db_conn, user_id)

        first = await self._join(db_conn, sector_id, user_id, device_id)
        await memberships_repo.approve(
            db_conn, first.id,
            approved_by=user_id, key_epoch=1,
            session_expires_at=datetime.now(timezone.utc) + timedelta(hours=8),
        )
        await memberships_repo.end_all_for_event(db_conn, event_id)

        again = await self._join(db_conn, sector_id, user_id, device_id)
        assert again is not None and again.status == "pending"

    async def test_a_live_request_is_still_a_duplicate(self, db_conn):
        """The reopen must not become a way to overwrite a pending or
        approved membership."""
        event_id, _commander = await _make_event(db_conn)
        sector_id = await _make_sector_in(db_conn, event_id)
        user_id = await _make_user(db_conn, "Impatient Searcher")
        device_id, _wire, _key = await _make_device(db_conn, user_id)

        first = await self._join(db_conn, sector_id, user_id, device_id)
        assert first is not None

        assert await self._join(db_conn, sector_id, user_id, device_id) is None

        await memberships_repo.approve(
            db_conn, first.id,
            approved_by=user_id, key_epoch=1,
            session_expires_at=datetime.now(timezone.utc) + timedelta(hours=8),
        )
        assert await self._join(db_conn, sector_id, user_id, device_id) is None
        # And the approval survived the attempts.
        current = await memberships_repo.get(db_conn, first.id)
        assert current.status == "approved"

    async def test_one_row_per_device_still_holds(self, db_conn):
        event_id, _commander = await _make_event(db_conn)
        sector_id = await _make_sector_in(db_conn, event_id)
        user_id = await _make_user(db_conn, "Single Row Searcher")
        device_id, _wire, _key = await _make_device(db_conn, user_id)

        first = await self._join(db_conn, sector_id, user_id, device_id)
        await memberships_repo.reject(db_conn, first.id)
        second = await self._join(db_conn, sector_id, user_id, device_id)

        assert second.id == first.id
        assert await db_conn.fetchval(
            "SELECT count(*) FROM sector_memberships WHERE sector_id = $1 AND device_id = $2",
            sector_id, device_id,
        ) == 1


# ===========================================================================
# 4. Alert clearing
# ===========================================================================


class TestAlertDeletion:
    async def _alert(self, conn, sector_id, user_id, device_id):
        return await sos_repo.trigger(
            conn, sector_id=sector_id, device_id=device_id, user_id=user_id,
            lat=31.77, lng=35.21,
        )

    async def test_deletes_a_closed_alert(self, db_conn):
        event_id, commander_id = await _make_event(db_conn)
        sector_id = await _make_sector_in(db_conn, event_id)
        user_id = await _make_user(db_conn, "Alert Searcher")
        device_id, _wire, _key = await _make_device(db_conn, user_id)
        alert = await self._alert(db_conn, sector_id, user_id, device_id)
        await sos_repo.resolve(db_conn, alert.id, by_user_id=commander_id)

        deleted = await sos_repo.delete(db_conn, alert.id)
        assert deleted is not None and deleted.id == alert.id
        assert await sos_repo.get(db_conn, alert.id) is None
        assert await sos_repo.delete(db_conn, alert.id) is None

    async def test_bulk_clear_spares_open_alerts(self, db_conn):
        """'Clear the list' must never be able to silence a live emergency."""
        event_id, commander_id = await _make_event(db_conn)
        sector_id = await _make_sector_in(db_conn, event_id)

        open_user = await _make_user(db_conn, "Still In Trouble")
        open_device, _w, _k = await _make_device(db_conn, open_user)
        open_alert = await self._alert(db_conn, sector_id, open_user, open_device)

        ack_user = await _make_user(db_conn, "Being Helped")
        ack_device, _w, _k = await _make_device(db_conn, ack_user)
        ack_alert = await self._alert(db_conn, sector_id, ack_user, ack_device)
        await sos_repo.acknowledge(db_conn, ack_alert.id, by_user_id=commander_id)

        done_user = await _make_user(db_conn, "Already Fine")
        done_device, _w, _k = await _make_device(db_conn, done_user)
        done_alert = await self._alert(db_conn, sector_id, done_user, done_device)
        await sos_repo.resolve(db_conn, done_alert.id, by_user_id=commander_id)

        cancelled_user = await _make_user(db_conn, "False Alarm")
        cancelled_device, _w, _k = await _make_device(db_conn, cancelled_user)
        cancelled_alert = await self._alert(
            db_conn, sector_id, cancelled_user, cancelled_device
        )
        await sos_repo.cancel(db_conn, cancelled_alert.id)

        removed = await sos_repo.delete_closed_for_sector(db_conn, sector_id)

        assert set(removed) == {done_alert.id, cancelled_alert.id}
        assert await sos_repo.get(db_conn, open_alert.id) is not None
        assert await sos_repo.get(db_conn, ack_alert.id) is not None

    async def test_bulk_clear_is_scoped_to_one_sector(self, db_conn):
        event_id, commander_id = await _make_event(db_conn)
        sector_a = await _make_sector_in(db_conn, event_id, "A")
        sector_b = await _make_sector_in(db_conn, event_id, "B")

        user_a = await _make_user(db_conn, "Sector A Searcher")
        device_a, _w, _k = await _make_device(db_conn, user_a)
        alert_a = await self._alert(db_conn, sector_a, user_a, device_a)
        await sos_repo.resolve(db_conn, alert_a.id, by_user_id=commander_id)

        user_b = await _make_user(db_conn, "Sector B Searcher")
        device_b, _w, _k = await _make_device(db_conn, user_b)
        alert_b = await self._alert(db_conn, sector_b, user_b, device_b)
        await sos_repo.resolve(db_conn, alert_b.id, by_user_id=commander_id)

        removed = await sos_repo.delete_closed_for_sector(db_conn, sector_a)

        assert removed == [alert_a.id]
        assert await sos_repo.get(db_conn, alert_b.id) is not None


# ===========================================================================
# 5. Team scan paths
# ===========================================================================


class TestTeamTracks:
    async def test_returns_every_searcher_not_just_one(self, db_conn):
        """The bug this endpoint fixes: the field app could only ever draw
        the logged-in user's own trail."""
        event_id, _commander = await _make_event(db_conn)
        sector_id = await _make_sector_in(db_conn, event_id)

        alice = await _make_user(db_conn, "Alice")
        alice_device, _w, _k = await _make_device(db_conn, alice)
        await _make_segment_with_points(
            db_conn, sector_id, alice_device, alice,
            [(31.770, 35.210), (31.771, 35.211), (31.772, 35.212)],
        )

        bob = await _make_user(db_conn, "Bob")
        bob_device, _w, _k = await _make_device(db_conn, bob)
        await _make_segment_with_points(
            db_conn, sector_id, bob_device, bob,
            [(31.775, 35.220), (31.776, 35.221)],
        )

        tracks = await track_points_repo.get_team_tracks(db_conn, sector_id)

        assert {t.user_id for t in tracks} == {alice, bob}
        for track in tracks:
            assert len(track.points) >= 2
            # (lat, lng), not GeoJSON's (lng, lat): latitudes near 31.7,
            # longitudes near 35.2 -- a transposition would be obvious here
            # and invisible on a map until someone noticed the wrong country.
            assert 31.0 < track.points[0][0] < 32.0
            assert 35.0 < track.points[0][1] < 36.0

    async def test_excludes_invalidated_segments(self, db_conn):
        event_id, _commander = await _make_event(db_conn)
        sector_id = await _make_sector_in(db_conn, event_id)
        user_id = await _make_user(db_conn, "Retracted Searcher")
        device_id, _w, _k = await _make_device(db_conn, user_id)
        segment_id = await _make_segment_with_points(
            db_conn, sector_id, device_id, user_id,
            [(31.770, 35.210), (31.771, 35.211)],
        )
        await track_points_repo.invalidate_segment(db_conn, segment_id, "implausible")

        assert await track_points_repo.get_team_tracks(db_conn, sector_id) == []

    async def test_since_returns_a_segment_that_is_still_growing(self, db_conn):
        """Filtering on the segment's LAST point, not its first: an open
        traverse must keep updating on teammates' maps."""
        event_id, _commander = await _make_event(db_conn)
        sector_id = await _make_sector_in(db_conn, event_id)
        user_id = await _make_user(db_conn, "Walking Searcher")
        device_id, _w, _k = await _make_device(db_conn, user_id)
        segment_id = await _make_segment_with_points(
            db_conn, sector_id, device_id, user_id,
            [(31.770, 35.210), (31.771, 35.211)],
        )

        # Checkpoint AFTER the segment started but BEFORE its next point.
        checkpoint = datetime.now(timezone.utc)
        await db_conn.execute(
            "UPDATE track_segments SET last_recorded_at = $2 WHERE id = $1",
            segment_id,
            checkpoint + timedelta(seconds=5),
        )

        tracks = await track_points_repo.get_team_tracks(
            db_conn, sector_id, since=checkpoint
        )
        assert [t.segment_id for t in tracks] == [segment_id]

        # Nothing has moved since this later checkpoint.
        assert await track_points_repo.get_team_tracks(
            db_conn, sector_id, since=checkpoint + timedelta(minutes=1)
        ) == []

    async def test_single_point_segments_are_skipped(self, db_conn):
        """One fix is a position, not a path -- there is no line to draw."""
        event_id, _commander = await _make_event(db_conn)
        sector_id = await _make_sector_in(db_conn, event_id)
        user_id = await _make_user(db_conn, "Standing Still")
        device_id, _w, _k = await _make_device(db_conn, user_id)
        await _make_segment_with_points(
            db_conn, sector_id, device_id, user_id, [(31.770, 35.210)]
        )

        assert await track_points_repo.get_team_tracks(db_conn, sector_id) == []
