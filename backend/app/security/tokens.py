"""JWT issuance and verification.

Two token types, kept deliberately separate:

* **account** (Phase 1) proves "this phone number is mine". No sector, no
  role, no key material. Long-lived, reusable across every event a volunteer
  ever joins.
* **session** (Phase 2) proves "this device holds an approved membership in
  this sector, as of this key epoch". Scoped to one `sector_memberships` row.

The session token carries `key_epoch` and `membership_id`, but deliberately
NOT the raw sector key -- that would put live decryption key material inside
a bearer token that rides on every request and lands in access logs. The raw
key is instead handed to the device exactly once, over TLS, at claim time
(see routes/memberships.py `claim_session`), for storage in Secure Storage.

`current_membership` in api/deps.py re-checks the token's claims against the
live `sector_memberships` and `sectors` rows on every request. That is what
makes revocation and re-keying (bumping `sectors.key_epoch`) take effect
immediately, despite the JWT itself being stateless and unexpired.
"""

from __future__ import annotations

import uuid
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone

import jwt

from ..config import Settings
from ..errors import Unauthorized

TOKEN_TYPE_ACCOUNT = "account"
TOKEN_TYPE_SESSION = "session"


def issue_account_token(settings: Settings, user_id: uuid.UUID) -> tuple[str, datetime]:
    now = datetime.now(timezone.utc)
    expires_at = now + timedelta(minutes=settings.account_token_ttl_minutes)
    payload = {
        "sub": str(user_id),
        "typ": TOKEN_TYPE_ACCOUNT,
        "iss": settings.jwt_issuer,
        "iat": int(now.timestamp()),
        "exp": int(expires_at.timestamp()),
        "jti": uuid.uuid4().hex,
    }
    token = jwt.encode(payload, settings.jwt_secret, algorithm=settings.jwt_algorithm)
    return token, expires_at


def decode_account_token(settings: Settings, token: str) -> uuid.UUID:
    try:
        payload = jwt.decode(
            token,
            settings.jwt_secret,
            algorithms=[settings.jwt_algorithm],
            issuer=settings.jwt_issuer,
            options={"require": ["exp", "iat", "sub", "iss"]},
        )
    except jwt.ExpiredSignatureError as exc:
        raise Unauthorized("token has expired") from exc
    except jwt.InvalidTokenError as exc:
        raise Unauthorized("token is invalid") from exc

    if payload.get("typ") != TOKEN_TYPE_ACCOUNT:
        raise Unauthorized("wrong token type for this endpoint")

    try:
        return uuid.UUID(payload["sub"])
    except (KeyError, ValueError) as exc:
        raise Unauthorized("token subject is malformed") from exc


@dataclass(frozen=True, slots=True)
class SessionClaims:
    user_id: uuid.UUID
    device_id: uuid.UUID
    sector_id: uuid.UUID
    membership_id: uuid.UUID
    role: str
    key_epoch: int
    movement_mode: str


def issue_session_token(
    settings: Settings,
    *,
    user_id: uuid.UUID,
    device_id: uuid.UUID,
    sector_id: uuid.UUID,
    membership_id: uuid.UUID,
    role: str,
    key_epoch: int,
    movement_mode: str,
    expires_at: datetime,
) -> str:
    """`movement_mode` rides in the token (Phase 3 addition) so the ingest
    pipeline knows walker-vs-vehicle radius without a membership lookup on
    every batch upload -- it's fixed for the life of a session, decided once
    at /join."""
    now = datetime.now(timezone.utc)
    payload = {
        "sub": str(user_id),
        "typ": TOKEN_TYPE_SESSION,
        "iss": settings.jwt_issuer,
        "iat": int(now.timestamp()),
        "exp": int(expires_at.timestamp()),
        "jti": uuid.uuid4().hex,
        "device_id": str(device_id),
        "sector_id": str(sector_id),
        "membership_id": str(membership_id),
        "role": role,
        "key_epoch": key_epoch,
        "movement_mode": movement_mode,
    }
    return jwt.encode(payload, settings.jwt_secret, algorithm=settings.jwt_algorithm)


def decode_session_token(settings: Settings, token: str) -> SessionClaims:
    try:
        payload = jwt.decode(
            token,
            settings.jwt_secret,
            algorithms=[settings.jwt_algorithm],
            issuer=settings.jwt_issuer,
            options={"require": ["exp", "iat", "sub", "iss"]},
        )
    except jwt.ExpiredSignatureError as exc:
        raise Unauthorized("session has expired") from exc
    except jwt.InvalidTokenError as exc:
        raise Unauthorized("session token is invalid") from exc

    if payload.get("typ") != TOKEN_TYPE_SESSION:
        raise Unauthorized("wrong token type for this endpoint")

    try:
        return SessionClaims(
            user_id=uuid.UUID(payload["sub"]),
            device_id=uuid.UUID(payload["device_id"]),
            sector_id=uuid.UUID(payload["sector_id"]),
            membership_id=uuid.UUID(payload["membership_id"]),
            role=payload["role"],
            key_epoch=int(payload["key_epoch"]),
            movement_mode=payload["movement_mode"],
        )
    except (KeyError, ValueError) as exc:
        raise Unauthorized("session token claims are malformed") from exc
