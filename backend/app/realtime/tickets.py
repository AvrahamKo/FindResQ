"""Short-lived, single-use WebSocket connection tickets.

Browsers cannot set an `Authorization` header on a WebSocket handshake, and
putting a long-lived Bearer token directly in the connection URL means it
lands in every proxy and access log between the browser and this server.
The standard fix: mint a ticket over a normal, header-authenticated REST
call, and the socket handshake presents only that ticket -- opaque,
single-use, and expired within seconds even if it leaks somewhere.

In-memory, per-process -- same scaling caveat as ConnectionManager. A
ticket minted on one worker will not validate on another behind a
load-balanced multi-worker deployment without sticky sessions; the natural
upgrade path is a shared store (Redis) if that's ever needed.
"""

from __future__ import annotations

import secrets
import uuid
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone

TICKET_TTL_SECONDS = 30


@dataclass(frozen=True, slots=True)
class Ticket:
    user_id: uuid.UUID
    event_id: uuid.UUID
    expires_at: datetime


class TicketStore:
    def __init__(self, ttl_seconds: int = TICKET_TTL_SECONDS) -> None:
        self._ttl_seconds = ttl_seconds
        self._tickets: dict[str, Ticket] = {}

    def issue(self, user_id: uuid.UUID, event_id: uuid.UUID) -> tuple[str, datetime]:
        self._evict_expired()
        token = secrets.token_urlsafe(24)
        expires_at = datetime.now(timezone.utc) + timedelta(seconds=self._ttl_seconds)
        self._tickets[token] = Ticket(user_id=user_id, event_id=event_id, expires_at=expires_at)
        return token, expires_at

    def redeem(self, token: str, event_id: uuid.UUID) -> uuid.UUID | None:
        """Single-use: a ticket is consumed on lookup regardless of whether
        it matches `event_id`, so a client cannot retry the same ticket
        against a different event after a mismatch."""
        ticket = self._tickets.pop(token, None)
        if ticket is None:
            return None
        if ticket.expires_at <= datetime.now(timezone.utc):
            return None
        if ticket.event_id != event_id:
            return None
        return ticket.user_id

    def _evict_expired(self) -> None:
        now = datetime.now(timezone.utc)
        expired = [t for t, ticket in self._tickets.items() if ticket.expires_at <= now]
        for t in expired:
            del self._tickets[t]
