"""Shared FastAPI dependencies."""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Annotated, AsyncIterator

import asyncpg
from fastapi import Depends
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer

from .. import db
from ..config import Settings, get_settings
from ..errors import Forbidden, Unauthorized
from ..repositories import memberships as memberships_repo
from ..repositories import sectors as sectors_repo
from ..repositories import users as users_repo
from ..security.tokens import SessionClaims, decode_account_token, decode_session_token

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


@dataclass(frozen=True, slots=True)
class ActiveSession:
    """A session token whose claims have just been re-validated against the
    live database -- never trust `SessionClaims` alone for authorization."""

    claims: SessionClaims
    sector: sectors_repo.Sector
    membership: memberships_repo.Membership


async def current_membership(
    settings: SettingsDep,
    conn: ConnDep,
    credentials: Annotated[HTTPAuthorizationCredentials | None, Depends(_bearer)],
) -> ActiveSession:
    """Validate a session token AND re-check it against current server state.

    The JWT signature alone only proves the token hasn't been tampered with --
    it says nothing about whether the membership was revoked, the event ended,
    or the sector re-keyed *after* the token was issued. All three must be
    checked on every call, which is why this hits the database instead of
    trusting the decoded claims outright:

      * `key_epoch` mismatch  -> the sector was re-keyed (future revocation
        mechanism, parked as P1); every old session token dies at once.
      * membership.status != 'approved' -> revoked, rejected, or the event
        ended and swept every membership to 'ended' (Q9 teardown).
      * session_expires_at elapsed -> the client-side hard-expiry mirror,
        enforced server-side too so a device with a wrong clock can't extend
        its own session by refusing to self-terminate.
      * sector.status == 'closed' -> belt-and-braces for teardown.
    """
    if credentials is None:
        raise Unauthorized("missing bearer token")

    claims = decode_session_token(settings, credentials.credentials)

    membership = await memberships_repo.get(conn, claims.membership_id)
    if membership is None or membership.status != "approved":
        raise Unauthorized("session is no longer valid")
    if (
        membership.user_id != claims.user_id
        or membership.device_id != claims.device_id
        or membership.sector_id != claims.sector_id
    ):
        raise Unauthorized("session no longer matches its membership")

    now = datetime.now(timezone.utc)
    if membership.session_expires_at is not None and membership.session_expires_at <= now:
        raise Unauthorized("session has expired")

    sector = await sectors_repo.get(conn, claims.sector_id)
    if sector is None or sector.status == "closed":
        raise Unauthorized("sector is no longer active")

    if sector.key_epoch != claims.key_epoch:
        raise Unauthorized("session key has been rotated; re-join required")

    return ActiveSession(claims=claims, sector=sector, membership=membership)


CurrentSession = Annotated[ActiveSession, Depends(current_membership)]
