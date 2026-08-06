"""End-to-end realtime behaviour of the Phase 7 removals, with nothing
mocked: a committed DELETE (or revocation) fires its trigger from migration
0008 -> NOTIFY -> the app's realtime listener -> a message on, or the close
of, a live WebSocket.

This is the half of "cascade delete" and "session invalidation" that the
repository tests structurally cannot reach. `test_moderation_db.py` proves
the rows are gone and the access is withdrawn; this proves the connections
that were ALREADY OPEN find out, which is the difference between access
ending on someone's next request and access ending now.

Same harness constraints as test_ws_dashboard.py, for the same reasons:
TestClient runs the app (and its lifespan) on its own event loop, fixture
data is created over an independent connection, and nothing here can use the
rollback-only `db_conn` fixture -- Postgres delivers a NOTIFY only when the
issuing transaction COMMITS.
"""

from __future__ import annotations

import uuid

import asyncpg
import pytest
from fastapi.testclient import TestClient
from starlette.websockets import WebSocketDisconnect

from app.config import get_settings
from app.main import app
from app.realtime.manager import CLOSE_ACCESS_REVOKED, CLOSE_EVENT_DELETED
from app.repositories import sos as sos_repo
from app.security.tokens import issue_account_token
from tests.conftest import DATABASE_URL
from tests.test_ingest_pipeline_db import _make_device, _make_user

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
        "INSERT INTO events (name, commander_id, status) VALUES ($1, $2, 'active') "
        "RETURNING id",
        "WS Moderation Event",
        commander_id,
    )


async def _make_sector(conn, event_id: uuid.UUID) -> uuid.UUID:
    return await conn.fetchval(
        """
        INSERT INTO sectors (event_id, name, boundary)
        VALUES ($1, 'WS Moderation Sector',
                ST_SetSRID(ST_GeomFromGeoJSON($2::json), 4326)::geography)
        RETURNING id
        """,
        event_id,
        SECTOR_BOUNDARY_GEOJSON,
    )


def _connect(client: TestClient, event_id: uuid.UUID, token: str):
    """Mint a ticket and open a socket, consuming the handshake."""
    response = client.post(
        f"/events/{event_id}/ws-ticket",
        headers={"Authorization": f"Bearer {token}"},
    )
    assert response.status_code == 201, response.text
    ticket = response.json()["ticket"]
    return client.websocket_connect(f"/ws/events/{event_id}?ticket={ticket}")


def _await_message(ws, wanted_type: str) -> dict:
    """Reads until a message of `wanted_type` arrives, skipping unrelated
    deltas -- a live sector can emit presence/coverage traffic at any moment,
    so the wanted message is not necessarily the next one on the wire.

    Bounded by message count so a regression surfaces as a clear assertion
    rather than a hung suite.
    """
    for _ in range(20):
        message = ws.receive_json()
        if message.get("type") == wanted_type:
            return message
    raise AssertionError(f"never received a {wanted_type!r} message")


