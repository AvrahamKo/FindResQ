"""Device enrolment: binding an Ed25519 public key to a user account.

Two-step, because the binding must be proof-of-possession (see 0002_auth.sql):

  1. POST /devices/key-challenge  -> server returns a random nonce
  2. POST /devices                -> device returns {public_key, signature(nonce)}

The server verifies the signature against the *submitted* key before storing it.
An attacker who submits someone else's public key cannot produce the signature,
so the key never gets bound to the wrong account.
"""

from __future__ import annotations

import base64
import logging
import uuid

import asyncpg
from fastapi import APIRouter, status

from ...errors import Conflict, NotFound, Unauthorized, ValidationFailed
from ...repositories import devices as devices_repo
from ...security import signatures
from ..deps import ConnDep, CurrentUser, SettingsDep
from ..schemas.devices import (
    DeviceOut,
    DeviceRegister,
    KeyChallengeResponse,
)

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/devices", tags=["devices"])


def _to_out(device: devices_repo.Device) -> DeviceOut:
    return DeviceOut(
        id=device.id,
        wire_id=device.wire_id,
        public_key=signatures.encode_public_key(device.ed25519_public_key),
        platform=device.platform,  # type: ignore[arg-type]
        mesh_capable=device.mesh_capable,
        label=device.label,
        registered_at=device.registered_at,
        revoked_at=device.revoked_at,
    )


@router.post(
    "/key-challenge",
    response_model=KeyChallengeResponse,
    status_code=status.HTTP_201_CREATED,
)
async def create_key_challenge(
    user: CurrentUser, settings: SettingsDep, conn: ConnDep
) -> KeyChallengeResponse:
    challenge = await devices_repo.create_key_challenge(
        conn, user.id, settings.device_challenge_ttl_seconds
    )
    return KeyChallengeResponse(
        challenge_id=challenge.id,
        nonce=base64.b64encode(challenge.nonce).decode("ascii"),
        expires_at=challenge.expires_at,
    )


@router.post("", response_model=DeviceOut, status_code=status.HTTP_201_CREATED)
async def register_device(
    payload: DeviceRegister, user: CurrentUser, conn: ConnDep
) -> DeviceOut:
    try:
        public_key = signatures.decode_public_key(payload.public_key)
        signature = signatures.decode_signature(payload.signature)
    except signatures.InvalidKeyEncoding as exc:
        raise ValidationFailed(str(exc)) from exc

    async with conn.transaction():
        challenge = await devices_repo.claim_key_challenge(
            conn, payload.challenge_id, user.id
        )
        if challenge is None:
            raise Unauthorized("key challenge is invalid, expired, or already used")

        if not signatures.verify(public_key, challenge.nonce, signature):
            # The challenge stays consumed: a failed proof does not get retried
            # against the same nonce.
            raise Unauthorized("signature does not match the submitted public key")

        # iOS cannot advertise arbitrary BLE payloads in the background, so only
        # Android devices are eligible to relay. Decided in the architecture
        # review; the client does not get to claim this.
        mesh_capable = payload.platform == "android"

        try:
            device = await devices_repo.create(
                conn,
                user_id=user.id,
                public_key=public_key,
                platform=payload.platform,
                mesh_capable=mesh_capable,
                label=payload.label,
            )
        except asyncpg.UniqueViolationError as exc:
            existing = await devices_repo.get_by_public_key(conn, public_key)
            if existing is not None and existing.user_id == user.id:
                raise Conflict("this device key is already registered to you") from exc
            raise Conflict("this device key is already registered") from exc

    logger.info(
        "device registered user_id=%s device_id=%s wire_id=%s platform=%s",
        user.id,
        device.id,
        device.wire_id,
        device.platform,
    )
    return _to_out(device)


@router.get("", response_model=list[DeviceOut])
async def list_devices(user: CurrentUser, conn: ConnDep) -> list[DeviceOut]:
    devices = await devices_repo.list_for_user(conn, user.id)
    return [_to_out(d) for d in devices]


@router.delete("/{device_id}", response_model=DeviceOut)
async def revoke_device(device_id: str, user: CurrentUser, conn: ConnDep) -> DeviceOut:
    try:
        parsed = uuid.UUID(device_id)
    except ValueError as exc:
        raise ValidationFailed("device_id is not a valid UUID") from exc

    device = await devices_repo.revoke(conn, parsed, user.id)
    if device is None:
        raise NotFound("device not found")
    return _to_out(device)
