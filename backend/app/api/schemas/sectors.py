from __future__ import annotations

import uuid
from datetime import datetime
from decimal import Decimal
from typing import Literal

from pydantic import BaseModel, Field, field_validator


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


class SectorStatusUpdate(BaseModel):
    # 'closed' deliberately excluded -- that's a terminal state set by event
    # teardown (`close_all_for_event`), not something to toggle back and
    # forth from this recruitment on/off switch.
    status: Literal["open", "paused"]


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
