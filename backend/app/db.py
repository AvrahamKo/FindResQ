"""asyncpg connection pool lifecycle.

One pool per process, created on startup and closed on shutdown. Handlers never
touch the pool directly -- they take a connection via the `get_conn` dependency,
which guarantees it is returned even when the handler raises.
"""

from __future__ import annotations

import logging

import asyncpg

from .config import Settings

logger = logging.getLogger(__name__)

_pool: asyncpg.Pool | None = None


async def connect(settings: Settings) -> asyncpg.Pool:
    global _pool
    if _pool is not None:
        return _pool

    _pool = await asyncpg.create_pool(
        dsn=settings.database_url,
        min_size=settings.db_pool_min_size,
        max_size=settings.db_pool_max_size,
        command_timeout=30,
        # Statement caching interacts badly with connection poolers such as
        # PgBouncer in transaction mode. Revisit if one is introduced.
        max_inactive_connection_lifetime=300,
    )
    logger.info(
        "database pool ready (min=%d max=%d)",
        settings.db_pool_min_size,
        settings.db_pool_max_size,
    )
    return _pool


async def disconnect() -> None:
    global _pool
    if _pool is not None:
        await _pool.close()
        _pool = None
        logger.info("database pool closed")


def get_pool() -> asyncpg.Pool:
    if _pool is None:
        raise RuntimeError("Database pool is not initialised.")
    return _pool


async def healthcheck() -> bool:
    try:
        async with get_pool().acquire() as conn:
            return await conn.fetchval("SELECT 1") == 1
    except Exception:  # noqa: BLE001 - health probe must never propagate
        logger.exception("database healthcheck failed")
        return False
