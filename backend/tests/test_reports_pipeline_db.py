"""Report ingest pipeline verification against a REAL Postgres -- mirrors
`test_ingest_pipeline_db.py`'s shape for location points. Skipped
automatically if no database is reachable (see conftest.py's `db_conn`).
"""

from __future__ import annotations

import pytest
from nacl import utils
from nacl.signing import SigningKey

from app.mesh import report_format
from app.repositories import reports as reports_repo
from app.reports.pipeline import ingest_reports
from app.security import mesh_crypto
from tests.test_ingest_pipeline_db import _make_device, _make_sector, _make_user

pytestmark = pytest.mark.asyncio


def _encrypted_report(
    sector_key: bytes,
    signing_key: SigningKey,
    wire_id: int,
    *,
    t_ms: int,
    kind: str = "hazard",
    lat: float = 31.7715,
    lng: float = 35.2170,
    note: str = "Downed power line.",
) -> bytes:
    payload = report_format.ReportPayload(
        wire_id=wire_id, recorded_at_ms=t_ms, kind=kind, lat=lat, lng=lng, note=note,
    )
    packed = report_format.pack(payload)
    signature = signing_key.sign(packed).signature
    return mesh_crypto.encrypt(sector_key, packed + signature)


class TestValidReports:
    async def test_a_valid_report_is_accepted_and_stored(self, db_conn) -> None:
        sector = await _make_sector(db_conn)
        sector_key = utils.random(mesh_crypto.KEY_BYTES)
        user_id = await _make_user(db_conn, "Reporter")
        device_id, wire_id, signing_key = await _make_device(db_conn, user_id)

        blob = _encrypted_report(
            sector_key, signing_key, wire_id, t_ms=1_700_000_000_000,
            kind="subject_found", note="Subject spotted near the ridge.",
        )

        outcome = await ingest_reports(
            db_conn, sector=sector, device_id=device_id, device_wire_id=wire_id,
            device_public_key=bytes(signing_key.verify_key), user_id=user_id,
            sector_key=sector_key, blobs=[blob],
        )

        assert outcome.accepted == 1
        assert outcome.duplicate == 0

        stored = await reports_repo.list_for_sector(db_conn, sector.id)
        assert len(stored) == 1
        assert stored[0].kind == "subject_found"
        assert stored[0].note == "Subject spotted near the ridge."
        assert stored[0].lat == pytest.approx(31.7715, abs=1e-6)
        assert stored[0].lng == pytest.approx(35.2170, abs=1e-6)
        assert stored[0].delivery_path == "direct"
        assert stored[0].status == "open"

    async def test_an_empty_note_is_stored_as_null(self, db_conn) -> None:
        # ReportPayload.note is always a str (never absent on the wire), but
        # the DB column is nullable -- an empty note should round-trip to
        # NULL, not an empty string, matching reports_repo.create's `note or
        # None`.
        sector = await _make_sector(db_conn)
        sector_key = utils.random(mesh_crypto.KEY_BYTES)
        user_id = await _make_user(db_conn, "Reporter2")
        device_id, wire_id, signing_key = await _make_device(db_conn, user_id)

        blob = _encrypted_report(
            sector_key, signing_key, wire_id, t_ms=1_700_000_000_000, note="",
        )
        await ingest_reports(
            db_conn, sector=sector, device_id=device_id, device_wire_id=wire_id,
            device_public_key=bytes(signing_key.verify_key), user_id=user_id,
            sector_key=sector_key, blobs=[blob],
        )

        stored = await reports_repo.list_for_sector(db_conn, sector.id)
        assert stored[0].note is None

    async def test_multiple_reports_in_one_batch_are_all_accepted(self, db_conn) -> None:
        sector = await _make_sector(db_conn)
        sector_key = utils.random(mesh_crypto.KEY_BYTES)
        user_id = await _make_user(db_conn, "Reporter3")
        device_id, wire_id, signing_key = await _make_device(db_conn, user_id)

        blobs = [
            _encrypted_report(sector_key, signing_key, wire_id, t_ms=1_700_000_000_000 + i, kind=kind)
            for i, kind in enumerate(["hazard", "item_found", "medical"])
        ]

        outcome = await ingest_reports(
            db_conn, sector=sector, device_id=device_id, device_wire_id=wire_id,
            device_public_key=bytes(signing_key.verify_key), user_id=user_id,
            sector_key=sector_key, blobs=blobs,
        )

        assert outcome.accepted == 3


