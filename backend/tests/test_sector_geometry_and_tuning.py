"""Boundary editing on PATCH /sectors/{id}, and the tuning recalc/resolution gate.

The load-bearing claim proved here is a NEGATIVE one: redrawing a sector's
boundary must leave the coverage ledger completely untouched. That is not an
oversight to be "fixed" later -- `hex_contributions` records where searchers
physically walked (the ingest pipeline buffers the track and hexifies it
without ever intersecting the sector polygon), and `recalc_hex_coverage()`
reads only that ledger plus `repeat_discount`. If someone later adds a recalc
call to the boundary path believing it does something, these tests are what
should stop them.

The POSITIVE recalc case lives on tuning instead: `repeat_discount` is read
live by the SQL function, so changing it genuinely does re-weight history.
"""

from __future__ import annotations

import json
import uuid

import asyncpg
import pytest
from fastapi.testclient import TestClient
from nacl.signing import SigningKey

from app.config import get_settings
from app.main import app
from app.security.tokens import issue_account_token
from tests.conftest import DATABASE_URL

pytestmark = pytest.mark.asyncio

ORIGINAL_BOUNDARY = {
    "type": "Polygon",
    "coordinates": [[
        [34.70, 31.40], [34.90, 31.40], [34.90, 31.60], [34.70, 31.60], [34.70, 31.40],
    ]],
}
# Deliberately far away, so every previously-covered hex falls outside it.
RELOCATED_BOUNDARY = {
    "type": "Polygon",
    "coordinates": [[
        [34.10, 31.10], [34.12, 31.10], [34.12, 31.12], [34.10, 31.12], [34.10, 31.10],
    ]],
}
# A real H3 res-12 cell inside ORIGINAL_BOUNDARY.
COVERED_HEX = 631308114074895359


async def _db_reachable() -> bool:
    try:
        conn = await asyncpg.connect(DATABASE_URL, timeout=5)
        await conn.close()
        return True
    except (OSError, asyncpg.PostgresError):
        return False


@pytest.fixture
async def real_conn():
    if not await _db_reachable():
        pytest.skip(f"no database reachable at {DATABASE_URL}")
    conn = await asyncpg.connect(DATABASE_URL)
    try:
        yield conn
    finally:
        await conn.close()


async def _make_user(conn, name: str) -> uuid.UUID:
    return await conn.fetchval(
        "INSERT INTO users (phone_e164, display_name) VALUES ($1, $2) RETURNING id",
        f"+1555{uuid.uuid4().int % 10_000_000:07d}",
        name,
    )


async def _make_device(conn, user_id: uuid.UUID) -> uuid.UUID:
    return await conn.fetchval(
        """
        INSERT INTO devices (user_id, ed25519_public_key, platform)
        VALUES ($1, $2, 'android') RETURNING id
        """,
        user_id,
        bytes(SigningKey.generate().verify_key),
    )


async def _make_sector(conn, commander_id: uuid.UUID) -> uuid.UUID:
    event_id = await conn.fetchval(
        "INSERT INTO events (name, commander_id, status) VALUES ($1, $2, 'active') RETURNING id",
        "Geometry Test Event",
        commander_id,
    )
    return await conn.fetchval(
        """
        INSERT INTO sectors (event_id, name, boundary)
        VALUES ($1, 'Geometry Test Sector',
                ST_SetSRID(ST_GeomFromGeoJSON($2::json), 4326)::geography)
        RETURNING id
        """,
        event_id,
        json.dumps(ORIGINAL_BOUNDARY),
    )


async def _add_coverage(conn, sector_id: uuid.UUID, user_id: uuid.UUID, device_id: uuid.UUID):
    """One contribution over COVERED_HEX, with derived state materialised.

    `ended_at` is set because these represent COMPLETED traverse episodes --
    and because `track_segments_open_idx` is a partial unique index allowing
    only one open segment per device, so leaving them open makes a second
    pass by the same searcher impossible to record.
    """
    segment_id = await conn.fetchval(
        """
        INSERT INTO track_segments
            (sector_id, device_id, user_id, movement_mode, started_at, ended_at)
        VALUES ($1, $2, $3, 'walker', now(), now()) RETURNING id
        """,
        sector_id, device_id, user_id,
    )
    await conn.execute(
        """
        INSERT INTO hex_contributions
            (sector_id, hex_id, user_id, device_id, segment_id, segment_started_at, base_pod)
        VALUES ($1, $2, $3, $4, $5, now(), 0.400)
        """,
        sector_id, COVERED_HEX, user_id, device_id, segment_id,
    )
    await conn.fetchval(
        "SELECT recalc_hex_coverage($1, $2)", sector_id, [COVERED_HEX]
    )


