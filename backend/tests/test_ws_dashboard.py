"""Realtime dashboard transport: ticket issuance, WebSocket handshake, and
the end-to-end proof that a committed ingest actually reaches a connected
client via LISTEN/NOTIFY.

`TestClient` runs the ASGI app -- including its `lifespan`, which needs a
real Postgres to start up -- on its OWN internal event loop, separate from
the one this test coroutine runs on. Two consequences:

  * The whole file is skipped if no database is reachable (same convention
    as the rest of the DB-backed suite).
  * Test fixture data is created via an INDEPENDENT `asyncpg.connect()`, not
    the app's own connection pool -- reaching into `db.get_pool()` directly
    from this coroutine hit "attached to a different loop" in practice. A
    separate connection has no such conflict; it's just another client
    talking to the same database.

The realtime-broadcast test specifically cannot use the transaction-rollback
`db_conn` fixture used elsewhere in this suite: Postgres only delivers a
NOTIFY once the issuing transaction commits, so proving broadcast delivery
needs a transaction that actually commits. That test's data is cleaned up
explicitly via foreign-key cascades instead of a rollback.
"""

from __future__ import annotations

import uuid
from datetime import datetime, timezone

import asyncpg
import pytest
from fastapi.testclient import TestClient
from nacl import utils as nacl_utils
from starlette.websockets import WebSocketDisconnect

from app.config import get_settings
from app.ingest.pipeline import ingest_batch
from app.main import app
from app.repositories import sectors as sectors_repo
from app.security import mesh_crypto
from app.security.tokens import issue_account_token
from tests.conftest import DATABASE_URL
from tests.test_ingest_pipeline_db import _encrypted_point, _make_device, _make_user

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


async def _make_event(conn, commander_id: uuid.UUID) -> uuid.UUID:
    return await conn.fetchval(
        "INSERT INTO events (name, commander_id, status) VALUES ($1, $2, 'active') RETURNING id",
        "WS Test Event",
        commander_id,
    )


class TestTicketRejection:
    async def test_missing_ticket_is_rejected(self, real_conn) -> None:
        with TestClient(app) as client:
            with client.websocket_connect(f"/ws/events/{uuid.uuid4()}") as ws:
                with pytest.raises(WebSocketDisconnect) as exc_info:
                    ws.receive_json()
                assert exc_info.value.code == 4401

    async def test_garbage_ticket_is_rejected(self, real_conn) -> None:
        with TestClient(app) as client:
            url = f"/ws/events/{uuid.uuid4()}?ticket=not-a-real-ticket"
            with client.websocket_connect(url) as ws:
                with pytest.raises(WebSocketDisconnect) as exc_info:
                    ws.receive_json()
                assert exc_info.value.code == 4401


class TestTicketIssueAndConnect:
    async def test_valid_ticket_connects_and_receives_handshake(self, real_conn) -> None:
        settings = get_settings()
        user_id = await _make_user(real_conn, "WS Commander")
        event_id = await _make_event(real_conn, user_id)
        token, _ = issue_account_token(settings, user_id)

        try:
            with TestClient(app) as client:
                r = client.post(
                    f"/events/{event_id}/ws-ticket",
                    headers={"Authorization": f"Bearer {token}"},
                )
                assert r.status_code == 201
                ticket = r.json()["ticket"]

                with client.websocket_connect(f"/ws/events/{event_id}?ticket={ticket}") as ws:
                    handshake = ws.receive_json()
                    assert handshake == {"type": "connected", "event_id": str(event_id)}

                    ws.send_json({"type": "ping"})
                    assert ws.receive_json() == {"type": "pong"}
        finally:
            await real_conn.execute("DELETE FROM events WHERE id = $1", event_id)
            await real_conn.execute("DELETE FROM users WHERE id = $1", user_id)

    async def test_ticket_cannot_be_reused_for_a_second_connection(self, real_conn) -> None:
        settings = get_settings()
        user_id = await _make_user(real_conn, "WS Commander Reuse")
        event_id = await _make_event(real_conn, user_id)
        token, _ = issue_account_token(settings, user_id)

        try:
            with TestClient(app) as client:
                r = client.post(
                    f"/events/{event_id}/ws-ticket",
                    headers={"Authorization": f"Bearer {token}"},
                )
                ticket = r.json()["ticket"]

                with client.websocket_connect(f"/ws/events/{event_id}?ticket={ticket}") as ws:
                    ws.receive_json()  # consume the handshake

                with client.websocket_connect(
                    f"/ws/events/{event_id}?ticket={ticket}"
                ) as second:
                    with pytest.raises(WebSocketDisconnect) as exc_info:
                        second.receive_json()
                    assert exc_info.value.code == 4401
        finally:
            await real_conn.execute("DELETE FROM events WHERE id = $1", event_id)
            await real_conn.execute("DELETE FROM users WHERE id = $1", user_id)

    async def test_user_with_no_role_in_event_cannot_get_a_ticket(self, real_conn) -> None:
        settings = get_settings()
        commander_id = await _make_user(real_conn, "Commander Only")
        event_id = await _make_event(real_conn, commander_id)
        outsider_id = await _make_user(real_conn, "Outsider")
        token, _ = issue_account_token(settings, outsider_id)

        try:
            with TestClient(app) as client:
                r = client.post(
                    f"/events/{event_id}/ws-ticket",
                    headers={"Authorization": f"Bearer {token}"},
                )
                assert r.status_code == 403
        finally:
            await real_conn.execute("DELETE FROM events WHERE id = $1", event_id)
            await real_conn.execute("DELETE FROM users WHERE id = $1", commander_id)
            await real_conn.execute("DELETE FROM users WHERE id = $1", outsider_id)


