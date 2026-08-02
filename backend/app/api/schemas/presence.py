from __future__ import annotations

import uuid
from datetime import datetime

from pydantic import BaseModel


class PresenceOut(BaseModel):
    sector_id: uuid.UUID
    device_id: uuid.UUID
    user_id: uuid.UUID
    presence_state: str
    last_point_at: datetime | None
    last_lat: float | None
    last_lng: float | None
    last_battery_pct: int | None
    last_delivery_path: str | None
    state_changed_at: datetime
    updated_at: datetime
