from __future__ import annotations

import uuid
from datetime import datetime

from pydantic import BaseModel


class SosTriggerRequest(BaseModel):
    # Optional -- if omitted, the route falls back to the device's last
    # known presence point rather than requiring a fresh GPS fix before an
    # SOS can even be sent. See routes/sos.py's trigger_sos docstring.
    lat: float | None = None
    lng: float | None = None


class SosOut(BaseModel):
    id: uuid.UUID
    sector_id: uuid.UUID
    device_id: uuid.UUID
    user_id: uuid.UUID
    status: str
    lat: float | None
    lng: float | None
    triggered_at: datetime
    acknowledged_at: datetime | None
    acknowledged_by: uuid.UUID | None
    resolved_at: datetime | None
    resolved_by: uuid.UUID | None
    cancelled_at: datetime | None
    updated_at: datetime
