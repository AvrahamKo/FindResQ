"""Reports at the HTTP route layer: auth boundaries (session token to
submit, account token + sector visibility to list, account token +
Lead/Commander to acknowledge), and the realtime broadcast proof -- same
`TestClient`-on-a-real-app pattern as `test_ws_dashboard.py`/
`test_sos_routes.py`, for the same reasons documented there.
"""

from __future__ import annotations

import base64
import uuid
from datetime import datetime, timedelta, timezone

import asyncpg
import pytest
from fastapi.testclient import TestClient
from nacl.signing import SigningKey

from app.config import get_settings
from app.main import app
from app.mesh import report_format
from app.repositories import memberships as memberships_repo
from app.repositories import sector_keys as sector_keys_repo
from app.repositories import sectors as sectors_repo
from app.security import envelope, mesh_crypto
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
        f"+1555{uuid.uuid4().int % 10_000_000:07d}",
        name,
    )


async def _make_device(conn, user_id: uuid.UUID) -> tuple[uuid.UUID, int, SigningKey]:
    signing_key = SigningKey.generate()
    device_id = await conn.fetchval(
        """
        INSERT INTO devices (user_id, ed25519_public_key, platform, mesh_capable)
        VALUES ($1, $2, 'android', true)
        RETURNING id
        """,
        user_id,
        bytes(signing_key.verify_key),
    )
    wire_id = await conn.fetchval("SELECT wire_id FROM devices WHERE id = $1", device_id)
    return device_id, wire_id, signing_key


async def _make_event(conn, commander_id: uuid.UUID) -> uuid.UUID:
    return await conn.fetchval(
        "INSERT INTO events (name, commander_id, status) VALUES ($1, $2, 'active') RETURNING id",
        "Reports Test Event",
        commander_id,
    )


async def _make_sector(conn, event_id: uuid.UUID):
    sector_id = await conn.fetchval(
        """
        INSERT INTO sectors (event_id, name, boundary)
        VALUES ($1, 'Reports Test Sector', ST_SetSRID(ST_GeomFromGeoJSON($2::json), 4326)::geography)
        RETURNING id
        """,
        event_id,
        SECTOR_BOUNDARY_GEOJSON,
    )
    sector = await sectors_repo.get(conn, sector_id)
    # Reports are encrypted with the sector key (unlike SOS) -- unlike
    # `sectors_repo.create()` (used by the real `POST /events/{id}/sectors`
    # route, which wraps+inserts a key in the same transaction), this raw
    # INSERT above doesn't, so it has to happen here too.
    settings = get_settings()
    raw_key = envelope.generate_sector_key()
    wrapped = envelope.wrap(settings.sector_key_wrap_secret, raw_key)
    await sector_keys_repo.insert(conn, sector.id, sector.key_epoch, wrapped)
    return sector


