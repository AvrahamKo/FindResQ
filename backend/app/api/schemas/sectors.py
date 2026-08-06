from __future__ import annotations

import uuid
from datetime import datetime
from decimal import Decimal
from typing import Literal

from pydantic import BaseModel, Field, field_validator, model_validator


class GeoJSONPolygon(BaseModel):
    type: Literal["Polygon"]
    coordinates: list[list[list[float]]]

    @field_validator("coordinates")
    @classmethod
    def _validate_ring(cls, rings: list) -> list:
        if not rings or len(rings[0]) < 4:
            raise ValueError("a polygon ring needs at least 4 positions (closed ring)")
        outer = rings[0]
        if outer[0] != outer[-1]:
            raise ValueError("the outer ring must be closed (first position == last)")
        return rings


class SectorCreate(BaseModel):
    name: str = Field(min_length=1, max_length=120)
    boundary: GeoJSONPolygon


class SectorUpdate(BaseModel):
    """Partial update. Both fields optional, but at least one required --
    an empty body would otherwise be a silent no-op that still returns 200."""

    # 'closed' deliberately excluded -- that's a terminal state set by event
    # teardown (`close_all_for_event`), not something to toggle back and
    # forth from this recruitment on/off switch.
    status: Literal["open", "paused"] | None = None

    # Redrawing the outline. Does NOT disturb the coverage ledger; see
    # sectors_repo.update_boundary for why that is correct rather than an
    # omission.
    boundary: GeoJSONPolygon | None = None

    @model_validator(mode="after")
    def _require_at_least_one_field(self) -> SectorUpdate:
        if self.status is None and self.boundary is None:
            raise ValueError("supply at least one of 'status' or 'boundary'")
        return self


class SectorTuningUpdate(BaseModel):
    """All fields optional -- only supplied keys are written (partial update).
    Available to a sector's Lead as well as the Commander, per the PRD's
    "Sector Leads can override defaults"."""

    h3_resolution: int | None = Field(default=None, ge=8, le=13)
    walker_radius_m: Decimal | None = Field(default=None, gt=0, le=100)
    vehicle_base_radius_m: Decimal | None = Field(default=None, gt=0, le=100)
    base_pod_day: Decimal | None = Field(default=None, gt=0, lt=1)
    base_pod_night: Decimal | None = Field(default=None, gt=0, lt=1)
    repeat_discount: Decimal | None = Field(default=None, gt=0, le=1)
    max_gap_seconds: int | None = Field(default=None, ge=5, le=600)
    max_gap_meters: int | None = Field(default=None, ge=5, le=1000)
    min_accuracy_m: int | None = Field(default=None, ge=5, le=200)
    max_walker_speed_mps: Decimal | None = Field(default=None, gt=0, le=20)


class SectorOut(BaseModel):
    id: uuid.UUID
    event_id: uuid.UUID
    name: str
    boundary: dict
    lead_user_id: uuid.UUID | None
    status: str
    key_epoch: int
    h3_resolution: int
    walker_radius_m: Decimal
    vehicle_base_radius_m: Decimal
    base_pod_day: Decimal
    base_pod_night: Decimal
    repeat_discount: Decimal
    max_gap_seconds: int
    max_gap_meters: int
    min_accuracy_m: int
    max_walker_speed_mps: Decimal
    created_at: datetime


class SectorLeadAssign(BaseModel):
    user_id: uuid.UUID


class SectorPermissionsOut(BaseModel):
    """The caller's own capabilities in one sector, for UI gating only.

    Every flag is derived server-side from the same checks the protected
    routes run, so a client never has to encode "who may acknowledge an
    alert" for itself -- and cannot drift from the answer the server will
    actually give.
    """

    sector_id: uuid.UUID
    role: Literal["commander", "lead", "volunteer"]
    is_commander: bool
    is_sector_manager: bool = Field(
        description="True if the caller is this sector's Lead (Sector Manager)."
    )
    can_acknowledge_alerts: bool
    can_delete_alerts: bool
    can_moderate_members: bool