class TestAlertDeletionBroadcast:
    async def test_deleting_an_alert_reaches_a_connected_dashboard(
        self, real_conn
    ) -> None:
        """The message a delta query can never carry. Every other realtime
        update is "re-read what changed"; a deleted row cannot be re-read,
        so the id has to be pushed."""
        settings = get_settings()
        commander_id = await _make_user(real_conn, "Alert Delete Commander")
        event_id = await _make_event(real_conn, commander_id)
        sector_id = await _make_sector(real_conn, event_id)
        volunteer_id = await _make_user(real_conn, "Alert Delete Volunteer")
        device_id, _wire, _key = await _make_device(real_conn, volunteer_id)
        token, _ = issue_account_token(settings, commander_id)

        alert = await sos_repo.trigger(
            real_conn,
            sector_id=sector_id,
            device_id=device_id,
            user_id=volunteer_id,
            lat=31.77,
            lng=35.22,
        )
        await sos_repo.resolve(real_conn, alert.id, by_user_id=commander_id)

        try:
            with TestClient(app) as client:
                with _connect(client, event_id, token) as ws:
                    assert ws.receive_json()["type"] == "connected"

                    response = client.delete(
                        f"/sos/{alert.id}",
                        headers={"Authorization": f"Bearer {token}"},
                    )
                    assert response.status_code == 200, response.text
                    assert response.json()["deleted_ids"] == [str(alert.id)]

                    message = _await_message(ws, "sos_deleted")
                    assert message["alert_id"] == str(alert.id)
                    assert message["sector_id"] == str(sector_id)
        finally:
            await real_conn.execute("DELETE FROM events WHERE id = $1", event_id)
            await real_conn.execute(
                "DELETE FROM users WHERE id = ANY($1::uuid[])",
                [commander_id, volunteer_id],
            )

    async def test_an_open_alert_cannot_be_deleted(self, real_conn) -> None:
        """Deletion must never be the shortcut for silencing a live alarm."""
        settings = get_settings()
        commander_id = await _make_user(real_conn, "Open Alert Commander")
        event_id = await _make_event(real_conn, commander_id)
        sector_id = await _make_sector(real_conn, event_id)
        volunteer_id = await _make_user(real_conn, "Open Alert Volunteer")
        device_id, _wire, _key = await _make_device(real_conn, volunteer_id)
        token, _ = issue_account_token(settings, commander_id)

        alert = await sos_repo.trigger(
            real_conn,
            sector_id=sector_id,
            device_id=device_id,
            user_id=volunteer_id,
            lat=31.77,
            lng=35.22,
        )

        try:
            with TestClient(app) as client:
                response = client.delete(
                    f"/sos/{alert.id}",
                    headers={"Authorization": f"Bearer {token}"},
                )
                assert response.status_code == 409, response.text
            assert await sos_repo.get(real_conn, alert.id) is not None
        finally:
            await real_conn.execute("DELETE FROM events WHERE id = $1", event_id)
            await real_conn.execute(
                "DELETE FROM users WHERE id = ANY($1::uuid[])",
                [commander_id, volunteer_id],
            )

    async def test_a_field_volunteer_cannot_acknowledge_or_delete(
        self, real_conn
    ) -> None:
        """RBAC on the alert actions, at the API boundary."""
        settings = get_settings()
        commander_id = await _make_user(real_conn, "RBAC Commander")
        event_id = await _make_event(real_conn, commander_id)
        sector_id = await _make_sector(real_conn, event_id)
        volunteer_id = await _make_user(real_conn, "RBAC Volunteer")
        device_id, _wire, _key = await _make_device(real_conn, volunteer_id)
        # An APPROVED member of the sector -- not an outsider. The point is
        # that belonging to the sector is not enough to moderate its alerts.
        await real_conn.execute(
            """
            INSERT INTO sector_memberships (
                sector_id, user_id, device_id, role, status, approved_at,
                session_expires_at
            )
            VALUES ($1, $2, $3, 'volunteer', 'approved', now(),
                    now() + interval '8 hours')
            """,
            sector_id,
            volunteer_id,
            device_id,
        )
        volunteer_token, _ = issue_account_token(settings, volunteer_id)

        alert = await sos_repo.trigger(
            real_conn,
            sector_id=sector_id,
            device_id=device_id,
            user_id=volunteer_id,
            lat=31.77,
            lng=35.22,
        )

        try:
            with TestClient(app) as client:
                headers = {"Authorization": f"Bearer {volunteer_token}"}

                assert client.post(
                    f"/sos/{alert.id}/acknowledge", headers=headers
                ).status_code == 403
                assert client.post(
                    f"/sos/{alert.id}/resolve", headers=headers
                ).status_code == 403
                assert client.delete(f"/sos/{alert.id}", headers=headers).status_code == 403

                # ...and the permissions endpoint tells them so up front,
                # which is what lets the app hide the controls.
                permissions = client.get(
                    f"/sectors/{sector_id}/permissions", headers=headers
                )
                assert permissions.status_code == 200, permissions.text
                body = permissions.json()
                assert body["role"] == "volunteer"
                assert body["can_acknowledge_alerts"] is False
                assert body["can_delete_alerts"] is False

            # The alert survived every attempt.
            still_there = await sos_repo.get(real_conn, alert.id)
            assert still_there is not None and still_there.status == "active"
        finally:
            await real_conn.execute("DELETE FROM events WHERE id = $1", event_id)
            await real_conn.execute(
                "DELETE FROM users WHERE id = ANY($1::uuid[])",
                [commander_id, volunteer_id],
            )

    async def test_the_sector_manager_can_acknowledge(self, real_conn) -> None:
        settings = get_settings()
        commander_id = await _make_user(real_conn, "Manager Test Commander")
        event_id = await _make_event(real_conn, commander_id)
        sector_id = await _make_sector(real_conn, event_id)
        lead_id = await _make_user(real_conn, "Sector Manager")
        device_id, _wire, _key = await _make_device(real_conn, lead_id)
        await real_conn.execute(
            "UPDATE sectors SET lead_user_id = $2 WHERE id = $1", sector_id, lead_id
        )
        lead_token, _ = issue_account_token(settings, lead_id)

        alert = await sos_repo.trigger(
            real_conn,
            sector_id=sector_id,
            device_id=device_id,
            user_id=lead_id,
            lat=31.77,
            lng=35.22,
        )

        try:
            with TestClient(app) as client:
                headers = {"Authorization": f"Bearer {lead_token}"}
                response = client.post(f"/sos/{alert.id}/acknowledge", headers=headers)
                assert response.status_code == 200, response.text
                assert response.json()["status"] == "acknowledged"

                permissions = client.get(
                    f"/sectors/{sector_id}/permissions", headers=headers
                ).json()
                assert permissions["role"] == "lead"
                assert permissions["is_sector_manager"] is True
                assert permissions["can_acknowledge_alerts"] is True
        finally:
            await real_conn.execute(
                "UPDATE sectors SET lead_user_id = NULL WHERE id = $1", sector_id
            )
            await real_conn.execute("DELETE FROM events WHERE id = $1", event_id)
            await real_conn.execute(
                "DELETE FROM users WHERE id = ANY($1::uuid[])", [commander_id, lead_id]
            )


