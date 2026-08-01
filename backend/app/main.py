"""LifeSearch API entry point."""

from __future__ import annotations

import logging
from contextlib import asynccontextmanager
from typing import AsyncIterator

from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse

from . import db
from .api.routes import auth, devices, health
from .config import get_settings
from .errors import AppError

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)-8s %(name)s: %(message)s",
)
logger = logging.getLogger(__name__)


@asynccontextmanager
async def lifespan(app: FastAPI) -> AsyncIterator[None]:
    settings = get_settings()
    await db.connect(settings)
    logger.info("LifeSearch API started (env=%s)", settings.env)
    try:
        yield
    finally:
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
    allow_origins=["http://localhost:5173"] if get_settings().is_local else [],
    allow_credentials=True,
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
