from __future__ import annotations

import uuid
from datetime import datetime
from decimal import Decimal

from pydantic import BaseModel, field_serializer


class HexCoverageOut(BaseModel):
    # H3 cell ids are 64-bit integers -- larger than JavaScript's safe
    # integer range (2**53-1). Serialized as a string so a JS-based
    # dashboard never silently loses precision on a raw JSON number.
    hex_id: int
    cumulative_pod: Decimal
    valid_contributions: int
    distinct_searchers: int
    last_contribution_at: datetime | None

    @field_serializer("hex_id")
    def _hex_id_as_string(self, value: int) -> str:
        return str(value)


class CoverageResponse(BaseModel):
    sector_id: uuid.UUID
    resolution: int
    hexes: list[HexCoverageOut]


class ContributorOut(BaseModel):
    user_id: uuid.UUID
    segment_id: uuid.UUID
    segment_started_at: datetime
    base_pod: Decimal
    is_valid: bool
