"""PATCH /sectors/{id} (recruitment on/off) at the HTTP route layer, plus a
regression test for the actual bug that motivated adding this endpoint: a
sector defaults to 'open' at creation with no way to request otherwise, so
"why can't a volunteer join a freshly-created sector" was never actually a
sector-status problem -- it was the EVENT still sitting in 'draft' (see
routes/memberships.py's join_sector, which rejects on either the sector OR
the event being non-accepting). Both gates are exercised here so this
specific class of bug can't silently regress. Same TestClient-on-a-real-app
pattern as test_sos_routes.py, for the same reasons documented there.
"""

from __future__ import annotations

import uuid

import asyncpg
import pytest
from fastapi.testclient import TestClient
from nacl.signing import SigningKey

from app.config import get_settings
from app.main import app
from app.repositories import join_codes as join_codes_repo
from app.security.tokens import issue_account_token
from tests.conftest import DATABASE_URL

pytestmark = pytest.mark.asyncio

SECTOR_BOUNDARY_GEOJSON = (
    '{"type":"Polygon","coordinates":[[[35.30,31.86],[35.30,31.88],'
    '[35.34,31.88],[35.34,31.86],[35.30,31.86]]]}'
)


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
        f"+1555{uuid.uuid4().int % 10_000_000_000:010d}",
        name,
    )


async def _make_device(conn, user_id: uuid.UUID) -> uuid.UUID:
    signing_key = SigningKey.generate()
    return await conn.fetchval(
        """
        INSERT INTO devices (user_id, ed25519_public_key, platform, mesh_capable)
        VALUES ($1, $2, 'android', true)
        RETURNING id
        """,
        user_id,
        bytes(signing_key.verify_key),
    )


async def _make_event(conn, commander_id: uuid.UUID, status: str = "active") -> uuid.UUID:
    return await conn.fetchval(
        "INSERT INTO events (name, commander_id, status) VALUES ($1, $2, $3) RETURNING id",
        "Sector Status Test Event",
        commander_id,
        status,
    )


async def _make_sector(conn, event_id: uuid.UUID) -> uuid.UUID:
    return await conn.fetchval(
        """
        INSERT INTO sectors (event_id, name, boundary)
        VALUES ($1, 'Sector Status Test Sector', ST_SetSRID(ST_GeomFromGeoJSON($2::json), 4326)::geography)
        RETURNING id
        """,
        event_id,
        SECTOR_BOUNDARY_GEOJSON,
    )


async def _join_payload(conn, sector_id: uuid.UUID, *, ttl_seconds: int = 3600) -> tuple[dict, str]:
    """Creates a join code and a fresh volunteer+device, returns
    (join request body, volunteer's account bearer token)."""
    settings = get_settings()
    creator_id = await _make_user(conn, "Sector Status Test Code Creator")
    code = await join_codes_repo.create(
        conn, sector_id=sector_id, created_by=creator_id, ttl_seconds=ttl_seconds, max_uses=None
    )
    volunteer_id = await _make_user(conn, "Sector Status Test Volunteer")
    device_id = await _make_device(conn, volunteer_id)
    token, _ = issue_account_token(settings, volunteer_id)
    return (
        {
            "code": code.code,
            "device_id": str(device_id),
            "movement_mode": "walker",
            "battery_pct": 90,
        },
        token,
    )


class TestStatusUpdateRoute:
    async def test_commander_can_pause_and_reopen(self, real_conn):
        commander_id = await _make_user(real_conn, "Sector Status Commander")
        event_id = await _make_event(real_conn, commander_id)
        sector_id = await _make_sector(real_conn, event_id)
        token, _ = issue_account_token(get_settings(), commander_id)
        headers = {"Authorization": f"Bearer {token}"}

        with TestClient(app) as client:
            r1 = client.patch(f"/sectors/{sector_id}", json={"status": "paused"}, headers=headers)
            assert r1.status_code == 200
            assert r1.json()["status"] == "paused"

            r2 = client.patch(f"/sectors/{sector_id}", json={"status": "open"}, headers=headers)
            assert r2.status_code == 200
            assert r2.json()["status"] == "open"

    async def test_stranger_is_forbidden(self, real_conn):
        commander_id = await _make_user(real_conn, "Sector Status Commander 2")
        event_id = await _make_event(real_conn, commander_id)
        sector_id = await _make_sector(real_conn, event_id)
        stranger_id = await _make_user(real_conn, "Sector Status Stranger")
        token, _ = issue_account_token(get_settings(), stranger_id)
        headers = {"Authorization": f"Bearer {token}"}

        with TestClient(app) as client:
            r = client.patch(f"/sectors/{sector_id}", json={"status": "paused"}, headers=headers)
            assert r.status_code == 403

    async def test_missing_bearer_token_is_rejected(self, real_conn):
        commander_id = await _make_user(real_conn, "Sector Status Commander 3")
        event_id = await _make_event(real_conn, commander_id)
        sector_id = await _make_sector(real_conn, event_id)

        with TestClient(app) as client:
            r = client.patch(f"/sectors/{sector_id}", json={"status": "paused"})
            assert r.status_code == 401

    async def test_closed_is_rejected_by_this_endpoint(self, real_conn):
        """'closed' is set by event teardown (close_all_for_event), not this
        recruitment toggle -- excluded from the schema entirely."""
        commander_id = await _make_user(real_conn, "Sector Status Commander 4")
        event_id = await _make_event(real_conn, commander_id)
        sector_id = await _make_sector(real_conn, event_id)
        token, _ = issue_account_token(get_settings(), commander_id)
        headers = {"Authorization": f"Bearer {token}"}

        with TestClient(app) as client:
            r = client.patch(f"/sectors/{sector_id}", json={"status": "closed"}, headers=headers)
            assert r.status_code == 422

    async def test_unknown_sector_is_404(self, real_conn):
        commander_id = await _make_user(real_conn, "Sector Status Commander 5")
        token, _ = issue_account_token(get_settings(), commander_id)
        headers = {"Authorization": f"Bearer {token}"}

        with TestClient(app) as client:
            r = client.patch(
                f"/sectors/{uuid.uuid4()}", json={"status": "paused"}, headers=headers
            )
            assert r.status_code == 404


