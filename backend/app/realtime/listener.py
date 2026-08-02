"""Background task: LISTENs for sector-change notifications (fired by the
`hex_coverage_state`/`device_presence` triggers in migration 0005) and pushes
deltas to connected dashboard WebSockets.

Uses a dedicated connection, not one borrowed from the request pool -- a
LISTEN session needs to stay open indefinitely, and the pool could otherwise
recycle or reset a connection out from under it.

On each notification this re-queries "what changed for this sector since my
last checkpoint" rather than trusting the NOTIFY payload to carry the delta:
Postgres caps NOTIFY payloads at 8000 bytes, and a delta-since-timestamp
query is self-healing against any notification that gets missed or
coalesced, which a payload-carries-the-delta design would not be.
"""

from __future__ import annotations

import asyncio
import logging
import uuid
from dataclasses import asdict
from datetime import datetime, timezone

import asyncpg

from ..api.schemas.coverage import HexCoverageOut
from ..api.schemas.presence import PresenceOut
from ..api.schemas.reports import ReportOut
from ..api.schemas.sos import SosOut
from ..repositories import hex_contributions as hex_contrib_repo
from ..repositories import presence as presence_repo
from ..repositories import reports as reports_repo
from ..repositories import sos as sos_repo
from .manager import ConnectionManager

logger = logging.getLogger(__name__)

COVERAGE_CHANNEL = "sector_coverage_channel"
PRESENCE_CHANNEL = "sector_presence_channel"
SOS_CHANNEL = "sector_sos_channel"
REPORT_CHANNEL = "sector_report_channel"


class RealtimeListener:
    def __init__(
        self, database_url: str, pool: asyncpg.Pool, manager: ConnectionManager
    ) -> None:
        self._database_url = database_url
        self._pool = pool
        self._manager = manager
        self._conn: asyncpg.Connection | None = None
        self._coverage_checkpoints: dict[uuid.UUID, datetime] = {}
        self._presence_checkpoints: dict[uuid.UUID, datetime] = {}
        self._sos_checkpoints: dict[uuid.UUID, datetime] = {}
        self._report_checkpoints: dict[uuid.UUID, datetime] = {}

    async def start(self) -> None:
        self._conn = await asyncpg.connect(self._database_url)
        await self._conn.add_listener(COVERAGE_CHANNEL, self._on_coverage_notify)
        await self._conn.add_listener(PRESENCE_CHANNEL, self._on_presence_notify)
        await self._conn.add_listener(SOS_CHANNEL, self._on_sos_notify)
        await self._conn.add_listener(REPORT_CHANNEL, self._on_report_notify)
        logger.info("realtime listener connected and subscribed")

    async def stop(self) -> None:
        if self._conn is not None:
            await self._conn.close()
            self._conn = None

    # Plain (non-coroutine) callbacks that schedule their own task: this
    # guarantees notification dispatch is never blocked by a slow delta
    # query, regardless of how asyncpg internally schedules a coroutine
    # callback passed to add_listener.
    def _on_coverage_notify(self, connection, pid, channel, payload: str) -> None:
        asyncio.create_task(self._safe(self._handle_coverage_change, uuid.UUID(payload)))

    def _on_presence_notify(self, connection, pid, channel, payload: str) -> None:
        asyncio.create_task(self._safe(self._handle_presence_change, uuid.UUID(payload)))

    def _on_sos_notify(self, connection, pid, channel, payload: str) -> None:
        asyncio.create_task(self._safe(self._handle_sos_change, uuid.UUID(payload)))

    def _on_report_notify(self, connection, pid, channel, payload: str) -> None:
        asyncio.create_task(self._safe(self._handle_report_change, uuid.UUID(payload)))

    async def _safe(self, handler, sector_id: uuid.UUID) -> None:
        try:
            await handler(sector_id)
        except Exception:
            logger.exception(
                "realtime handler %s failed for sector_id=%s", handler.__name__, sector_id
            )

    async def _event_id_for_sector(self, sector_id: uuid.UUID) -> uuid.UUID | None:
        async with self._pool.acquire() as conn:
            return await conn.fetchval(
                "SELECT event_id FROM sectors WHERE id = $1", sector_id
            )

    async def _handle_coverage_change(self, sector_id: uuid.UUID) -> None:
        event_id = await self._event_id_for_sector(sector_id)
        if event_id is None or self._manager.connection_count(event_id) == 0:
            return

        since = self._coverage_checkpoints.get(sector_id)
        checkpoint = datetime.now(timezone.utc)
        async with self._pool.acquire() as conn:
            rows = await hex_contrib_repo.get_coverage_for_sector(conn, sector_id, since)
        self._coverage_checkpoints[sector_id] = checkpoint

        if not rows:
            return
        await self._manager.broadcast(
            event_id,
            {
                "type": "hex_delta",
                "sector_id": str(sector_id),
                "hexes": [HexCoverageOut(**asdict(r)).model_dump(mode="json") for r in rows],
            },
        )

    async def _handle_presence_change(self, sector_id: uuid.UUID) -> None:
        event_id = await self._event_id_for_sector(sector_id)
        if event_id is None or self._manager.connection_count(event_id) == 0:
            return

        since = self._presence_checkpoints.get(sector_id)
        checkpoint = datetime.now(timezone.utc)
        async with self._pool.acquire() as conn:
            rows = await presence_repo.get_for_sector(conn, sector_id, since)
        self._presence_checkpoints[sector_id] = checkpoint

        if not rows:
            return
        await self._manager.broadcast(
            event_id,
            {
                "type": "presence_delta",
                "sector_id": str(sector_id),
                "devices": [PresenceOut(**asdict(r)).model_dump(mode="json") for r in rows],
            },
        )

    async def _handle_sos_change(self, sector_id: uuid.UUID) -> None:
        event_id = await self._event_id_for_sector(sector_id)
        if event_id is None or self._manager.connection_count(event_id) == 0:
            return

        since = self._sos_checkpoints.get(sector_id)
        checkpoint = datetime.now(timezone.utc)
        async with self._pool.acquire() as conn:
            rows = await sos_repo.get_for_sector(conn, sector_id, since)
        self._sos_checkpoints[sector_id] = checkpoint

        if not rows:
            return
        await self._manager.broadcast(
            event_id,
            {
                "type": "sos_delta",
                "sector_id": str(sector_id),
                "alerts": [SosOut(**asdict(r)).model_dump(mode="json") for r in rows],
            },
        )

    async def _handle_report_change(self, sector_id: uuid.UUID) -> None:
        event_id = await self._event_id_for_sector(sector_id)
        if event_id is None or self._manager.connection_count(event_id) == 0:
            return

        since = self._report_checkpoints.get(sector_id)
        checkpoint = datetime.now(timezone.utc)
        async with self._pool.acquire() as conn:
            rows = await reports_repo.get_for_sector(conn, sector_id, since)
        self._report_checkpoints[sector_id] = checkpoint

        if not rows:
            return
        await self._manager.broadcast(
            event_id,
            {
                "type": "report_delta",
                "sector_id": str(sector_id),
                "reports": [ReportOut(**asdict(r)).model_dump(mode="json") for r in rows],
            },
        )
