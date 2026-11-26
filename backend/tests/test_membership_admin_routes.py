"""Leadership membership controls used by the Commander dashboard.

These tests cover the human/operator-facing contract rather than only the
row transitions: managers must be able to identify a person, recover active
join codes after a page refresh, and correct walker/vehicle mode without
mixing two coverage assumptions in one track segment.
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

BOUNDARY = (
    '{"type":"Polygon","coordinates":[[[35.20,31.70],[35.20,31.72],'
    '[35.23,31.72],[35.23,31.70],[35.20,31.70]]]}'
)


@pytest.fixture
async def scenario():
    try:
        conn = await asyncpg.connect(DATABASE_URL, timeout=5)
    except (OSError, asyncpg.PostgresError):
        pytest.skip(f"no database reachable at {DATABASE_URL}")

    users: list[uuid.UUID] = []
    events: list[uuid.UUID] = []
    try:
        yield conn, users, events
    finally:
        if events:
            await conn.execute("DELETE FROM events WHERE id = ANY($1::uuid[])", events)
        if users:
            await conn.execute("DELETE FROM devices WHERE user_id = ANY($1::uuid[])", users)
            await conn.execute("DELETE FROM users WHERE id = ANY($1::uuid[])", users)
        await conn.close()


async def _user(conn, users, name: str) -> tuple[uuid.UUID, str]:
    phone = f"+1555{uuid.uuid4().int % 10_000_000_000:010d}"
    user_id = await conn.fetchval(
        "INSERT INTO users (phone_e164, display_name) VALUES ($1, $2) RETURNING id",
        phone,
        name,
    )
    users.append(user_id)
    return user_id, phone


async def _event_and_sector(conn, events, commander_id: uuid.UUID) -> tuple[uuid.UUID, uuid.UUID]:
    event_id = await conn.fetchval(
        "INSERT INTO events (name, commander_id, status) "
        "VALUES ('Admin Route Test', $1, 'active') RETURNING id",
        commander_id,
    )
    events.append(event_id)
    sector_id = await conn.fetchval(
        """
        INSERT INTO sectors (event_id, name, boundary)
        VALUES ($1, 'Admin Sector',
                ST_SetSRID(ST_GeomFromGeoJSON($2::json), 4326)::geography)
        RETURNING id
        """,
        event_id,
        BOUNDARY,
    )
    return event_id, sector_id


async def _device(conn, user_id: uuid.UUID) -> uuid.UUID:
    return await conn.fetchval(
        """
        INSERT INTO devices (user_id, ed25519_public_key, platform)
        VALUES ($1, $2, 'android') RETURNING id
        """,
        user_id,
        bytes(SigningKey.generate().verify_key),
    )


async def _membership(
    conn,
    *,
    sector_id: uuid.UUID,
    user_id: uuid.UUID,
    device_id: uuid.UUID,
    status: str = "approved",
) -> uuid.UUID:
    return await conn.fetchval(
        """
        INSERT INTO sector_memberships
            (sector_id, user_id, device_id, role, movement_mode, status,
             session_expires_at)
        VALUES ($1, $2, $3, 'volunteer', 'walker', $4,
                CASE WHEN $4 = 'approved' THEN now() + interval '8 hours' END)
        RETURNING id
        """,
        sector_id,
        user_id,
        device_id,
        status,
    )


def _headers(user_id: uuid.UUID) -> dict[str, str]:
    token, _ = issue_account_token(get_settings(), user_id)
    return {"Authorization": f"Bearer {token}"}


class TestMembershipRoster:
    async def test_list_includes_human_identity(self, scenario):
        conn, users, events = scenario
        commander_id, _ = await _user(conn, users, "Commander")
        _, sector_id = await _event_and_sector(conn, events, commander_id)
        searcher_id, phone = await _user(conn, users, "Dana Searcher")
        device_id = await _device(conn, searcher_id)
        membership_id = await _membership(
            conn,
            sector_id=sector_id,
            user_id=searcher_id,
            device_id=device_id,
        )

        with TestClient(app) as client:
            response = client.get(
                f"/sectors/{sector_id}/memberships", headers=_headers(commander_id)
            )

        assert response.status_code == 200, response.text
        member = next(row for row in response.json() if row["id"] == str(membership_id))
        assert member["display_name"] == "Dana Searcher"
        assert member["phone_e164"] == phone


class TestJoinCodeListing:
    async def test_only_redeemable_codes_are_returned(self, scenario):
        conn, users, events = scenario
        commander_id, _ = await _user(conn, users, "Code Commander")
        _, sector_id = await _event_and_sector(conn, events, commander_id)
        active = await join_codes_repo.create(
            conn,
            sector_id=sector_id,
            created_by=commander_id,
            ttl_seconds=3600,
            max_uses=None,
        )
        expired = await join_codes_repo.create(
            conn,
            sector_id=sector_id,
            created_by=commander_id,
            ttl_seconds=3600,
            max_uses=None,
        )
        revoked = await join_codes_repo.create(
            conn,
            sector_id=sector_id,
            created_by=commander_id,
            ttl_seconds=3600,
            max_uses=None,
        )
        exhausted = await join_codes_repo.create(
            conn,
            sector_id=sector_id,
            created_by=commander_id,
            ttl_seconds=3600,
            max_uses=1,
        )
        await conn.execute(
            "UPDATE join_codes SET expires_at = now() - interval '1 minute' "
            "WHERE code = $1",
            expired.code,
        )
        await conn.execute(
            "UPDATE join_codes SET revoked_at = now() WHERE code = $1",
            revoked.code,
        )
        await conn.execute(
            "UPDATE join_codes SET uses = max_uses WHERE code = $1",
            exhausted.code,
        )

        expiry_state = await conn.fetchrow(
            "SELECT expires_at, now() AS db_now, expires_at > now() AS active "
            "FROM join_codes WHERE code = $1",
            expired.code,
        )
        assert not expiry_state["active"], dict(expiry_state)
        direct = {code.code for code in await join_codes_repo.list_active(conn, sector_id)}
        assert expired.code not in direct

        with TestClient(app) as client:
            response = client.get(
                f"/sectors/{sector_id}/join-codes", headers=_headers(commander_id)
            )

        assert response.status_code == 200, response.text
        returned = {row["code"] for row in response.json()}
        assert active.code in returned
        assert expired.code not in returned
        assert revoked.code not in returned
        assert exhausted.code not in returned


class TestMembershipEditing:
    async def test_mode_change_closes_the_old_track_segment(self, scenario):
        conn, users, events = scenario
        commander_id, _ = await _user(conn, users, "Edit Commander")
        _, sector_id = await _event_and_sector(conn, events, commander_id)
        searcher_id, _ = await _user(conn, users, "Mode Searcher")
        device_id = await _device(conn, searcher_id)
        membership_id = await _membership(
            conn,
            sector_id=sector_id,
            user_id=searcher_id,
            device_id=device_id,
        )
        segment_id = await conn.fetchval(
            """
            INSERT INTO track_segments
                (sector_id, device_id, user_id, movement_mode, started_at,
                 last_recorded_at, last_lat, last_lng, point_count)
            VALUES ($1, $2, $3, 'walker', now(), now(), 31.71, 35.21, 0)
            RETURNING id
            """,
            sector_id,
            device_id,
            searcher_id,
        )

        with TestClient(app) as client:
            response = client.patch(
                f"/memberships/{membership_id}",
                json={"movement_mode": "vehicle"},
                headers=_headers(commander_id),
            )

        assert response.status_code == 200, response.text
        assert response.json()["movement_mode"] == "vehicle"
        assert await conn.fetchval(
            "SELECT ended_at IS NOT NULL FROM track_segments WHERE id = $1", segment_id
        )

    async def test_stranger_cannot_edit_a_searcher(self, scenario):
        conn, users, events = scenario
        commander_id, _ = await _user(conn, users, "Protected Commander")
        _, sector_id = await _event_and_sector(conn, events, commander_id)
        searcher_id, _ = await _user(conn, users, "Protected Searcher")
        stranger_id, _ = await _user(conn, users, "Stranger")
        membership_id = await _membership(
            conn,
            sector_id=sector_id,
            user_id=searcher_id,
            device_id=await _device(conn, searcher_id),
        )

        with TestClient(app) as client:
            response = client.patch(
                f"/memberships/{membership_id}",
                json={"movement_mode": "vehicle"},
                headers=_headers(stranger_id),
            )

        assert response.status_code == 403
        assert await conn.fetchval(
            "SELECT movement_mode FROM sector_memberships WHERE id = $1", membership_id
        ) == "walker"
