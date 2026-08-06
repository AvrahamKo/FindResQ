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
from ..repositories import memberships as memberships_repo
from ..repositories import presence as presence_repo
from ..repositories import reports as reports_repo
from ..repositories import sos as sos_repo
from .manager import ConnectionManager
from .tickets import TicketStore

logger = logging.getLogger(__name__)

COVERAGE_CHANNEL = "sector_coverage_channel"
PRESENCE_CHANNEL = "sector_presence_channel"
SOS_CHANNEL = "sector_sos_channel"
REPORT_CHANNEL = "sector_report_channel"

# Phase 7 (migration 0008). Unlike the four above -- which carry a bare
# sector_id and let the handler re-query the delta -- these describe things
# that no longer exist, or access that no longer applies, so the payload
# carries the identity itself. There is nothing left to re-query.
SOS_DELETED_CHANNEL = "sector_sos_deleted_channel"        # 'sector_id:alert_id'
EVENT_DELETED_CHANNEL = "event_deleted_channel"           # 'event_id'
MEMBERSHIP_REVOKED_CHANNEL = "membership_revoked_channel"  # 'sector_id:user_id'


def _split_pair(payload: str) -> tuple[uuid.UUID, uuid.UUID]:
    left, _, right = payload.partition(":")
    return uuid.UUID(left), uuid.UUID(right)


class RealtimeListener:
    def __init__(
        self,
        database_url: str,
        pool: asyncpg.Pool,
        manager: ConnectionManager,
        tickets: TicketStore | None = None,
    ) -> None:
        self._database_url = database_url
        self._pool = pool
        self._manager = manager
        self._tickets = tickets
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
        await self._conn.add_listener(SOS_DELETED_CHANNEL, self._on_sos_deleted_notify)
        await self._conn.add_listener(EVENT_DELETED_CHANNEL, self._on_event_deleted_notify)
        await self._conn.add_listener(
            MEMBERSHIP_REVOKED_CHANNEL, self._on_membership_revoked_notify
        )
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

    def _on_sos_deleted_notify(self, connection, pid, channel, payload: str) -> None:
        sector_id, alert_id = _split_pair(payload)
        asyncio.create_task(self._safe(self._handle_sos_deleted, sector_id, alert_id))

    def _on_event_deleted_notify(self, connection, pid, channel, payload: str) -> None:
        asyncio.create_task(self._safe(self._handle_event_deleted, uuid.UUID(payload)))

    def _on_membership_revoked_notify(self, connection, pid, channel, payload: str) -> None:
        sector_id, user_id = _split_pair(payload)
        asyncio.create_task(self._safe(self._handle_membership_revoked, sector_id, user_id))

    async def _safe(self, handler, *args) -> None:
        try:
            await handler(*args)
        except Exception:
            logger.exception("realtime handler %s failed for %s", handler.__name__, args)

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

    # ---- Phase 7: removals ------------------------------------------------

    async def _handle_sos_deleted(self, sector_id: uuid.UUID, alert_id: uuid.UUID) -> None:
        """An alert was cleared. There is no delta query that can produce a
        row which no longer exists, so this forwards the id straight through
        and the client removes it locally."""
        event_id = await self._event_id_for_sector(sector_id)
        if event_id is None or self._manager.connection_count(event_id) == 0:
            # The sector may itself have been cascade-deleted (an event
            # teardown deletes its alerts too), in which case the
            # `event_deleted` broadcast below already told everyone.
            return
        await self._manager.broadcast(
            event_id,
            {
                "type": "sos_deleted",
                "sector_id": str(sector_id),
                "alert_id": str(alert_id),
            },
        )

    async def _handle_event_deleted(self, event_id: uuid.UUID) -> None:
        """Tells every dashboard the event is gone, hangs up their sockets,
        and drops the process-local state that referenced it.

        The checkpoint dicts are the subtle part: they are keyed by
        sector_id and nothing in the normal flow ever removes an entry, so
        without this every deleted sector would leave a permanent
        `{uuid: datetime}` pair in four separate dicts for the lifetime of
        the process. Rather than track which sectors belonged to which event
        (a second copy of state the database already owns, and one that is
        unreadable by the time this runs), the pruning asks Postgres which
        of the sector ids it is holding still exist and drops the rest --
        self-healing, and correct even for a sector deleted some other way.
        """
        closed = await self._manager.close_event(
            event_id, {"type": "event_deleted", "event_id": str(event_id)}
        )
        if self._tickets is not None:
            self._tickets.purge_event(event_id)
        pruned = await self._prune_dead_sector_checkpoints()
        logger.info(
            "event deleted id=%s: closed %d socket(s), pruned %d sector checkpoint(s)",
            event_id, closed, pruned,
        )

    async def _handle_membership_revoked(
        self, sector_id: uuid.UUID, user_id: uuid.UUID
    ) -> None:
        """A membership hit a terminal status. If that leaves the user with
        no remaining access to the event, cut their live connection now.

        The re-check matters: a volunteer removed from Sector A while still
        approved in Sector B has not lost access to the event, and hanging
        up on them would be a bug, not a security win. Same for the
        Commander, who is authorized by `events.commander_id` and needs no
        membership at all.
        """
        event_id = await self._event_id_for_sector(sector_id)
        if event_id is None:
            return

        async with self._pool.acquire() as conn:
            still_has_access = await conn.fetchval(
                """
                SELECT EXISTS (SELECT 1 FROM events
                               WHERE id = $1 AND commander_id = $2)
                    OR EXISTS (SELECT 1 FROM sector_memberships m
                               JOIN sectors s ON s.id = m.sector_id
                               WHERE s.event_id = $1 AND m.user_id = $2
                                 AND m.status = ANY($3::text[]))
                """,
                event_id,
                user_id,
                list(memberships_repo.VISIBILITY_STATUSES),
            )
        if still_has_access:
            return

        if self._tickets is not None:
            self._tickets.purge_user(user_id, event_id)
        closed = await self._manager.disconnect_user(
            event_id,
            user_id,
            {"type": "access_revoked", "event_id": str(event_id)},
        )
        if closed:
            logger.info(
                "access revoked user_id=%s event_id=%s: closed %d socket(s)",
                user_id, event_id, closed,
            )

    async def _prune_dead_sector_checkpoints(self) -> int:
        checkpoints = (
            self._coverage_checkpoints,
            self._presence_checkpoints,
            self._sos_checkpoints,
            self._report_checkpoints,
        )
        known: set[uuid.UUID] = set()
        for book in checkpoints:
            known.update(book)
        if not known:
            return 0

        async with self._pool.acquire() as conn:
            rows = await conn.fetch(
                "SELECT id FROM sectors WHERE id = ANY($1::uuid[])", list(known)
            )
        alive = {row["id"] for row in rows}
        dead = known - alive
        for book in checkpoints:
            for sector_id in dead:
                book.pop(sector_id, None)
        return len(dead)