class TestEventDeletionTeardown:
    async def test_deleting_an_event_closes_its_dashboard_sockets(
        self, real_conn
    ) -> None:
        """The in-memory half of the cascade. Without it the event's socket
        group outlives every row it described, for the life of the process."""
        settings = get_settings()
        commander_id = await _make_user(real_conn, "Teardown Commander")
        event_id = await _make_event(real_conn, commander_id)
        await _make_sector(real_conn, event_id)
        token, _ = issue_account_token(settings, commander_id)

        try:
            with TestClient(app) as client:
                with _connect(client, event_id, token) as ws:
                    assert ws.receive_json()["type"] == "connected"

                    response = client.delete(
                        f"/events/{event_id}",
                        headers={"Authorization": f"Bearer {token}"},
                    )
                    assert response.status_code == 200, response.text
                    assert response.json()["sectors_deleted"] == 1

                    # Told why, then hung up -- an unexplained drop is
                    # indistinguishable from a flaky field link.
                    assert _await_message(ws, "event_deleted")["event_id"] == str(event_id)
                    with pytest.raises(WebSocketDisconnect) as exc_info:
                        ws.receive_json()
                    assert exc_info.value.code == CLOSE_EVENT_DELETED

                # The connection manager forgot the event entirely.
                assert client.app.state.connection_manager.connection_count(event_id) == 0
        finally:
            await real_conn.execute("DELETE FROM events WHERE id = $1", event_id)
            await real_conn.execute("DELETE FROM users WHERE id = $1", commander_id)

    async def test_only_the_commander_can_delete_an_event(self, real_conn) -> None:
        settings = get_settings()
        commander_id = await _make_user(real_conn, "Owning Commander")
        event_id = await _make_event(real_conn, commander_id)
        sector_id = await _make_sector(real_conn, event_id)
        member_id = await _make_user(real_conn, "Ordinary Member")
        device_id, _wire, _key = await _make_device(real_conn, member_id)
        await real_conn.execute(
            """
            INSERT INTO sector_memberships (
                sector_id, user_id, device_id, role, status, approved_at,
                session_expires_at
            )
            VALUES ($1, $2, $3, 'volunteer', 'approved', now(),
                    now() + interval '8 hours')
            """,
            sector_id,
            member_id,
            device_id,
        )
        member_token, _ = issue_account_token(settings, member_id)

        try:
            with TestClient(app) as client:
                response = client.delete(
                    f"/events/{event_id}",
                    headers={"Authorization": f"Bearer {member_token}"},
                )
                assert response.status_code == 403, response.text
            assert await real_conn.fetchval(
                "SELECT count(*) FROM events WHERE id = $1", event_id
            ) == 1
        finally:
            await real_conn.execute("DELETE FROM events WHERE id = $1", event_id)
            await real_conn.execute(
                "DELETE FROM users WHERE id = ANY($1::uuid[])",
                [commander_id, member_id],
            )


