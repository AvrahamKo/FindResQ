from __future__ import annotations

import uuid
from datetime import datetime
from decimal import Decimal

import h3
from pydantic import BaseModel, computed_field, field_serializer


class HexCoverageOut(BaseModel):
    # H3 cell ids are 64-bit integers -- larger than JavaScript's safe
    # integer range (2**53-1). The wire value must therefore be a string,
    # and h3-js specifically expects H3's canonical hexadecimal string
    # representation (for example ``8c2db2b25155dff``), not a decimal
    # rendering of the underlying integer.
    hex_id: int
    cumulative_pod: Decimal
    valid_contributions: int
    distinct_searchers: int
    last_contribution_at: datetime | None

    @field_serializer("hex_id")
    def _hex_id_as_string(self, value: int) -> str:
        return h3.int_to_str(value)

    @computed_field(return_type=list[tuple[float, float]])
    @property
    def boundary(self) -> list[tuple[float, float]]:
        """Cell ring in ``[lat, lng]`` order for map clients.

        The web dashboard can derive this from h3-js, but the field app
        deliberately carries no H3 runtime. Sending the six vertices lets
        it cache and render coverage offline without adding another native
        dependency or duplicating H3 conversion code.
        """
        return list(h3.cell_to_boundary(h3.int_to_str(self.hex_id)))


class CoverageResponse(BaseModel):
    sector_id: uuid.UUID
    resolution: int
    hexes: list[HexCoverageOut]
    # Clients pass this database-sourced checkpoint back as `since`. Using
    # the server clock avoids gaps caused by a field handset whose clock is
    # ahead or behind PostgreSQL.
    server_time: datetime


class ContributorOut(BaseModel):
    user_id: uuid.UUID
    segment_id: uuid.UUID
    segment_started_at: datetime
    base_pod: Decimal
    is_valid: bool
