"""Phone-number authentication via one-time passcode.

Phase 1 scope: prove control of a phone number and mint an account token. No
sector, no role, no key material -- those arrive in Phase 2.
"""

from __future__ import annotations

import logging
from datetime import datetime, timezone

from fastapi import APIRouter, status

from ...errors import RateLimited, Unauthorized
from ...repositories import users as users_repo
from ...security import otp
from ...security.tokens import issue_account_token
from ..deps import ConnDep, CurrentUser, SettingsDep
from ..schemas.auth import (
    AuthTokenResponse,
    OtpRequest,
    OtpRequestResponse,
    OtpVerify,
    UserOut,
)

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/auth", tags=["auth"])


@router.post("/otp/request", response_model=OtpRequestResponse)
async def request_otp(
    payload: OtpRequest, settings: SettingsDep, conn: ConnDep
) -> OtpRequestResponse:
    elapsed = await users_repo.seconds_since_last_challenge(conn, payload.phone_e164)
    if elapsed is not None and elapsed < settings.otp_resend_cooldown_seconds:
        raise RateLimited(
            f"wait {int(settings.otp_resend_cooldown_seconds - elapsed)}s "
            "before requesting another code"
        )

    code = otp.generate_code()
    salt = otp.generate_salt()
    challenge = await users_repo.create_otp_challenge(
        conn,
        phone_e164=payload.phone_e164,
        salt=salt,
        code_hash=otp.hash_code(code, salt),
        ttl_seconds=settings.otp_ttl_seconds,
    )

    if settings.is_local:
        # Local only. An SMS provider replaces this in Phase 2.
        logger.warning("DEV OTP for %s: %s", payload.phone_e164, code)

    return OtpRequestResponse(
        challenge_id=challenge.id,
        expires_at=challenge.expires_at,
        dev_code=code if settings.is_local else None,
    )


@router.post("/otp/verify", response_model=AuthTokenResponse)
async def verify_otp(
    payload: OtpVerify, settings: SettingsDep, conn: ConnDep
) -> AuthTokenResponse:
    async with conn.transaction():
        challenge = await users_repo.lock_otp_challenge(conn, payload.challenge_id)

        # One opaque error for every rejection path: a caller must not be able
        # to distinguish "no such challenge" from "wrong code" from "expired".
        if challenge is None:
            raise Unauthorized("invalid or expired code")
        if challenge.consumed_at is not None:
            raise Unauthorized("invalid or expired code")
        if challenge.expires_at <= datetime.now(timezone.utc):
            raise Unauthorized("invalid or expired code")
        if challenge.attempts >= settings.otp_max_attempts:
            raise Unauthorized("invalid or expired code")

        if not otp.verify_code(payload.code, challenge.salt, challenge.code_hash):
            attempts = await users_repo.record_failed_attempt(conn, challenge.id)
            if attempts >= settings.otp_max_attempts:
                await users_repo.consume_otp_challenge(conn, challenge.id)
            raise Unauthorized("invalid or expired code")

        await users_repo.consume_otp_challenge(conn, challenge.id)

        display_name = payload.display_name or challenge.phone_e164
        user, created = await users_repo.upsert_by_phone(
            conn, challenge.phone_e164, display_name
        )

    logger.info("otp verified user_id=%s created=%s", user.id, created)

    token, expires_at = issue_account_token(settings, user.id)
    return AuthTokenResponse(
        access_token=token,
        expires_at=expires_at,
        user=UserOut(
            id=user.id,
            phone_e164=user.phone_e164,
            display_name=user.display_name,
            verification_status=user.verification_status,
            verified_org=user.verified_org,
        ),
    )


@router.get("/me", response_model=UserOut, status_code=status.HTTP_200_OK)
async def me(user: CurrentUser) -> UserOut:
    return UserOut(
        id=user.id,
        phone_e164=user.phone_e164,
        display_name=user.display_name,
        verification_status=user.verification_status,
        verified_org=user.verified_org,
    )
