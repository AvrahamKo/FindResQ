"""Coverage API wire-format tests that do not require a database."""

from __future__ import annotations

from datetime import datetime, timezone
from decimal import Decimal
import uuid

import h3

from app.api.routes.coverage import _parse_hex_id
from app.api.schemas.coverage import HexCoverageOut
from app.repositories import hex_contributions as hex_contrib_repo


def test_hex_id_serializes_as_canonical_h3_string() -> None:
    canonical = h3.latlng_to_cell(31.768585, 35.207740, 12)
    integer_id = h3.str_to_int(canonical)

    payload = HexCoverageOut(
        hex_id=integer_id,
        cumulative_pod=Decimal("0.40"),
        valid_contributions=1,
        distinct_searchers=1,
        last_contribution_at=datetime(2026, 8, 5, tzinfo=timezone.utc),
    ).model_dump(mode="json")

    assert payload["hex_id"] == canonical
    assert payload["cumulative_pod"] == "0.40"
    assert h3.is_valid_cell(payload["hex_id"])
    assert len(payload["boundary"]) == 6
    center = h3.cell_to_latlng(canonical)
    assert all(len(point) == 2 for point in payload["boundary"])
    assert min(point[0] for point in payload["boundary"]) < center[0]
    assert max(point[0] for point in payload["boundary"]) > center[0]


def test_contributor_lookup_accepts_canonical_and_legacy_decimal_ids() -> None:
    canonical = h3.latlng_to_cell(31.768585, 35.207740, 12)
    integer_id = h3.str_to_int(canonical)

    assert _parse_hex_id(canonical) == integer_id
    assert _parse_hex_id(str(integer_id)) == integer_id


async def test_delta_query_is_bounded_by_server_checkpoint() -> None:
    class RecordingConnection:
        query = ""
        args: tuple[object, ...] = ()

        async def fetch(self, query: str, *args: object) -> list[object]:
            self.query = query
            self.args = args
            return []

    conn = RecordingConnection()
    sector_id = uuid.uuid4()
    since = datetime(2030, 1, 1, tzinfo=timezone.utc)
    until = datetime(2030, 1, 1, 0, 1, tzinfo=timezone.utc)

    result = await hex_contrib_repo.get_coverage_for_sector(
        conn,  # type: ignore[arg-type]
        sector_id,
        since,
        until=until,
    )

    assert result == []
    assert "updated_at > $2" in conn.query
    assert "updated_at <= $3" in conn.query
    assert conn.args == (sector_id, since, until)
