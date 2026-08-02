"""End-to-end pipeline verification against a REAL Postgres, including the
actual `recalc_hex_coverage` SQL function from migrations/0001_init.sql.

This is deliberately not a Python reimplementation of the search-theory
formula -- there is exactly one implementation of
`POD_total = 1 - prod(1 - POD_i)`, in SQL, and this file proves it correct
by driving it through the real ingest pipeline rather than calling it in
isolation.

Skipped automatically if no database is reachable (see conftest.py's
`db_conn` fixture). Run against a real Postgres with migrations 0001-0004
applied to get real signal from this file.
"""

from __future__ import annotations

import uuid
from datetime import datetime, timezone

import pytest
from nacl import utils
from nacl.signing import SigningKey

from app.ingest.pipeline import ingest_batch
from app.mesh import wire_format
from app.repositories import hex_contributions as hex_contrib_repo
from app.repositories import sectors as sectors_repo
from app.security import mesh_crypto

pytestmark = pytest.mark.asyncio

SECTOR_BOUNDARY_GEOJSON = (
    '{"type":"Polygon","coordinates":[[[35.20,31.76],[35.20,31.78],'
    '[35.24,31.78],[35.24,31.76],[35.20,31.76]]]}'
)
NOON_UTC_MS = int(datetime(2026, 6, 1, 12, 0, 0, tzinfo=timezone.utc).timestamp() * 1000)


async def _make_user(conn, name: str) -> uuid.UUID:
    return await conn.fetchval(
        "INSERT INTO users (phone_e164, display_name) VALUES ($1, $2) RETURNING id",
        f"+1555{uuid.uuid4().int % 10_000_000:07d}",
        name,
    )


async def _make_device(conn, user_id: uuid.UUID):
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


async def _make_sector(conn):
    commander_id = await _make_user(conn, "Test Commander")
    event_id = await conn.fetchval(
        "INSERT INTO events (name, commander_id, status) VALUES ($1, $2, 'active') RETURNING id",
        "Test Callout",
        commander_id,
    )
    sector_id = await conn.fetchval(
        """
        INSERT INTO sectors (event_id, name, boundary)
        VALUES ($1, 'Test Sector', ST_SetSRID(ST_GeomFromGeoJSON($2::json), 4326)::geography)
        RETURNING id
        """,
        event_id,
        SECTOR_BOUNDARY_GEOJSON,
    )
    return await sectors_repo.get(conn, sector_id)


def _encrypted_point(
    sector_key: bytes,
    signing_key: SigningKey,
    wire_id: int,
    *,
    t_ms: int,
    lat: float,
    lng: float,
    accuracy_m: float = 5.0,
    speed_mps: float = 1.4,
    battery: int = 80,
    mocked: bool = False,
) -> bytes:
    payload = wire_format.PointPayload(
        wire_id=wire_id,
        recorded_at_ms=t_ms,
        lat=lat,
        lng=lng,
        accuracy_m=accuracy_m,
        speed_mps=speed_mps,
        battery_pct=battery,
        is_mocked=mocked,
    )
    packed = wire_format.pack(payload)
    signature = signing_key.sign(packed).signature
    return mesh_crypto.encrypt(sector_key, packed + signature)


