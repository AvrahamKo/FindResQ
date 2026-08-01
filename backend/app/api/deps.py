"""Shared FastAPI dependencies."""

from __future__ import annotations

from typing import Annotated, AsyncIterator

import asyncpg
from fastapi import Depends
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer

from .. import db
from ..config import Settings, get_settings
from ..errors import Forbidden, Unauthorized
from ..repositories import users as users_repo
from ..security.tokens import decode_account_token

_bearer = HTTPBearer(auto_error=False)


async def get_conn() -> AsyncIterator[asyncpg.Connection]:
    async with db.get_pool().acquire() as conn:
        yield conn


SettingsDep = Annotated[Settings, Depends(get_settings)]
ConnDep = Annotated[asyncpg.Connection, Depends(get_conn)]


async def current_user(
    settings: SettingsDep,
    conn: ConnDep,
    credentials: Annotated[HTTPAuthorizationCredentials | None, Depends(_bearer)],
) -> users_repo.User:
    if credentials is None:
        raise Unauthorized("missing bearer token")

    user_id = decode_account_token(settings, credentials.credentials)
    user = await users_repo.get_by_id(conn, user_id)

    # The token may outlive the account it names.
    if user is None:
        raise Unauthorized("token subject no longer exists")
    if user.disabled_at is not None:
        raise Forbidden("account is disabled")
    return user


CurrentUser = Annotated[users_repo.User, Depends(current_user)]
