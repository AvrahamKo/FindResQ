"""Realtime transport for the Commander dashboard.

Two-step connection, because a browser WebSocket handshake cannot carry an
`Authorization` header:

  1. POST /events/{event_id}/ws-ticket   (normal Bearer-token REST call)
     -> a short-lived, single-use ticket
  2. WS   /ws/events/{event_id}?ticket=...
     -> the ticket is redeemed once, at handshake time

The socket is push-only from the server's perspective: it broadcasts
`hex_delta` / `presence_delta` messages as the realtime listener (see
app/realtime/listener.py) observes sector changes. A client connecting
should first hydrate itself via `GET /sectors/{id}/hexes` and
`GET /sectors/{id}/presence` (Phase 3/4 REST snapshots), then rely on this
socket for changes from that point on -- the socket does not replay history
on connect.
"""

from __future__ import annotations

import logging
import uuid

from fastapi import APIRouter, Request, WebSocket, WebSocketDisconnect, status

from ..deps import ConnDep, CurrentUser
from .events import _get_visible_event
from ..schemas.realtime import WsTicketResponse

logger = logging.getLogger(__name__)

router = APIRouter(tags=["realtime"])


@router.post(
    "/events/{event_id}/ws-ticket",
    response_model=WsTicketResponse,
    status_code=status.HTTP_201_CREATED,
)
async def create_ws_ticket(
    event_id: uuid.UUID, user: CurrentUser, conn: ConnDep, request: Request
) -> WsTicketResponse:
    await _get_visible_event(conn, event_id, user)
    token, expires_at = request.app.state.ticket_store.issue(user.id, event_id)
    return WsTicketResponse(ticket=token, expires_at=expires_at)


@router.websocket("/ws/events/{event_id}")
async def dashboard_socket(websocket: WebSocket, event_id: uuid.UUID) -> None:
    ticket_store = websocket.app.state.ticket_store
    manager = websocket.app.state.connection_manager

    token = websocket.query_params.get("ticket")

    # Must accept before we can close with an application-defined code --
    # Starlette does not support rejecting the handshake itself with a
    # custom status, only after upgrading.
    await websocket.accept()

    if not token:
        await websocket.close(code=4401, reason="missing ticket")
        return

    user_id = ticket_store.redeem(token, event_id)
    if user_id is None:
        await websocket.close(code=4401, reason="invalid or expired ticket")
        return

    # The user id is retained per-socket so the server can hang up on one
    # specific person when their access is revoked -- after the handshake
    # there are no further requests to re-authorize, so a push stream can
    # only be stopped by closing it. See ConnectionManager.disconnect_user.
    await manager.connect(event_id, websocket, user_id)
    logger.info("dashboard socket connected user_id=%s event_id=%s", user_id, event_id)

    try:
        await websocket.send_json({"type": "connected", "event_id": str(event_id)})
        while True:
            try:
                message = await websocket.receive_json()
            except ValueError:
                continue  # malformed frame; this channel is push-only anyway, ignore and keep listening
            if message.get("type") == "ping":
                await websocket.send_json({"type": "pong"})
    except WebSocketDisconnect:
        pass
    finally:
        await manager.disconnect(event_id, websocket)
        logger.info("dashboard socket disconnected user_id=%s event_id=%s", user_id, event_id)
