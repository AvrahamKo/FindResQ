from __future__ import annotations

from datetime import datetime

from pydantic import BaseModel


class WsTicketResponse(BaseModel):
    ticket: str
    expires_at: datetime