class TestSearchTheoryMathAgainstRealDatabase:
    async def test_two_independent_walkers_combine_to_064_not_080(self, db_conn) -> None:
        """The exact worked example from the architecture review: two
        independent 0.40 POD passes over the same ground give
        1 - (0.60 * 0.60) = 0.64 -- NOT the naive (and dangerous) 0.40+0.40=0.80."""
        conn = db_conn
        sector = await _make_sector(conn)
        sector_key = utils.random(mesh_crypto.KEY_BYTES)

        user_a = await _make_user(conn, "Volunteer A")
        device_a, wire_a, key_a = await _make_device(conn, user_a)
        user_b = await _make_user(conn, "Volunteer B")
        device_b, wire_b, key_b = await _make_device(conn, user_b)

        # Both walk the identical single point -- guarantees their buffered
        # disks (and therefore hex sets) are identical, so every hex touched
        # gets a contribution from both.
        lat, lng = 31.7700, 35.2200

        blob_a = _encrypted_point(sector_key, key_a, wire_a, t_ms=NOON_UTC_MS, lat=lat, lng=lng)
        result_a = await ingest_batch(
            conn, sector=sector, device_id=device_a, device_wire_id=wire_a,
            device_public_key=bytes(key_a.verify_key), user_id=user_a,
            movement_mode="walker", sector_key=sector_key, blobs=[blob_a],
        )
        assert result_a.packets.accepted == 1
        assert result_a.hexes_touched >= 1

        blob_b = _encrypted_point(
            sector_key, key_b, wire_b, t_ms=NOON_UTC_MS + 60_000, lat=lat, lng=lng
        )
        result_b = await ingest_batch(
            conn, sector=sector, device_id=device_b, device_wire_id=wire_b,
            device_public_key=bytes(key_b.verify_key), user_id=user_b,
            movement_mode="walker", sector_key=sector_key, blobs=[blob_b],
        )
        assert result_b.packets.accepted == 1

        coverage = await hex_contrib_repo.get_coverage_for_sector(conn, sector.id, since=None)
        assert coverage, "expected at least one covered hex"
        for hex_state in coverage:
            assert hex_state.distinct_searchers == 2
            assert float(hex_state.cumulative_pod) == pytest.approx(0.64, abs=1e-4)

    async def test_invalidating_first_pass_promotes_second_to_full_weight(self, db_conn) -> None:
        """Q5's retraction bug: a stored discount_factor would leave the
        Commander's invalidation under-reporting coverage. Ranking by
        currently-valid rows at recalc time (not a stored discount) means
        invalidating pass #1 correctly promotes pass #2 from 0.25x to 1.0x."""
        conn = db_conn
        sector = await _make_sector(conn)
        sector_key = utils.random(mesh_crypto.KEY_BYTES)

        user = await _make_user(conn, "Repeat Volunteer")
        device_id, wire_id, key = await _make_device(conn, user)
        lat, lng = 31.7705, 35.2205

        blob_1 = _encrypted_point(sector_key, key, wire_id, t_ms=NOON_UTC_MS, lat=lat, lng=lng)
        await ingest_batch(
            conn, sector=sector, device_id=device_id, device_wire_id=wire_id,
            device_public_key=bytes(key.verify_key), user_id=user,
            movement_mode="walker", sector_key=sector_key, blobs=[blob_1],
        )

        blob_2 = _encrypted_point(
            sector_key, key, wire_id, t_ms=NOON_UTC_MS + 3600_000, lat=lat, lng=lng
        )
        await ingest_batch(
            conn, sector=sector, device_id=device_id, device_wire_id=wire_id,
            device_public_key=bytes(key.verify_key), user_id=user,
            movement_mode="walker", sector_key=sector_key, blobs=[blob_2],
        )

        coverage_before = await hex_contrib_repo.get_coverage_for_sector(conn, sector.id, None)
        assert coverage_before
        # 0.40 + a 0.25x-discounted second pass: 1 - (0.60 * 0.90) = 0.46
        for hex_state in coverage_before:
            assert float(hex_state.cumulative_pod) == pytest.approx(0.46, abs=1e-4)

        touched_hexes = [h.hex_id for h in coverage_before]
        first_segment_id = (
            await conn.fetch(
                "SELECT segment_id FROM hex_contributions WHERE sector_id = $1 "
                "ORDER BY segment_started_at LIMIT 1",
                sector.id,
            )
        )[0]["segment_id"]

        await conn.execute(
            "UPDATE hex_contributions SET is_valid = false WHERE segment_id = $1",
            first_segment_id,
        )
        await hex_contrib_repo.recalc(conn, sector.id, set(touched_hexes))

        coverage_after = await hex_contrib_repo.get_coverage_for_sector(conn, sector.id, None)
        for hex_state in coverage_after:
            # Promoted to full weight, not left at the 0.25x-discounted rate.
            assert float(hex_state.cumulative_pod) == pytest.approx(0.40, abs=1e-4)
            assert hex_state.valid_contributions == 1

    async def test_stationary_volunteer_does_not_inflate_pod(self, db_conn) -> None:
        """The bug this whole ledger design exists to prevent: many GPS fixes
        from one stationary phone must collapse to ONE traverse-episode
        contribution, not compound toward ~1.0 via repeated multiplication."""
        conn = db_conn
        sector = await _make_sector(conn)
        sector_key = utils.random(mesh_crypto.KEY_BYTES)
        user = await _make_user(conn, "Standing Still")
        device_id, wire_id, key = await _make_device(conn, user)
        lat, lng = 31.7710, 35.2210

        # 20 fixes, 30s apart, at the exact same spot -- one continuous run.
        blobs = [
            _encrypted_point(
                sector_key, key, wire_id, t_ms=NOON_UTC_MS + i * 30_000, lat=lat, lng=lng
            )
            for i in range(20)
        ]
        result = await ingest_batch(
            conn, sector=sector, device_id=device_id, device_wire_id=wire_id,
            device_public_key=bytes(key.verify_key), user_id=user,
            movement_mode="walker", sector_key=sector_key, blobs=blobs,
        )
        assert result.packets.accepted == 20
        assert result.segments_opened == 1  # one run, not 20

        coverage = await hex_contrib_repo.get_coverage_for_sector(conn, sector.id, None)
        assert coverage
        for hex_state in coverage:
            # One searcher, one pass -- exactly base_pod_day, never inflated.
            assert float(hex_state.cumulative_pod) == pytest.approx(0.40, abs=1e-4)
            assert hex_state.valid_contributions == 1


