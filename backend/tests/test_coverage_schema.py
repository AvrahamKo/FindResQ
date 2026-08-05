"""Coverage API wire-format tests that do not require a database."""

from __future__ import annotations

from datetime import datetime, timezone
from decimal import Decimal

import h3

from app.api.routes.coverage import _parse_hex_id
from app.api.schemas.coverage import HexCoverageOut


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