class TestRejectedReports:
    async def test_a_duplicate_signature_is_deduplicated(self, db_conn) -> None:
        sector = await _make_sector(db_conn)
        sector_key = utils.random(mesh_crypto.KEY_BYTES)
        user_id = await _make_user(db_conn, "Reporter4")
        device_id, wire_id, signing_key = await _make_device(db_conn, user_id)
        blob = _encrypted_report(sector_key, signing_key, wire_id, t_ms=1_700_000_000_000)

        first = await ingest_reports(
            db_conn, sector=sector, device_id=device_id, device_wire_id=wire_id,
            device_public_key=bytes(signing_key.verify_key), user_id=user_id,
            sector_key=sector_key, blobs=[blob],
        )
        second = await ingest_reports(
            db_conn, sector=sector, device_id=device_id, device_wire_id=wire_id,
            device_public_key=bytes(signing_key.verify_key), user_id=user_id,
            sector_key=sector_key, blobs=[blob],
        )

        assert first.accepted == 1
        assert second.accepted == 0
        assert second.duplicate == 1

    async def test_wrong_sector_key_fails_to_decrypt(self, db_conn) -> None:
        sector = await _make_sector(db_conn)
        real_key = utils.random(mesh_crypto.KEY_BYTES)
        wrong_key = utils.random(mesh_crypto.KEY_BYTES)
        user_id = await _make_user(db_conn, "Reporter5")
        device_id, wire_id, signing_key = await _make_device(db_conn, user_id)
        blob = _encrypted_report(real_key, signing_key, wire_id, t_ms=1_700_000_000_000)

        outcome = await ingest_reports(
            db_conn, sector=sector, device_id=device_id, device_wire_id=wire_id,
            device_public_key=bytes(signing_key.verify_key), user_id=user_id,
            sector_key=wrong_key, blobs=[blob],
        )

        assert outcome.decrypt_failed == 1
        assert outcome.accepted == 0

    async def test_wire_id_mismatch_is_flagged_wrong_device(self, db_conn) -> None:
        sector = await _make_sector(db_conn)
        sector_key = utils.random(mesh_crypto.KEY_BYTES)
        user_id = await _make_user(db_conn, "Reporter6")
        device_id, wire_id, signing_key = await _make_device(db_conn, user_id)
        # Packed with a DIFFERENT wire_id than the device actually presenting it.
        blob = _encrypted_report(sector_key, signing_key, wire_id + 999, t_ms=1_700_000_000_000)

        outcome = await ingest_reports(
            db_conn, sector=sector, device_id=device_id, device_wire_id=wire_id,
            device_public_key=bytes(signing_key.verify_key), user_id=user_id,
            sector_key=sector_key, blobs=[blob],
        )

        assert outcome.wrong_device == 1
        assert outcome.accepted == 0

    async def test_a_forged_signature_is_rejected(self, db_conn) -> None:
        sector = await _make_sector(db_conn)
        sector_key = utils.random(mesh_crypto.KEY_BYTES)
        user_id = await _make_user(db_conn, "Reporter7")
        device_id, wire_id, real_key = await _make_device(db_conn, user_id)
        attacker_key = SigningKey.generate()
        # Signed by an attacker's key, but claiming the victim device's wire_id.
        blob = _encrypted_report(sector_key, attacker_key, wire_id, t_ms=1_700_000_000_000)

        outcome = await ingest_reports(
            db_conn, sector=sector, device_id=device_id, device_wire_id=wire_id,
            device_public_key=bytes(real_key.verify_key), user_id=user_id,
            sector_key=sector_key, blobs=[blob],
        )

        assert outcome.signature_invalid == 1
        assert outcome.accepted == 0

    async def test_a_malformed_plaintext_is_flagged_malformed(self, db_conn) -> None:
        sector = await _make_sector(db_conn)
        sector_key = utils.random(mesh_crypto.KEY_BYTES)
        user_id = await _make_user(db_conn, "Reporter8")
        device_id, wire_id, signing_key = await _make_device(db_conn, user_id)
        # Too short to even contain a header.
        blob = mesh_crypto.encrypt(sector_key, b"short")

        outcome = await ingest_reports(
            db_conn, sector=sector, device_id=device_id, device_wire_id=wire_id,
            device_public_key=bytes(signing_key.verify_key), user_id=user_id,
            sector_key=sector_key, blobs=[blob],
        )

        assert outcome.malformed == 1
        assert outcome.accepted == 0
