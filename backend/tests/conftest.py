"""Shared fixtures.

`db_conn` connects to a real Postgres instance (the same one migrations
0001-0004 were applied to) and wraps the whole test in a transaction that is
always rolled back at teardown -- true isolation, nothing written by these
tests ever persists, and no manual cleanup is needed.

If no database is reachable, tests requesting `db_conn` are SKIPPED rather
than failed, so this suite stays green without Postgres available (as in the
sandbox this was developed in) while still providing real verification
wherever a database is present (as in the developer's own environment).
"""

from __future__ import annotations

import os

import asyncpg
import pytest
import pytest_asyncio

DATABASE_URL = os.environ.get(
    "TEST_DATABASE_URL",
    os.environ.get(
        "DATABASE_URL", "postgresql://lifesearch:lifesearch@localhost:5432/lifesearch"
    ),
)


@pytest_asyncio.fixture
async def db_conn():
    try:
        conn = await asyncpg.connect(DATABASE_URL, timeout=5)
    except (OSError, asyncpg.PostgresError) as exc:
        pytest.skip(f"no database reachable at {DATABASE_URL}: {exc}")
        return

    tx = conn.transaction()
    await tx.start()
    try:
        yield conn
    finally:
        await tx.rollback()
        await conn.close()
