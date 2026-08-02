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


class ConnectionManager:
    def __init__(self) -> None:
        self._connections: dict[uuid.UUID, set[WebSocket]] = {}
        self._lock = asyncio.Lock()

    async def connect(self, event_id: uuid.UUID, websocket: WebSocket) -> None:
        async with self._lock:
            self._connections.setdefault(event_id, set()).add(websocket)

    async def disconnect(self, event_id: uuid.UUID, websocket: WebSocket) -> None:
        async with self._lock:
            sockets = self._connections.get(event_id)
            if sockets is None:
                return
            sockets.discard(websocket)
            if not sockets:
                del self._connections[event_id]

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