async def _coverage_row(conn, sector_id: uuid.UUID):
    return await conn.fetchrow(
        """
        SELECT cumulative_pod, valid_contributions, distinct_searchers
        FROM hex_coverage_state WHERE sector_id = $1 AND hex_id = $2
        """,
        sector_id, COVERED_HEX,
    )


def _headers(user_id: uuid.UUID) -> dict:
    token, _ = issue_account_token(get_settings(), user_id)
    return {"Authorization": f"Bearer {token}"}


class TestBoundaryEditing:
    async def test_commander_can_redraw_the_boundary(self, real_conn):
        commander_id = await _make_user(real_conn, "Geometry Commander")
        sector_id = await _make_sector(real_conn, commander_id)

        with TestClient(app) as client:
            r = client.patch(
                f"/sectors/{sector_id}",
                json={"boundary": RELOCATED_BOUNDARY},
                headers=_headers(commander_id),
            )
            assert r.status_code == 200
            returned = r.json()["boundary"]

        assert returned["type"] == "Polygon"
        # The stored geometry really changed, not just the response echo.
        stored = json.loads(
            await real_conn.fetchval(
                "SELECT ST_AsGeoJSON(boundary::geometry) FROM sectors WHERE id = $1",
                sector_id,
            )
        )
        assert stored["coordinates"][0][0][0] == pytest.approx(34.10, abs=1e-6)

    async def test_redrawing_the_boundary_does_NOT_disturb_coverage(self, real_conn):
        """The core guarantee: physical coverage survives an administrative
        redraw, even when every covered hex ends up outside the new outline."""
        commander_id = await _make_user(real_conn, "Geometry Commander Coverage")
        sector_id = await _make_sector(real_conn, commander_id)
        device_id = await _make_device(real_conn, commander_id)
        await _add_coverage(real_conn, sector_id, commander_id, device_id)

        before = await _coverage_row(real_conn, sector_id)
        assert before is not None and before["cumulative_pod"] > 0

        with TestClient(app) as client:
            r = client.patch(
                f"/sectors/{sector_id}",
                json={"boundary": RELOCATED_BOUNDARY},
                headers=_headers(commander_id),
            )
            assert r.status_code == 200

        after = await _coverage_row(real_conn, sector_id)
        assert after is not None, "coverage row was deleted by a boundary edit"
        assert after["cumulative_pod"] == before["cumulative_pod"]
        assert after["valid_contributions"] == before["valid_contributions"]
        assert after["distinct_searchers"] == before["distinct_searchers"]

        # The contribution itself is untouched too.
        assert await real_conn.fetchval(
            "SELECT count(*) FROM hex_contributions WHERE sector_id = $1", sector_id
        ) == 1

    async def test_status_and_boundary_can_be_updated_together(self, real_conn):
        commander_id = await _make_user(real_conn, "Geometry Commander Both")
        sector_id = await _make_sector(real_conn, commander_id)

        with TestClient(app) as client:
            r = client.patch(
                f"/sectors/{sector_id}",
                json={"status": "paused", "boundary": RELOCATED_BOUNDARY},
                headers=_headers(commander_id),
            )
            assert r.status_code == 200
            assert r.json()["status"] == "paused"

        stored = json.loads(
            await real_conn.fetchval(
                "SELECT ST_AsGeoJSON(boundary::geometry) FROM sectors WHERE id = $1",
                sector_id,
            )
        )
        assert stored["coordinates"][0][0][0] == pytest.approx(34.10, abs=1e-6)

    async def test_empty_body_is_rejected(self, real_conn):
        """An empty patch would otherwise 200 having done nothing."""
        commander_id = await _make_user(real_conn, "Geometry Commander Empty")
        sector_id = await _make_sector(real_conn, commander_id)

        with TestClient(app) as client:
            r = client.patch(f"/sectors/{sector_id}", json={}, headers=_headers(commander_id))
            assert r.status_code == 422

    async def test_unclosed_ring_is_rejected(self, real_conn):
        commander_id = await _make_user(real_conn, "Geometry Commander Ring")
        sector_id = await _make_sector(real_conn, commander_id)
        unclosed = {
            "type": "Polygon",
            "coordinates": [[[34.1, 31.1], [34.2, 31.1], [34.2, 31.2], [34.1, 31.2]]],
        }

        with TestClient(app) as client:
            r = client.patch(
                f"/sectors/{sector_id}",
                json={"boundary": unclosed},
                headers=_headers(commander_id),
            )
            assert r.status_code == 422

    async def test_stranger_cannot_redraw(self, real_conn):
        commander_id = await _make_user(real_conn, "Geometry Commander RBAC")
        sector_id = await _make_sector(real_conn, commander_id)
        stranger_id = await _make_user(real_conn, "Geometry Stranger")

        with TestClient(app) as client:
            r = client.patch(
                f"/sectors/{sector_id}",
                json={"boundary": RELOCATED_BOUNDARY},
                headers=_headers(stranger_id),
            )
            assert r.status_code == 403


