"""Tracks active dashboard WebSocket connections, grouped by event, and
broadcasts JSON messages to them.

Per-process, in-memory. A client connected to worker A never sees a
broadcast triggered by a notification processed on worker B. That is an
acceptable MVP tradeoff for a single-worker deployment; horizontal scaling
would need either sticky sessions at the load balancer or a shared broadcast
layer -- the LISTEN/NOTIFY-driven design upstream of this class already
solves the "which data changed" problem correctly regardless, so scaling
this out later is a matter of fanning the same messages to multiple
processes, not redesigning how changes are detected.
"""

from __future__ import annotations

import asyncio
import logging
import uuid

from fastapi import WebSocket

logger = logging.getLogger(__name__)


# Application-defined close codes (4000-4999 is the private range).
CLOSE_EVENT_DELETED = 4404
CLOSE_ACCESS_REVOKED = 4403


class ConnectionManager:
    def __init__(self) -> None:
        self._connections: dict[uuid.UUID, set[WebSocket]] = {}
        # Which user each socket belongs to. Kept alongside, rather than
        # inside, `_connections` so the broadcast path -- by far the hottest
        # -- still iterates a plain set of sockets with no per-message
        # unwrapping. Revocation is rare; broadcast is constant.
        self._socket_users: dict[WebSocket, uuid.UUID] = {}
        self._lock = asyncio.Lock()

    async def connect(
        self, event_id: uuid.UUID, websocket: WebSocket, user_id: uuid.UUID
    ) -> None:
        async with self._lock:
            self._connections.setdefault(event_id, set()).add(websocket)
            self._socket_users[websocket] = user_id

    async def disconnect(self, event_id: uuid.UUID, websocket: WebSocket) -> None:
        async with self._lock:
            self._socket_users.pop(websocket, None)
            sockets = self._connections.get(event_id)
            if sockets is None:
                return
            sockets.discard(websocket)
            if not sockets:
                del self._connections[event_id]

    async def close_event(self, event_id: uuid.UUID, message: dict) -> int:
        """Sends a final message to every socket watching `event_id`, closes
        them, and forgets the group entirely. Returns how many were closed.

        This is the in-memory half of event deletion. Without it the event's
        entry lives on in `_connections` for as long as the process does,
        holding sockets open against an event whose every row is gone -- so
        each deleted event leaks a dict entry plus its sockets, and those
        sockets sit there waiting for broadcasts that can never arrive again.

        The message is sent BEFORE the close so the dashboard can react
        (navigate away, drop its local state) rather than merely observing a
        socket drop, which is indistinguishable from a flaky field link.
        """
        async with self._lock:
            sockets = list(self._connections.pop(event_id, ()))
            for ws in sockets:
                self._socket_users.pop(ws, None)

        for ws in sockets:
            try:
                await ws.send_json(message)
                await ws.close(code=CLOSE_EVENT_DELETED)
            except Exception:
                # Already dead. Nothing to clean up -- it is out of both
                # dicts by this point either way.
                pass
        return len(sockets)

    async def disconnect_user(
        self, event_id: uuid.UUID, user_id: uuid.UUID, message: dict
    ) -> int:
        """Force-closes just this user's sockets on one event, leaving
        everyone else's untouched. Returns how many were closed.

        This is what makes removing a user take effect *immediately* rather
        than at their next REST call. A WebSocket is a stream the server is
        already pushing to -- re-checking a bearer token cannot help, because
        after the handshake there are no further requests to check. The
        server has to hang up.
        """
        async with self._lock:
            sockets = [
                ws
                for ws in self._connections.get(event_id, ())
                if self._socket_users.get(ws) == user_id
            ]
            group = self._connections.get(event_id)
            for ws in sockets:
                self._socket_users.pop(ws, None)
                if group:
                    group.discard(ws)
            if group is not None and not group:
                del self._connections[event_id]

        for ws in sockets:
            try:
                await ws.send_json(message)
                await ws.close(code=CLOSE_ACCESS_REVOKED)
            except Exception:
                pass
        return len(sockets)

    async def broadcast(self, event_id: uuid.UUID, message: dict) -> None:
        async with self._lock:
            sockets = list(self._connections.get(event_id, ()))

        stale: list[WebSocket] = []
        for ws in sockets:
            try:
                await ws.send_json(message)
            except Exception:
                stale.append(ws)

        if stale:
            async with self._lock:
                group = self._connections.get(event_id)
                if group:
                    for ws in stale:
                        group.discard(ws)
                    if not group:
                        self._connections.pop(event_id, None)

    def connection_count(self, event_id: uuid.UUID) -> int:
        return len(self._connections.get(event_id, ()))

    def tracked_event_ids(self) -> list[uuid.UUID]:
        return list(self._connections)
