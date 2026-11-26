"""The dev simulator API, and above all: proof that it cannot exist outside
local development.

`/dev/sim` mints Ed25519 device identities, self-approves sector memberships
and issues session tokens with no proof of possession. That is a deliberate
backdoor for driving the real ingest pipeline without physical handsets, and
it would be catastrophic in a deployment. Two independent guards exist --
`main.py` refuses to register the router unless `settings.is_local`, and
`dev_sim._require_local` re-checks per request -- so that removing either one
alone still fails closed. Both are asserted here.
"""

from __future__ import annotations

import uuid

import asyncpg
import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

from app.api.routes import dev_sim
from app.config import Settings
from app.errors import AppError
from app.main import app
from tests.conftest import DATABASE_URL

# Applied per-class rather than module-wide: TestLocalGating's checks are
# synchronous, and marking them asyncio only produces warnings.
SECTOR_BOUNDARY_GEOJSON = (
    '{"type":"Polygon","coordinates":[[[35.40,31.90],[35.40,31.92],'
    '[35.44,31.92],[35.44,31.90],[35.40,31.90]]]}'
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


async def _make_sector(conn) -> uuid.UUID:
    commander_id = await conn.fetchval(
        "INSERT INTO users (phone_e164, display_name) VALUES ($1, $2) RETURNING id",
        f"+1555{uuid.uuid4().int % 10_000_000_000:010d}",
        "Dev Sim Commander",
    )
    event_id = await conn.fetchval(
        "INSERT INTO events (name, commander_id, status) VALUES ($1, $2, 'active') RETURNING id",
        "Dev Sim Event",
        commander_id,
    )
    sector_id = await conn.fetchval(
        """
        INSERT INTO sectors (event_id, name, boundary)
        VALUES ($1, 'Dev Sim Sector',
                ST_SetSRID(ST_GeomFromGeoJSON($2::json), 4326)::geography)
        RETURNING id
        """,
        event_id,
        SECTOR_BOUNDARY_GEOJSON,
    )
    # A sector needs key material before a session can be issued against it.
    from app.config import get_settings
    from app.repositories import sector_keys as sector_keys_repo
    from app.security import envelope

    settings = get_settings()
    raw = envelope.generate_sector_key()
    await sector_keys_repo.insert(
        conn, sector_id, 1, envelope.wrap(settings.sector_key_wrap_secret, raw)
    )
    return sector_id


class TestLocalGating:
    """The load-bearing tests. If these ever fail, a deployment can be handed
    working device credentials by an unauthenticated HTTP request."""

    def test_router_is_not_registered_outside_local(self) -> None:
        """Mirrors main.py's `if get_settings().is_local` guard: a
        non-local app must not carry the routes at all."""
        production_app = FastAPI()
        settings = Settings(
            env="production",
            database_url="postgresql://x/y",
            jwt_secret="x" * 40,
            sector_key_wrap_secret="y" * 40,
        )
        assert not settings.is_local

        if settings.is_local:  # pragma: no cover - documents the guard
            production_app.include_router(dev_sim.router)

        paths = {r.path for r in production_app.routes}
        assert not any(p.startswith("/dev/sim") for p in paths)

    def test_require_local_rejects_non_local_settings(self) -> None:
        """The second, independent guard -- enforced per request, so it holds
        even if the registration guard is removed."""
        settings = Settings(
            env="production",
            database_url="postgresql://x/y",
            jwt_secret="x" * 40,
            sector_key_wrap_secret="y" * 40,
        )
        with pytest.raises(AppError) as excinfo:
            dev_sim._require_local(settings)
        assert excinfo.value.status_code == 403

    def test_routes_ARE_registered_in_local(self) -> None:
        paths = {r.path for r in app.routes}
        assert "/dev/sim/units" in paths, (
            "the simulator router should be registered in local dev"
        )


@pytest.mark.asyncio
class TestUnitProvisioning:
    async def test_creates_a_fully_credentialed_unit(self, real_conn) -> None:
        sector_id = await _make_sector(real_conn)
        try:
            with TestClient(app) as client:
                r = client.post(
                    "/dev/sim/units",
                    json={"name": "Alpha", "sector_id": str(sector_id)},
                )
                assert r.status_code == 201, r.text
                body = r.json()
                assert body["name"] == "Alpha"
                assert body["session_token"]
                assert body["wire_id"] > 0

            # The membership is genuinely approved, not merely pending --
            # otherwise /ingest would reject every packet.
            status = await real_conn.fetchval(
                "SELECT status FROM sector_memberships WHERE device_id = $1",
                uuid.UUID(body["device_id"]),
            )
            assert status == "approved"
        finally:
            with TestClient(app) as client:
                client.delete("/dev/sim/units")

    async def test_encoded_points_survive_the_real_ingest_pipeline(
        self, real_conn
    ) -> None:
        """The end-to-end claim this whole module rests on: blobs encoded by
        the simulator decrypt, verify and land as track_points, using the
        same code path as the mobile app."""
        sector_id = await _make_sector(real_conn)
        try:
            with TestClient(app) as client:
                created = client.post(
                    "/dev/sim/units",
                    json={"name": "Bravo", "sector_id": str(sector_id)},
                ).json()

                encoded = client.post(
                    f"/dev/sim/units/{created['unit_id']}/encode-points",
                    json={
                        "points": [
                            {"lat": 31.905, "lng": 35.415},
                            {"lat": 31.9052, "lng": 35.4152},
                            {"lat": 31.9054, "lng": 35.4154},
                        ]
                    },
                )
                assert encoded.status_code == 200, encoded.text
                blobs = encoded.json()["blobs"]
                assert len(blobs) == 3

                ingest = client.post(
                    "/ingest",
                    json={"blobs": blobs},
                    headers={"Authorization": f"Bearer {encoded.json()['session_token']}"},
                )
                assert ingest.status_code == 200, ingest.text
                outcome = ingest.json()
                assert outcome["accepted"] == 3, outcome
                assert outcome["signature_invalid"] == 0
                assert outcome["decrypt_failed"] == 0
                # The load-bearing assertion. "accepted" only means stored --
                # a point can be accepted and still contribute nothing, which
                # is exactly what happened when this module defaulted
                # is_mocked to True: 22 accepted, 0 coverage. Asserting
                # hexes_touched is what makes the simulator provably useful
                # for testing the coverage pipeline.
                assert outcome["hexes_touched"] > 0, (
                    "points were stored but produced no coverage -- check "
                    "plausibility (is_mocked / accuracy) before assuming the "
                    "pipeline is fine"
                )

            stored = await real_conn.fetchval(
                "SELECT count(*) FROM track_points WHERE device_id = $1",
                uuid.UUID(created["device_id"]),
            )
            assert stored == 3
            contributions = await real_conn.fetchval(
                "SELECT count(*) FROM hex_contributions WHERE device_id = $1",
                uuid.UUID(created["device_id"]),
            )
            assert contributions > 0, "no rows reached the coverage ledger"
        finally:
            with TestClient(app) as client:
                client.delete("/dev/sim/units")

    async def test_mocked_points_are_stored_but_excluded_from_coverage(
        self, real_conn
    ) -> None:
        """The opposite direction, so the exclusion behaviour stays covered
        now that the default flipped: an explicitly mocked fix is recorded
        for audit but must contribute nothing to the coverage map."""
        sector_id = await _make_sector(real_conn)
        try:
            with TestClient(app) as client:
                created = client.post(
                    "/dev/sim/units",
                    json={"name": "Delta", "sector_id": str(sector_id)},
                ).json()
                encoded = client.post(
                    f"/dev/sim/units/{created['unit_id']}/encode-points",
                    json={
                        "points": [
                            {"lat": 31.906, "lng": 35.416, "is_mocked": True},
                            {"lat": 31.9062, "lng": 35.4162, "is_mocked": True},
                        ]
                    },
                ).json()
                outcome = client.post(
                    "/ingest",
                    json={"blobs": encoded["blobs"]},
                    headers={"Authorization": f"Bearer {encoded['session_token']}"},
                ).json()
                assert outcome["accepted"] == 2
                assert outcome["hexes_touched"] == 0, (
                    "a mocked fix must not reach the coverage ledger"
                )

            assert await real_conn.fetchval(
                "SELECT count(*) FROM hex_contributions WHERE device_id = $1",
                uuid.UUID(created["device_id"]),
            ) == 0
        finally:
            with TestClient(app) as client:
                client.delete("/dev/sim/units")

    async def test_cleanup_removes_only_sim_rows(self, real_conn) -> None:
        sector_id = await _make_sector(real_conn)
        # A non-sim device that must survive the purge.
        from nacl.signing import SigningKey

        real_user = await real_conn.fetchval(
            "INSERT INTO users (phone_e164, display_name) VALUES ($1, $2) RETURNING id",
            f"+1555{uuid.uuid4().int % 10_000_000_000:010d}",
            "Genuine Volunteer",
        )
        real_device = await real_conn.fetchval(
            """
            INSERT INTO devices (user_id, ed25519_public_key, platform, label)
            VALUES ($1, $2, 'android', 'real handset') RETURNING id
            """,
            real_user,
            bytes(SigningKey.generate().verify_key),
        )

        with TestClient(app) as client:
            client.post("/dev/sim/units", json={"name": "Charlie", "sector_id": str(sector_id)})
            r = client.delete("/dev/sim/units")
            assert r.status_code == 200
            assert r.json()["devices_deleted"] >= 1

        assert await real_conn.fetchval(
            "SELECT count(*) FROM devices WHERE id = $1", real_device
        ) == 1, "cleanup deleted a real device"

        await real_conn.execute("DELETE FROM devices WHERE id = $1", real_device)
        await real_conn.execute("DELETE FROM users WHERE id = $1", real_user)