class TestTuningRecalc:
    async def test_changing_repeat_discount_recalculates_existing_coverage(
        self, real_conn
    ):
        """`repeat_discount` is read live by recalc_hex_coverage, so it DOES
        re-weight history -- the case where a recalc is genuinely required."""
        commander_id = await _make_user(real_conn, "Tuning Commander")
        sector_id = await _make_sector(real_conn, commander_id)
        device_id = await _make_device(real_conn, commander_id)
        # Two passes by the SAME user over one hex, so the repeat discount
        # actually participates: pass 2 is weighted by repeat_discount^1.
        await _add_coverage(real_conn, sector_id, commander_id, device_id)
        await _add_coverage(real_conn, sector_id, commander_id, device_id)

        before = (await _coverage_row(real_conn, sector_id))["cumulative_pod"]

        with TestClient(app) as client:
            r = client.patch(
                f"/sectors/{sector_id}/tuning",
                json={"repeat_discount": 0.9},
                headers=_headers(commander_id),
            )
            assert r.status_code == 200

        after = (await _coverage_row(real_conn, sector_id))["cumulative_pod"]
        assert after != before, (
            "repeat_discount changed but cumulative_pod did not -- the recalc "
            "did not run, leaving stale search-theory numbers on the map"
        )

    async def test_changing_a_non_pod_field_leaves_coverage_alone(self, real_conn):
        """base_pod_day is snapshotted into hex_contributions at ingest, so it
        must NOT retroactively change already-recorded coverage."""
        commander_id = await _make_user(real_conn, "Tuning Commander NonPod")
        sector_id = await _make_sector(real_conn, commander_id)
        device_id = await _make_device(real_conn, commander_id)
        await _add_coverage(real_conn, sector_id, commander_id, device_id)

        before = (await _coverage_row(real_conn, sector_id))["cumulative_pod"]

        with TestClient(app) as client:
            r = client.patch(
                f"/sectors/{sector_id}/tuning",
                json={"base_pod_day": 0.9},
                headers=_headers(commander_id),
            )
            assert r.status_code == 200

        after = (await _coverage_row(real_conn, sector_id))["cumulative_pod"]
        assert after == before


class TestResolutionGate:
    async def test_resolution_change_blocked_once_contributions_exist(self, real_conn):
        commander_id = await _make_user(real_conn, "Resolution Commander")
        sector_id = await _make_sector(real_conn, commander_id)
        device_id = await _make_device(real_conn, commander_id)
        await _add_coverage(real_conn, sector_id, commander_id, device_id)

        with TestClient(app) as client:
            r = client.patch(
                f"/sectors/{sector_id}/tuning",
                json={"h3_resolution": 10},
                headers=_headers(commander_id),
            )
            assert r.status_code == 409
            assert "h3_resolution" in r.json()["error"]["message"]

        # And the stored resolution is unchanged.
        assert await real_conn.fetchval(
            "SELECT h3_resolution FROM sectors WHERE id = $1", sector_id
        ) == 12

    async def test_resolution_change_allowed_before_any_coverage(self, real_conn):
        commander_id = await _make_user(real_conn, "Resolution Commander Clean")
        sector_id = await _make_sector(real_conn, commander_id)

        with TestClient(app) as client:
            r = client.patch(
                f"/sectors/{sector_id}/tuning",
                json={"h3_resolution": 10},
                headers=_headers(commander_id),
            )
            assert r.status_code == 200
            assert r.json()["h3_resolution"] == 10

    async def test_resending_the_same_resolution_is_not_blocked(self, real_conn):
        """Re-sending the current value is a no-op, not a conflict -- a UI that
        PATCHes the whole tuning form would otherwise be unable to save
        anything once coverage exists."""
        commander_id = await _make_user(real_conn, "Resolution Commander Same")
        sector_id = await _make_sector(real_conn, commander_id)
        device_id = await _make_device(real_conn, commander_id)
        await _add_coverage(real_conn, sector_id, commander_id, device_id)

        with TestClient(app) as client:
            r = client.patch(
                f"/sectors/{sector_id}/tuning",
                json={"h3_resolution": 12, "max_gap_seconds": 45},
                headers=_headers(commander_id),
            )
            assert r.status_code == 200
            assert r.json()["max_gap_seconds"] == 45