class TestJoinGating:
    """Regression coverage for the actual reported bug: a freshly-created
    sector is always 'open' (no code path can make it otherwise at
    creation), so a rejected join always traces back to one of these two
    gates -- exercised individually so a future change can't silently
    reintroduce the "commander creates an event, nobody can join it" bug."""

    async def test_draft_event_blocks_join_even_with_an_open_sector(self, real_conn):
        commander_id = await _make_user(real_conn, "Join Gating Commander Draft")
        event_id = await _make_event(real_conn, commander_id, status="draft")
        sector_id = await _make_sector(real_conn, event_id)
        payload, token = await _join_payload(real_conn, sector_id)

        with TestClient(app) as client:
            r = client.post("/join", json=payload, headers={"Authorization": f"Bearer {token}"})
            assert r.status_code == 409
            assert "not currently accepting volunteers" in r.json()["error"]["message"]

    async def test_paused_sector_blocks_join_even_in_an_active_event(self, real_conn):
        commander_id = await _make_user(real_conn, "Join Gating Commander Paused")
        event_id = await _make_event(real_conn, commander_id, status="active")
        sector_id = await _make_sector(real_conn, event_id)
        await real_conn.execute("UPDATE sectors SET status = 'paused' WHERE id = $1", sector_id)
        payload, token = await _join_payload(real_conn, sector_id)

        with TestClient(app) as client:
            r = client.post("/join", json=payload, headers={"Authorization": f"Bearer {token}"})
            assert r.status_code == 409
            assert "not currently accepting volunteers" in r.json()["error"]["message"]

    async def test_active_event_and_open_sector_allows_join(self, real_conn):
        commander_id = await _make_user(real_conn, "Join Gating Commander Active")
        event_id = await _make_event(real_conn, commander_id, status="active")
        sector_id = await _make_sector(real_conn, event_id)
        payload, token = await _join_payload(real_conn, sector_id)

        with TestClient(app) as client:
            r = client.post("/join", json=payload, headers={"Authorization": f"Bearer {token}"})
            assert r.status_code == 201
            assert r.json()["status"] == "pending"

    async def test_pausing_via_the_new_endpoint_actually_blocks_a_subsequent_join(
        self, real_conn
    ):
        """End-to-end proof that the dashboard's new recruitment toggle has a
        real effect on join eligibility, not just on the stored status
        column in isolation."""
        commander_id = await _make_user(real_conn, "Join Gating Commander Toggle")
        event_id = await _make_event(real_conn, commander_id, status="active")
        sector_id = await _make_sector(real_conn, event_id)
        commander_token, _ = issue_account_token(get_settings(), commander_id)
        commander_headers = {"Authorization": f"Bearer {commander_token}"}

        with TestClient(app) as client:
            pause = client.patch(
                f"/sectors/{sector_id}", json={"status": "paused"}, headers=commander_headers
            )
            assert pause.status_code == 200

            payload, volunteer_token = await _join_payload(real_conn, sector_id)
            blocked = client.post(
                "/join", json=payload, headers={"Authorization": f"Bearer {volunteer_token}"}
            )
            assert blocked.status_code == 409

            reopen = client.patch(
                f"/sectors/{sector_id}", json={"status": "open"}, headers=commander_headers
            )
            assert reopen.status_code == 200

            payload2, volunteer_token2 = await _join_payload(real_conn, sector_id)
            allowed = client.post(
                "/join", json=payload2, headers={"Authorization": f"Bearer {volunteer_token2}"}
            )
            assert allowed.status_code == 201