class TestPipelineEndToEnd:
    async def test_replayed_packet_is_rejected_as_duplicate(self, db_conn) -> None:
        conn = db_conn
        sector = await _make_sector(conn)
        sector_key = utils.random(mesh_crypto.KEY_BYTES)
        user = await _make_user(conn, "Replay Target")
        device_id, wire_id, key = await _make_device(conn, user)

        blob = _encrypted_point(sector_key, key, wire_id, t_ms=NOON_UTC_MS, lat=31.77, lng=35.22)

        first = await ingest_batch(
            conn, sector=sector, device_id=device_id, device_wire_id=wire_id,
            device_public_key=bytes(key.verify_key), user_id=user,
            movement_mode="walker", sector_key=sector_key, blobs=[blob],
        )
        assert first.packets.accepted == 1

        replay = await ingest_batch(
            conn, sector=sector, device_id=device_id, device_wire_id=wire_id,
            device_public_key=bytes(key.verify_key), user_id=user,
            movement_mode="walker", sector_key=sector_key, blobs=[blob],
        )
        assert replay.packets.duplicate == 1
        assert replay.packets.accepted == 0

    async def test_forged_signature_is_rejected(self, db_conn) -> None:
        """An attacker holding the sector key (shared, symmetric) but not the
        device's Ed25519 private key cannot mint a valid packet."""
        conn = db_conn
        sector = await _make_sector(conn)
        sector_key = utils.random(mesh_crypto.KEY_BYTES)
        user = await _make_user(conn, "Victim")
        device_id, wire_id, _real_key = await _make_device(conn, user)
        attacker_key = SigningKey.generate()  # attacker's own key, not the device's

        forged_blob = _encrypted_point(
            sector_key, attacker_key, wire_id, t_ms=NOON_UTC_MS, lat=31.77, lng=35.22
        )
        result = await ingest_batch(
            conn, sector=sector, device_id=device_id, device_wire_id=wire_id,
            device_public_key=bytes(_real_key.verify_key), user_id=user,
            movement_mode="walker", sector_key=sector_key, blobs=[forged_blob],
        )
        assert result.packets.signature_invalid == 1
        assert result.packets.accepted == 0

    async def test_wrong_sector_key_fails_to_decrypt(self, db_conn) -> None:
        conn = db_conn
        sector = await _make_sector(conn)
        real_key = utils.random(mesh_crypto.KEY_BYTES)
        wrong_key = utils.random(mesh_crypto.KEY_BYTES)
        user = await _make_user(conn, "Someone")
        device_id, wire_id, signing_key = await _make_device(conn, user)

        blob = _encrypted_point(real_key, signing_key, wire_id, t_ms=NOON_UTC_MS, lat=31.77, lng=35.22)
        result = await ingest_batch(
            conn, sector=sector, device_id=device_id, device_wire_id=wire_id,
            device_public_key=bytes(signing_key.verify_key), user_id=user,
            movement_mode="walker", sector_key=wrong_key, blobs=[blob],
        )
        assert result.packets.decrypt_failed == 1

    async def test_gap_produces_two_segments_not_one(self, db_conn) -> None:
        conn = db_conn
        sector = await _make_sector(conn)
        sector_key = utils.random(mesh_crypto.KEY_BYTES)
        user = await _make_user(conn, "Gapped Walker")
        device_id, wire_id, key = await _make_device(conn, user)

        blobs = [
            _encrypted_point(sector_key, key, wire_id, t_ms=NOON_UTC_MS, lat=31.7700, lng=35.2200),
            _encrypted_point(
                sector_key, key, wire_id,
                t_ms=NOON_UTC_MS + 3600_000, lat=31.7701, lng=35.2201,  # 1 hour later
            ),
        ]
        result = await ingest_batch(
            conn, sector=sector, device_id=device_id, device_wire_id=wire_id,
            device_public_key=bytes(key.verify_key), user_id=user,
            movement_mode="walker", sector_key=sector_key, blobs=blobs,
        )
        assert result.packets.accepted == 2
        assert result.segments_opened == 2

    async def test_mocked_point_is_stored_but_contributes_no_coverage(self, db_conn) -> None:
        conn = db_conn
        sector = await _make_sector(conn)
        sector_key = utils.random(mesh_crypto.KEY_BYTES)
        user = await _make_user(conn, "Mock Location User")
        device_id, wire_id, key = await _make_device(conn, user)

        blob = _encrypted_point(
            sector_key, key, wire_id, t_ms=NOON_UTC_MS, lat=31.77, lng=35.22, mocked=True
        )
        result = await ingest_batch(
            conn, sector=sector, device_id=device_id, device_wire_id=wire_id,
            device_public_key=bytes(key.verify_key), user_id=user,
            movement_mode="walker", sector_key=sector_key, blobs=[blob],
        )
        assert result.packets.accepted == 1
        assert result.hexes_touched == 0

        stored = await conn.fetchval(
            "SELECT count(*) FROM track_points WHERE device_id = $1", device_id
        )
        assert stored == 1  # stored for audit

        coverage = await hex_contrib_repo.get_coverage_for_sector(conn, sector.id, None)
        assert coverage == []  # but never contributes to the heatmap
