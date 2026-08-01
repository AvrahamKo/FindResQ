from __future__ import annotations

from fastapi import APIRouter, Response, status

from ... import db

router = APIRouter(tags=["health"])


@router.get("/healthz")
async def liveness() -> dict[str, str]:
    """Process is up. Deliberately does not touch the database."""
    return {"status": "ok"}


@router.get("/readyz")
async def readiness(response: Response) -> dict[str, str]:
    """Ready to serve traffic, i.e. the database answers."""
    if not await db.healthcheck():
        response.status_code = status.HTTP_503_SERVICE_UNAVAILABLE
        return {"status": "degraded", "database": "unreachable"}
    return {"status": "ok", "database": "ok"}
