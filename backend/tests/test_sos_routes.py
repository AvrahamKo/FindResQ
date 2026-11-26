"""SOS at the HTTP route layer: auth boundaries (session token for
trigger/cancel, account token + Lead/Commander role for list/acknowledge/
resolve), the full state-machine flow over real requests, and the realtime
broadcast proof -- same `TestClient`-on-a-real-app pattern as
`test_ws_dashboard.py`, for the same reasons documented there (the app's
`lifespan` needs a real Postgres, and fixture data goes through an
independent `asyncpg.connect()` rather than the app's own pool to avoid an
"attached to a different loop" conflict).
"""

from __future__ import annotations

import uuid
from datetime import datetime, timedelta, timezone

import asyncpg
import pytest
from fastapi.testclient import TestClient
from nacl.signing import SigningKey

from app.config import get_settings
from app.main import app
from app.repositories import memberships as memberships_repo
from app.repositories import sectors as sectors_repo
from app.security.tokens import issue_account_token, issue_session_token
from tests.conftest import DATABASE_URL

pytestmark = pytest.mark.asyncio

SECTOR_BOUNDARY_GEOJSON = (
    '{"type":"Polygon","coordinates":[[[35.20,31.76],[35.20,31.78],'
    '[35.24,31.78],[35.24,31.76],[35.20,31.76]]]}'
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


async def _make_event(conn, commander_id: uuid.UUID) -> uuid.UUID:
    return await conn.fetchval(
        "INSERT INTO events (name, commander_id, status) VALUES ($1, $2, 'active') RETURNING id",
        "SOS Test Event",
        commander_id,
    )


async def _make_sector(conn, event_id: uuid.UUID):
    sector_id = await conn.fetchval(
        """
        INSERT INTO sectors (event_id, name, boundary)
        VALUES ($1, 'SOS Test Sector', ST_SetSRID(ST_GeomFromGeoJSON($2::json), 4326)::geography)
        RETURNING id
        """,
        event_id,
        SECTOR_BOUNDARY_GEOJSON,
    )
    return await sectors_repo.get(conn, sector_id)


async def _make_session(conn, *, sector, user_id: uuid.UUID, device_id: uuid.UUID) -> str:
    """Builds a real, valid session token by replicating exactly what
    `POST /join` -> approve -> `POST /memberships/{id}/session` does over
    HTTP, so `CurrentSession`'s live re-validation (membership approved,
    unexpired, sector key_epoch matching) is satisfied for real -- not a
    hand-waved fake JWT."""
    settings = get_settings()
    membership = await memberships_repo.create_or_reopen_pending(
        conn,
        sector_id=sector.id,
        user_id=user_id,
        device_id=device_id,
        movement_mode="walker",
        battery_at_join=90,
        powerbank_attested=False,
    )
    expires_at = datetime.now(timezone.utc) + timedelta(hours=8)
    approved = await memberships_repo.approve(
        conn,
        membership.id,
        approved_by=user_id,
        key_epoch=sector.key_epoch,
        session_expires_at=expires_at,
    )
    return issue_session_token(
        settings,
        user_id=user_id,
        device_id=device_id,
        sector_id=sector.id,
        membership_id=approved.id,
        role="volunteer",
        key_epoch=sector.key_epoch,
        movement_mode="walker",
        expires_at=expires_at,
    )


class TestTriggerAuth:
    async def test_missing_bearer_token_is_rejected(self, real_conn):
        with TestClient(app) as client:
            r = client.post("/sos", json={})
            assert r.status_code == 401

    async def test_an_account_token_is_not_a_valid_session_token(self, real_conn):
        settings = get_settings()
        user_id = await _make_user(real_conn, "SOS Route Solo User")
        account_token, _ = issue_account_token(settings, user_id)
        try:
            with TestClient(app) as client:
                r = client.post(
                    "/sos",
                    json={},
                    headers={"Authorization": f"Bearer {account_token}"},
                )
                assert r.status_code == 401
        finally:
            await real_conn.execute("DELETE FROM users WHERE id = $1", user_id)


class TestTriggerAndCancel:
    async def test_trigger_creates_an_active_alert_and_is_idempotent(self, real_conn):
        commander_id = await _make_user(real_conn, "SOS Route Commander")
        event_id = await _make_event(real_conn, commander_id)
        sector = await _make_sector(real_conn, event_id)
        searcher_id = await _make_user(real_conn, "SOS Route Searcher")
        device_id = await _make_device(real_conn, searcher_id)
        token = await _make_session(
            real_conn, sector=sector, user_id=searcher_id, device_id=device_id
        )

        try:
            with TestClient(app) as client:
                headers = {"Authorization": f"Bearer {token}"}

                r1 = client.post("/sos", json={"lat": 31.7715, "lng": 35.2170}, headers=headers)
                assert r1.status_code == 201
                body1 = r1.json()
                assert body1["status"] == "active"
                assert body1["sector_id"] == str(sector.id)
                assert body1["lat"] == pytest.approx(31.7715, abs=1e-6)

                r2 = client.post("/sos", json={"lat": 99.0, "lng": 99.0}, headers=headers)
                assert r2.status_code == 201
                body2 = r2.json()
                assert body2["id"] == body1["id"], "a second trigger must be idempotent"
        finally:
            await real_conn.execute("DELETE FROM events WHERE id = $1", event_id)
            await real_conn.execute(
                "DELETE FROM users WHERE id = ANY($1::uuid[])", [commander_id, searcher_id]
            )

    async def test_trigger_with_no_location_falls_back_to_last_presence(self, real_conn):
        commander_id = await _make_user(real_conn, "SOS Route Commander2")
        event_id = await _make_event(real_conn, commander_id)
        sector = await _make_sector(real_conn, event_id)
        searcher_id = await _make_user(real_conn, "SOS Route Searcher2")
        device_id = await _make_device(real_conn, searcher_id)
        token = await _make_session(
            real_conn, sector=sector, user_id=searcher_id, device_id=device_id
        )
        await real_conn.execute(
            """
            INSERT INTO device_presence (
                sector_id, device_id, last_point_at, last_geom,
                last_battery_pct, last_delivery_path, presence_state,
                state_changed_at, updated_at
            )
            VALUES (
                $1, $2, now(),
                ST_SetSRID(ST_MakePoint(35.219, 31.773), 4326)::geography,
                55, 'direct', 'active', now(), now()
            )
            """,
            sector.id,
            device_id,
        )

        try:
            with TestClient(app) as client:
                r = client.post(
                    "/sos", json={}, headers={"Authorization": f"Bearer {token}"}
                )
                assert r.status_code == 201
                body = r.json()
                assert body["lat"] == pytest.approx(31.773, abs=1e-3)
                assert body["lng"] == pytest.approx(35.219, abs=1e-3)
        finally:
            await real_conn.execute("DELETE FROM events WHERE id = $1", event_id)
            await real_conn.execute(
                "DELETE FROM users WHERE id = ANY($1::uuid[])", [commander_id, searcher_id]
            )

    async def test_only_the_triggering_device_can_cancel(self, real_conn):
        commander_id = await _make_user(real_conn, "SOS Route Commander3")
        event_id = await _make_event(real_conn, commander_id)
        sector = await _make_sector(real_conn, event_id)
        searcher_id = await _make_user(real_conn, "SOS Route Searcher3")
        device_id = await _make_device(real_conn, searcher_id)
        token = await _make_session(
            real_conn, sector=sector, user_id=searcher_id, device_id=device_id
        )

        other_id = await _make_user(real_conn, "SOS Route Other Searcher")
        other_device_id = await _make_device(real_conn, other_id)
        other_token = await _make_session(
            real_conn, sector=sector, user_id=other_id, device_id=other_device_id
        )

        try:
            with TestClient(app) as client:
                r = client.post(
                    "/sos",
                    json={"lat": 31.77, "lng": 35.21},
                    headers={"Authorization": f"Bearer {token}"},
                )
                alert_id = r.json()["id"]

                forbidden = client.post(
                    f"/sos/{alert_id}/cancel",
                    headers={"Authorization": f"Bearer {other_token}"},
                )
                assert forbidden.status_code == 403

                ok = client.post(
                    f"/sos/{alert_id}/cancel",
                    headers={"Authorization": f"Bearer {token}"},
                )
                assert ok.status_code == 200
                assert ok.json()["status"] == "cancelled"
        finally:
            await real_conn.execute("DELETE FROM events WHERE id = $1", event_id)
            await real_conn.execute(
                "DELETE FROM users WHERE id = ANY($1::uuid[])",
                [commander_id, searcher_id, other_id],
            )


class TestLeadCommanderActions:
    async def test_an_outsider_cannot_list_acknowledge_or_resolve(self, real_conn):
        commander_id = await _make_user(real_conn, "SOS Route Commander4")
        event_id = await _make_event(real_conn, commander_id)
        sector = await _make_sector(real_conn, event_id)
        searcher_id = await _make_user(real_conn, "SOS Route Searcher4")
        device_id = await _make_device(real_conn, searcher_id)
        token = await _make_session(
            real_conn, sector=sector, user_id=searcher_id, device_id=device_id
        )

        outsider_id = await _make_user(real_conn, "SOS Route Outsider")
        settings = get_settings()
        outsider_token, _ = issue_account_token(settings, outsider_id)

        try:
            with TestClient(app) as client:
                r = client.post(
                    "/sos",
                    json={"lat": 31.77, "lng": 35.21},
                    headers={"Authorization": f"Bearer {token}"},
                )
                alert_id = r.json()["id"]
                outsider_headers = {"Authorization": f"Bearer {outsider_token}"}

                assert client.get(
                    f"/sectors/{sector.id}/sos", headers=outsider_headers
                ).status_code == 403
                assert client.post(
                    f"/sos/{alert_id}/acknowledge", headers=outsider_headers
                ).status_code == 403
                assert client.post(
                    f"/sos/{alert_id}/resolve", headers=outsider_headers
                ).status_code == 403
        finally:
            await real_conn.execute("DELETE FROM events WHERE id = $1", event_id)
            await real_conn.execute(
                "DELETE FROM users WHERE id = ANY($1::uuid[])",
                [commander_id, searcher_id, outsider_id],
            )

    async def test_lead_can_list_acknowledge_and_resolve(self, real_conn):
        commander_id = await _make_user(real_conn, "SOS Route Commander5")
        event_id = await _make_event(real_conn, commander_id)
        sector = await _make_sector(real_conn, event_id)
        lead_id = await _make_user(real_conn, "SOS Route Lead")
        await sectors_repo.set_lead(real_conn, sector.id, lead_id)
        searcher_id = await _make_user(real_conn, "SOS Route Searcher5")
        device_id = await _make_device(real_conn, searcher_id)
        token = await _make_session(
            real_conn, sector=sector, user_id=searcher_id, device_id=device_id
        )
        settings = get_settings()
        lead_token, _ = issue_account_token(settings, lead_id)

        try:
            with TestClient(app) as client:
                r = client.post(
                    "/sos",
                    json={"lat": 31.77, "lng": 35.21},
                    headers={"Authorization": f"Bearer {token}"},
                )
                alert_id = r.json()["id"]
                lead_headers = {"Authorization": f"Bearer {lead_token}"}

                listed = client.get(f"/sectors/{sector.id}/sos", headers=lead_headers)
                assert listed.status_code == 200
                assert len(listed.json()) == 1
                assert listed.json()[0]["id"] == alert_id

                acked = client.post(f"/sos/{alert_id}/acknowledge", headers=lead_headers)
                assert acked.status_code == 200
                assert acked.json()["status"] == "acknowledged"
                assert acked.json()["acknowledged_by"] == str(lead_id)

                resolved = client.post(f"/sos/{alert_id}/resolve", headers=lead_headers)
                assert resolved.status_code == 200
                assert resolved.json()["status"] == "resolved"
                assert resolved.json()["resolved_by"] == str(lead_id)
        finally:
            await real_conn.execute("DELETE FROM events WHERE id = $1", event_id)
            await real_conn.execute(
                "DELETE FROM users WHERE id = ANY($1::uuid[])",
                [commander_id, lead_id, searcher_id],
            )


class TestRealtimeBroadcast:
    async def test_triggering_sos_broadcasts_sos_delta_to_a_connected_client(self, real_conn):
        """The end-to-end proof: a real SOS trigger fires the `sos_alerts`
        trigger -> NOTIFY -> the realtime listener -> a broadcast to every
        WebSocket connected for that event. Nothing in this chain is mocked
        -- same shape as test_ws_dashboard.py's hex/presence broadcast test.
        """
        commander_id = await _make_user(real_conn, "SOS Broadcast Commander")
        event_id = await _make_event(real_conn, commander_id)
        sector = await _make_sector(real_conn, event_id)
        searcher_id = await _make_user(real_conn, "SOS Broadcast Searcher")
        device_id = await _make_device(real_conn, searcher_id)
        session_token = await _make_session(
            real_conn, sector=sector, user_id=searcher_id, device_id=device_id
        )
        settings = get_settings()
        commander_token, _ = issue_account_token(settings, commander_id)

        try:
            with TestClient(app) as client:
                ticket_response = client.post(
                    f"/events/{event_id}/ws-ticket",
                    headers={"Authorization": f"Bearer {commander_token}"},
                )
                ticket = ticket_response.json()["ticket"]

                with client.websocket_connect(
                    f"/ws/events/{event_id}?ticket={ticket}"
                ) as ws:
                    handshake = ws.receive_json()
                    assert handshake["type"] == "connected"

                    r = client.post(
                        "/sos",
                        json={"lat": 31.77, "lng": 35.21},
                        headers={"Authorization": f"Bearer {session_token}"},
                    )
                    assert r.status_code == 201
                    alert_id = r.json()["id"]

                    message = ws.receive_json()
                    assert message["type"] == "sos_delta"
                    assert message["sector_id"] == str(sector.id)
                    assert len(message["alerts"]) == 1
                    assert message["alerts"][0]["id"] == alert_id
                    assert message["alerts"][0]["status"] == "active"
        finally:
            await real_conn.execute("DELETE FROM events WHERE id = $1", event_id)
            await real_conn.execute(
                "DELETE FROM users WHERE id = ANY($1::uuid[])", [commander_id, searcher_id]
            )
