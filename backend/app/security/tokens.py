"""JWT issuance and verification.

Phase 1 issues only the *account* token, which proves "this phone number is
mine". It deliberately carries no sector, no role, and no key material.

Phase 2 will add a separate *session* token scoped to a single sector
membership, carrying `key_epoch` and the `session_expires_at` that backs the
offline hard-expiry teardown rule.
"""

from __future__ import annotations

import uuid
from datetime import datetime, timedelta, timezone

import jwt

from ..config import Settings
from ..errors import Unauthorized

TOKEN_TYPE_ACCOUNT = "account"


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
