"""LifeSearch API entry point."""

from __future__ import annotations

import asyncio
import logging
from contextlib import asynccontextmanager
from pathlib import Path
from typing import AsyncIterator

from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from fastapi.staticfiles import StaticFiles

from . import db
from .api.routes import (
    auth,
    coverage,
    devices,
    events,
    health,
    ingest,
    memberships,
    presence,
    reports,
    sectors,
    sos,
    ws,
)
from .config import get_settings
from .errors import AppError
from .presence.sweep import sweep_all_open_sectors
from .realtime.listener import RealtimeListener
from .realtime.manager import ConnectionManager
from .realtime.tickets import TicketStore

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)-8s %(name)s: %(message)s",
)
logger = logging.getLogger(__name__)


async def _presence_sweep_loop(interval_seconds: int) -> None:
    while True:
        try:
            async with db.get_pool().acquire() as conn:
                changed = await sweep_all_open_sectors(conn)
            if changed:
                logger.info("presence sweep: %d device(s) changed state", changed)
        except asyncio.CancelledError:
            raise
        except Exception:
            logger.exception("presence sweep tick failed")
        await asyncio.sleep(interval_seconds)


@asynccontextmanager
async def lifespan(app: FastAPI) -> AsyncIterator[None]:
    settings = get_settings()
    pool = await db.connect(settings)

    app.state.connection_manager = ConnectionManager()
    app.state.ticket_store = TicketStore()

    listener = RealtimeListener(settings.database_url, pool, app.state.connection_manager)
    await listener.start()

    sweep_task = asyncio.create_task(
        _presence_sweep_loop(settings.presence_sweep_interval_seconds)
    )

    logger.info("LifeSearch API started (env=%s)", settings.env)
    try:
        yield
    finally:
        sweep_task.cancel()
        try:
            await sweep_task
        except asyncio.CancelledError:
            pass
        await listener.stop()
        await db.disconnect()


app = FastAPI(
    title="LifeSearch API",
    version="0.1.0",
    summary="Search & rescue coordination backend",
    lifespan=lifespan,
    # The dashboard is the only browser client; the mobile app is not
    # same-origin constrained. Lock this down properly in Phase 4.
    docs_url="/docs" if get_settings().is_local else None,
    redoc_url=None,
)

app.add_middleware(
    CORSMiddleware,
    # Wide open in local dev: a native desktop/mobile client isn't subject to
    # CORS at all (no browser involved), but `flutter run -d chrome` and the
    # web dashboard both are, and Flutter's web dev server picks a random
    # port per run -- there is no fixed origin to allowlist here that
    # wouldn't need updating every time. Locked down to real origins before
    # any non-local deployment.
    #
    # allow_credentials is deliberately False: this API authenticates via an
    # `Authorization: Bearer` header, never cookies, so there is no need for
    # CORS "credentials" mode -- and `allow_origins=["*"]` combined with
    # allow_credentials=True is invalid per the CORS spec anyway (browsers
    # reject a wildcard origin on any credentialed request), so turning it
    # on here would silently produce a config that looks fine but fails in
    # a real browser.
    allow_origins=["*"] if get_settings().is_local else [],
    allow_credentials=False,
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.exception_handler(AppError)
async def handle_app_error(request: Request, exc: AppError) -> JSONResponse:
    return JSONResponse(
        status_code=exc.status_code,
        content={"error": {"code": exc.code, "message": exc.message}},
    )


app.include_router(health.router)
app.include_router(auth.router)
app.include_router(devices.router)
app.include_router(events.router)
app.include_router(sectors.router)
app.include_router(memberships.router)
app.include_router(ingest.router)
app.include_router(coverage.router)
app.include_router(presence.router)
app.include_router(sos.router)
app.include_router(reports.router)
app.include_router(ws.router)

# Phase 6c: the Commander Dashboard is a plain HTML/JS/Leaflet SPA (no build
# step) served straight off this API, same-origin -- consistent with the
# CORS comment above that the dashboard is the only browser client this
# backend ever expects. It talks to the REST/WS routes above like any other
# client, nothing dashboard-specific exists server-side beyond serving these
# static files.
app.mount(
    "/dashboard",
    StaticFiles(directory=Path(__file__).resolve().parent.parent / "dashboard", html=True),
    name="dashboard",
)