class TestSessionInvalidation:
    async def test_removing_a_user_hangs_up_their_live_socket(self, real_conn) -> None:
        """Session invalidation, in the one place a token re-check cannot
        reach: a socket the server is already pushing to. After the
        handshake there are no further requests to authorize, so the only
        way to stop the stream is to close it."""
        settings = get_settings()
        commander_id = await _make_user(real_conn, "Revoking Commander")
        event_id = await _make_event(real_conn, commander_id)
        sector_id = await _make_sector(real_conn, event_id)
        member_id = await _make_user(real_conn, "Removed Member")
        device_id, _wire, _key = await _make_device(real_conn, member_id)
        await real_conn.execute(
            """
            INSERT INTO sector_memberships (
                sector_id, user_id, device_id, role, status, approved_at,
                session_expires_at
            )
            VALUES ($1, $2, $3, 'volunteer', 'approved', now(),
                    now() + interval '8 hours')
            """,
            sector_id,
            member_id,
            device_id,
        )
        commander_token, _ = issue_account_token(settings, commander_id)
        member_token, _ = issue_account_token(settings, member_id)

        try:
            with TestClient(app) as client:
                with _connect(client, event_id, member_token) as ws:
                    assert ws.receive_json()["type"] == "connected"

                    response = client.delete(
                        f"/events/{event_id}/members/{member_id}",
                        headers={"Authorization": f"Bearer {commander_token}"},
                    )
                    assert response.status_code == 200, response.text
                    assert response.json()["memberships_revoked"] == 1
                    assert response.json()["history_retained"] is True

                    assert _await_message(ws, "access_revoked")["event_id"] == str(event_id)
                    with pytest.raises(WebSocketDisconnect) as exc_info:
                        ws.receive_json()
                    assert exc_info.value.code == CLOSE_ACCESS_REVOKED

                # And they cannot simply reconnect: read access to the event
                # is gone too, so no new ticket can be minted.
                assert client.post(
                    f"/events/{event_id}/ws-ticket",
                    headers={"Authorization": f"Bearer {member_token}"},
                ).status_code == 403

                # Nor read any of the sector's data.
                assert client.get(
                    f"/sectors/{sector_id}/hexes",
                    headers={"Authorization": f"Bearer {member_token}"},
                ).status_code == 403
        finally:
            await real_conn.execute("DELETE FROM events WHERE id = $1", event_id)
            await real_conn.execute(
                "DELETE FROM users WHERE id = ANY($1::uuid[])",
                [commander_id, member_id],
            )

    async def test_the_commanders_own_socket_survives_a_revocation(
        self, real_conn
    ) -> None:
        """The disconnect must be aimed at one user, not sprayed at the
        event: removing a volunteer cannot knock the Commander off the map
        they are running the search from."""
        settings = get_settings()
        commander_id = await _make_user(real_conn, "Surviving Commander")
        event_id = await _make_event(real_conn, commander_id)
        sector_id = await _make_sector(real_conn, event_id)
        member_id = await _make_user(real_conn, "Other Removed Member")
        device_id, _wire, _key = await _make_device(real_conn, member_id)
        await real_conn.execute(
            """
            INSERT INTO sector_memberships (
                sector_id, user_id, device_id, role, status, approved_at,
                session_expires_at
            )
            VALUES ($1, $2, $3, 'volunteer', 'approved', now(),
                    now() + interval '8 hours')
            """,
            sector_id,
            member_id,
            device_id,
        )
        commander_token, _ = issue_account_token(settings, commander_id)

        try:
            with TestClient(app) as client:
                with _connect(client, event_id, commander_token) as ws:
                    assert ws.receive_json()["type"] == "connected"

                    response = client.delete(
                        f"/events/{event_id}/members/{member_id}",
                        headers={"Authorization": f"Bearer {commander_token}"},
                    )
                    assert response.status_code == 200, response.text

                    # Still connected and still talking.
                    ws.send_json({"type": "ping"})
                    assert _await_message(ws, "pong") == {"type": "pong"}
        finally:
            await real_conn.execute("DELETE FROM events WHERE id = $1", event_id)
            await real_conn.execute(
                "DELETE FROM users WHERE id = ANY($1::uuid[])",
                [commander_id, member_id],
            )

    async def test_a_commander_cannot_remove_themselves(self, real_conn) -> None:
        settings = get_settings()
        commander_id = await _make_user(real_conn, "Self Removing Commander")
        event_id = await _make_event(real_conn, commander_id)
        token, _ = issue_account_token(settings, commander_id)

        try:
            with TestClient(app) as client:
                response = client.delete(
                    f"/events/{event_id}/members/{commander_id}",
                    headers={"Authorization": f"Bearer {token}"},
                )
                assert response.status_code == 409, response.text
        finally:
            await real_conn.execute("DELETE FROM events WHERE id = $1", event_id)
            await real_conn.execute("DELETE FROM users WHERE id = $1", commander_id)