async def _make_session(conn, *, sector, user_id: uuid.UUID, device_id: uuid.UUID) -> str:
    settings = get_settings()
    membership = await memberships_repo.create_pending(
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


def _encrypted_report_blob(
    sector_key: bytes, signing_key: SigningKey, wire_id: int, *, kind: str = "hazard",
    note: str = "Test report", lat: float = 31.7715, lng: float = 35.2170,
) -> str:
    payload = report_format.ReportPayload(
        wire_id=wire_id,
        recorded_at_ms=int(datetime.now(timezone.utc).timestamp() * 1000),
        kind=kind,
        lat=lat,
        lng=lng,
        note=note,
    )
    packed = report_format.pack(payload)
    signature = signing_key.sign(packed).signature
    blob = mesh_crypto.encrypt(sector_key, packed + signature)
    return base64.b64encode(blob).decode("ascii")


async def _sector_key_for(conn, sector) -> bytes:
    settings = get_settings()
    row = await sector_keys_repo.get(conn, sector.id, sector.key_epoch)
    return envelope.unwrap(settings.sector_key_wrap_secret, row.key_wrapped)


class TestSubmitAuth:
    async def test_missing_bearer_token_is_rejected(self, real_conn):
        with TestClient(app) as client:
            r = client.post("/reports", json={"blobs": []})
            assert r.status_code == 401


class TestSubmitAndVisibility:
    async def test_a_valid_report_is_accepted_and_visible_to_the_reporter(self, real_conn):
        commander_id = await _make_user(real_conn, "Reports Commander")
        event_id = await _make_event(real_conn, commander_id)
        sector = await _make_sector(real_conn, event_id)
        searcher_id = await _make_user(real_conn, "Reports Searcher")
        device_id, wire_id, signing_key = await _make_device(real_conn, searcher_id)
        session_token = await _make_session(
            real_conn, sector=sector, user_id=searcher_id, device_id=device_id
        )
        sector_key = await _sector_key_for(real_conn, sector)

        try:
            with TestClient(app) as client:
                blob = _encrypted_report_blob(
                    sector_key, signing_key, wire_id, kind="subject_found",
                    note="Spotted near the ridge.",
                )
                r = client.post(
                    "/reports",
                    json={"blobs": [blob]},
                    headers={"Authorization": f"Bearer {session_token}"},
                )
                assert r.status_code == 200
                assert r.json()["accepted"] == 1

                account_token, _ = issue_account_token(get_settings(), searcher_id)
                listed = client.get(
                    f"/sectors/{sector.id}/reports",
                    headers={"Authorization": f"Bearer {account_token}"},
                )
                assert listed.status_code == 200
                reports = listed.json()
                assert len(reports) == 1
                assert reports[0]["kind"] == "subject_found"
                assert reports[0]["note"] == "Spotted near the ridge."
                assert reports[0]["status"] == "open"
        finally:
            await real_conn.execute("DELETE FROM events WHERE id = $1", event_id)
            await real_conn.execute(
                "DELETE FROM users WHERE id = ANY($1::uuid[])", [commander_id, searcher_id]
            )

    async def test_an_outsider_cannot_list_the_sector_reports(self, real_conn):
        commander_id = await _make_user(real_conn, "Reports Commander2")
        event_id = await _make_event(real_conn, commander_id)
        sector = await _make_sector(real_conn, event_id)
        searcher_id = await _make_user(real_conn, "Reports Searcher2")
        device_id, wire_id, signing_key = await _make_device(real_conn, searcher_id)
        session_token = await _make_session(
            real_conn, sector=sector, user_id=searcher_id, device_id=device_id
        )
        sector_key = await _sector_key_for(real_conn, sector)
        outsider_id = await _make_user(real_conn, "Reports Outsider")

        try:
            with TestClient(app) as client:
                blob = _encrypted_report_blob(sector_key, signing_key, wire_id)
                client.post(
                    "/reports",
                    json={"blobs": [blob]},
                    headers={"Authorization": f"Bearer {session_token}"},
                )

                outsider_token, _ = issue_account_token(get_settings(), outsider_id)
                r = client.get(
                    f"/sectors/{sector.id}/reports",
                    headers={"Authorization": f"Bearer {outsider_token}"},
                )
                assert r.status_code == 403
        finally:
            await real_conn.execute("DELETE FROM events WHERE id = $1", event_id)
            await real_conn.execute(
                "DELETE FROM users WHERE id = ANY($1::uuid[])",
                [commander_id, searcher_id, outsider_id],
            )


class TestAcknowledge:
    async def test_only_lead_or_commander_can_acknowledge(self, real_conn):
        commander_id = await _make_user(real_conn, "Reports Commander3")
        event_id = await _make_event(real_conn, commander_id)
        sector = await _make_sector(real_conn, event_id)
        searcher_id = await _make_user(real_conn, "Reports Searcher3")
        device_id, wire_id, signing_key = await _make_device(real_conn, searcher_id)
        session_token = await _make_session(
            real_conn, sector=sector, user_id=searcher_id, device_id=device_id
        )
        sector_key = await _sector_key_for(real_conn, sector)

        try:
            with TestClient(app) as client:
                blob = _encrypted_report_blob(sector_key, signing_key, wire_id)
                client.post(
                    "/reports",
                    json={"blobs": [blob]},
                    headers={"Authorization": f"Bearer {session_token}"},
                )
                account_token, _ = issue_account_token(get_settings(), searcher_id)
                reports = client.get(
                    f"/sectors/{sector.id}/reports",
                    headers={"Authorization": f"Bearer {account_token}"},
                ).json()
                report_id = reports[0]["id"]

                # The reporter themselves is not staff -- forbidden.
                forbidden = client.post(
                    f"/reports/{report_id}/acknowledge",
                    headers={"Authorization": f"Bearer {account_token}"},
                )
                assert forbidden.status_code == 403

                commander_token, _ = issue_account_token(get_settings(), commander_id)
                ok = client.post(
                    f"/reports/{report_id}/acknowledge",
                    headers={"Authorization": f"Bearer {commander_token}"},
                )
                assert ok.status_code == 200
                assert ok.json()["status"] == "acknowledged"
                assert ok.json()["acknowledged_by"] == str(commander_id)
        finally:
            await real_conn.execute("DELETE FROM events WHERE id = $1", event_id)
            await real_conn.execute(
                "DELETE FROM users WHERE id = ANY($1::uuid[])", [commander_id, searcher_id]
            )


class TestRealtimeBroadcast:
    async def test_submitting_a_report_broadcasts_report_delta(self, real_conn):
        commander_id = await _make_user(real_conn, "Reports Broadcast Commander")
        event_id = await _make_event(real_conn, commander_id)
        sector = await _make_sector(real_conn, event_id)
        searcher_id = await _make_user(real_conn, "Reports Broadcast Searcher")
        device_id, wire_id, signing_key = await _make_device(real_conn, searcher_id)
        session_token = await _make_session(
            real_conn, sector=sector, user_id=searcher_id, device_id=device_id
        )
        sector_key = await _sector_key_for(real_conn, sector)
        commander_token, _ = issue_account_token(get_settings(), commander_id)

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

                    blob = _encrypted_report_blob(
                        sector_key, signing_key, wire_id, kind="hazard",
                        note="Broadcast test hazard.",
                    )
                    r = client.post(
                        "/reports",
                        json={"blobs": [blob]},
                        headers={"Authorization": f"Bearer {session_token}"},
                    )
                    assert r.status_code == 200
                    assert r.json()["accepted"] == 1

                    message = ws.receive_json()
                    assert message["type"] == "report_delta"
                    assert message["sector_id"] == str(sector.id)
                    assert len(message["reports"]) == 1
                    assert message["reports"][0]["kind"] == "hazard"
                    assert message["reports"][0]["note"] == "Broadcast test hazard."
        finally:
            await real_conn.execute("DELETE FROM events WHERE id = $1", event_id)
            await real_conn.execute(
                "DELETE FROM users WHERE id = ANY($1::uuid[])", [commander_id, searcher_id]
            )