class TestRealtimeBroadcast:
    async def test_committed_ingest_broadcasts_hex_delta_to_connected_client(
        self, real_conn
    ) -> None:
        """The end-to-end proof: a real ingest commit fires the
        `hex_coverage_state` trigger -> NOTIFY -> the app's realtime listener
        (a background task started in `lifespan`) -> a broadcast to every
        WebSocket connected for that event. Nothing in this chain is mocked."""
        settings = get_settings()
        commander_id = await _make_user(real_conn, "Broadcast Commander")
        event_id = await _make_event(real_conn, commander_id)
        sector_id = await real_conn.fetchval(
            """
            INSERT INTO sectors (event_id, name, boundary)
            VALUES ($1, 'WS Broadcast Sector',
                    ST_SetSRID(ST_GeomFromGeoJSON($2::json), 4326)::geography)
            RETURNING id
            """,
            event_id,
            SECTOR_BOUNDARY_GEOJSON,
        )
        sector = await sectors_repo.get(real_conn, sector_id)
        volunteer_id = await _make_user(real_conn, "Broadcast Volunteer")
        device_id, wire_id, signing_key = await _make_device(real_conn, volunteer_id)
        token, _ = issue_account_token(settings, commander_id)

        try:
            with TestClient(app) as client:
                r = client.post(
                    f"/events/{event_id}/ws-ticket",
                    headers={"Authorization": f"Bearer {token}"},
                )
                ticket = r.json()["ticket"]

                with client.websocket_connect(f"/ws/events/{event_id}?ticket={ticket}") as ws:
                    handshake = ws.receive_json()
                    assert handshake["type"] == "connected"

                    sector_key = nacl_utils.random(mesh_crypto.KEY_BYTES)
                    blob = _encrypted_point(
                        sector_key,
                        signing_key,
                        wire_id,
                        t_ms=int(datetime.now(timezone.utc).timestamp() * 1000),
                        lat=31.7700,
                        lng=35.2200,
                    )

                    async with real_conn.transaction():
                        result = await ingest_batch(
                            real_conn,
                            sector=sector,
                            device_id=device_id,
                            device_wire_id=wire_id,
                            device_public_key=bytes(signing_key.verify_key),
                            user_id=volunteer_id,
                            movement_mode="walker",
                            sector_key=sector_key,
                            blobs=[blob],
                        )
                    assert result.hexes_touched >= 1

                    # The same committed batch updates BOTH hex_coverage_state
                    # (via recalc) and device_presence (via upsert_active),
                    # each with its own NOTIFY trigger on a different channel
                    # -- so two independent messages arrive, in no guaranteed
                    # order relative to each other. Collect both.
                    messages = [ws.receive_json(), ws.receive_json()]
                    by_type = {m["type"]: m for m in messages}
                    assert set(by_type) == {"hex_delta", "presence_delta"}

                    hex_message = by_type["hex_delta"]
                    assert hex_message["sector_id"] == str(sector_id)
                    assert len(hex_message["hexes"]) >= 1
                    # Confirms schemas/coverage.py's hex_id-as-string safeguard
                    # survives the realtime path too, not just the REST one.
                    assert isinstance(hex_message["hexes"][0]["hex_id"], str)

                    presence_message = by_type["presence_delta"]
                    assert presence_message["sector_id"] == str(sector_id)
                    assert presence_message["devices"][0]["device_id"] == str(device_id)
                    assert presence_message["devices"][0]["presence_state"] == "active"
        finally:
            await real_conn.execute("DELETE FROM events WHERE id = $1", event_id)
            await real_conn.execute("DELETE FROM users WHERE id = $1", commander_id)
            await real_conn.execute("DELETE FROM users WHERE id = $1", volunteer_id)
