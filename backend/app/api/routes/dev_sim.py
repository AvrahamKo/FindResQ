"""Development-only simulator support: virtual field units that exercise the
REAL ingest pipeline without physical devices.

=============================================================================
SECURITY: this router is registered ONLY when `settings.is_local`.
=============================================================================
Every endpoint here is a deliberate backdoor -- it mints Ed25519 device
identities, self-approves sector memberships and issues session tokens with
no proof of possession whatsoever. That is exactly what makes it useful for
simulation and exactly what makes it catastrophic in a deployment. The gate
lives in `main.py` (the router is not even included outside local) AND is
re-asserted at request time by `_require_local`, so removing one of the two
by accident still fails closed. `test_dev_sim_routes.py` asserts both.

WHY THE PACKET ENCODING LIVES HERE, IN PYTHON, AND NOT IN THE SIMULATOR'S
JAVASCRIPT:
`/ingest` accepts XChaCha20-Poly1305-encrypted, Ed25519-signed 27-byte
payloads. A browser-side simulator would therefore need its own
implementation of the wire format and both crypto primitives -- a THIRD
independent implementation alongside the Python backend and the Dart client,
with no interop test holding it to the other two. This codebase's governing
rule is that crypto and the wire format are never reimplemented (see
HANDOVER's "real libsodium on both ends" section). So the simulator's
browser code stays crypto-free: it asks this module to encode points, gets
opaque base64 blobs back, and POSTs them to the real `/ingest` itself. The
encoding path below is literally `wire_format.pack` + `mesh_crypto.encrypt`,
the same functions the ingest pipeline decodes with, so drift is impossible
by construction.

The simulator client still makes a genuine `POST /ingest` with a genuine
session token -- this module never forwards packets on its behalf -- so the
route's auth, validation and the full 11-stage pipeline are all exercised
for real.
"""

from __future__ import annotations

import base64
import logging
import uuid
from datetime import datetime, timedelta, timezone

from fastapi import APIRouter, status
from nacl.signing import SigningKey
from pydantic import BaseModel, Field

from ..deps import ConnDep, SettingsDep
from ...config import Settings
from ...errors import Forbidden, NotFound
from ...mesh import report_format, wire_format
from ...repositories import devices as devices_repo
from ...repositories import events as events_repo
from ...repositories import memberships as memberships_repo
from ...repositories import sector_keys as sector_keys_repo
from ...repositories import sectors as sectors_repo
from ...security import envelope, mesh_crypto
from ...security.tokens import issue_session_token

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/dev/sim", tags=["dev-sim"])

SIM_LABEL = "[SIM]"
"""Marks every row this module creates, so `DELETE /dev/sim/units` can clean
up without guessing and a human reading the database can tell simulated
traffic from real traffic at a glance."""

_SESSION_TTL_HOURS = 12


def _require_local(settings: Settings) -> None:
    """Defence in depth: `main.py` already refuses to register this router
    outside local, so reaching this check at all means that gate was removed
    or bypassed."""
    if not settings.is_local:
        raise Forbidden("the simulator API is available only in local development")


# In-process registry of simulated units. Deliberately NOT persisted: the raw
# device signing keys and sector key live here only, and a process restart
# should invalidate them rather than leave usable credentials on disk. The
# UI recreates its units after a backend restart.
class _SimUnit:
    def __init__(
        self,
        *,
        unit_id: str,
        name: str,
        user_id: uuid.UUID,
        device_id: uuid.UUID,
        wire_id: int,
        sector_id: uuid.UUID,
        signing_key: SigningKey,
        sector_key: bytes,
        session_token: str,
    ) -> None:
        self.unit_id = unit_id
        self.name = name
        self.user_id = user_id
        self.device_id = device_id
        self.wire_id = wire_id
        self.sector_id = sector_id
        self.signing_key = signing_key
        self.sector_key = sector_key
        self.session_token = session_token


_UNITS: dict[str, _SimUnit] = {}


# --- Schemas ---------------------------------------------------------------


class SimUnitCreate(BaseModel):
    name: str = Field(min_length=1, max_length=80)
    sector_id: uuid.UUID
    movement_mode: str = Field(default="walker", pattern="^(walker|vehicle)$")


class SimUnitOut(BaseModel):
    unit_id: str
    name: str
    sector_id: uuid.UUID
    device_id: uuid.UUID
    user_id: uuid.UUID
    wire_id: int
    # Handed to the simulator UI so IT can call the real /ingest, rather than
    # this module proxying packets on its behalf.
    session_token: str


class SimPoint(BaseModel):
    lat: float = Field(ge=-90, le=90)
    lng: float = Field(ge=-180, le=180)
    recorded_at_ms: int | None = None
    accuracy_m: float = Field(default=5.0, ge=0)
    speed_mps: float = Field(default=1.4, ge=0)
    battery_pct: int = Field(default=85, ge=0, le=100)

    # Defaults to False, and that is a considered choice rather than a
    # convenience. `plausibility.usability()` treats a mocked fix as
    # untrustworthy and excludes it from the swath ENTIRELY -- the point is
    # stored for audit but "contributes nothing to coverage, full stop". An
    # earlier version of this module set the flag on every simulated point
    # on the reasoning that synthetic positions should be labelled honestly;
    # the result was 22 points accepted, zero coverage hexes generated, and
    # a simulator structurally incapable of testing the thing it exists to
    # test. Set it True deliberately to exercise the EXCLUSION path instead.
    is_mocked: bool = False


class SimEncodeRequest(BaseModel):
    points: list[SimPoint] = Field(min_length=1, max_length=200)


class SimEncodeResponse(BaseModel):
    """Opaque, ready to POST to /ingest exactly as the mobile app would."""

    blobs: list[str]
    session_token: str


class SimReportRequest(BaseModel):
    kind: str
    lat: float = Field(ge=-90, le=90)
    lng: float = Field(ge=-180, le=180)
    note: str = ""


# --- Bootstrap -------------------------------------------------------------


@router.post("/units", response_model=SimUnitOut, status_code=status.HTTP_201_CREATED)
async def create_unit(
    payload: SimUnitCreate, conn: ConnDep, settings: SettingsDep
) -> SimUnitOut:
    """Provisions a complete, genuinely-credentialed field unit.

    Everything is real: a real user row, a real device with a real Ed25519
    keypair, a real approved membership, a real session token signed with the
    real JWT secret, and the sector's real unwrapped key. The only thing
    skipped is the human -- no OTP, no proof-of-possession challenge, no
    Lead approving the join. That shortcut is the entire reason this router
    must never leave local.
    """
    _require_local(settings)

    swe = await sectors_repo.get_with_event(conn, payload.sector_id)
    if swe is None:
        raise NotFound("sector not found")

    event = await events_repo.get(conn, swe.sector.event_id)
    if event is None:
        raise NotFound("event not found")

    signing_key = SigningKey.generate()

    async with conn.transaction():
        user_id = await conn.fetchval(
            "INSERT INTO users (phone_e164, display_name) VALUES ($1, $2) RETURNING id",
            # Reserved test range, so a simulated unit can never collide with
            # (or be mistaken for) a real volunteer's number.
            f"+1555{uuid.uuid4().int % 10_000_000:07d}",
            f"{SIM_LABEL} {payload.name}",
        )
        device = await devices_repo.create(
            conn,
            user_id=user_id,
            public_key=bytes(signing_key.verify_key),
            platform="android",
            mesh_capable=False,
            label=f"{SIM_LABEL} {payload.name}",
        )
        membership = await memberships_repo.create_pending(
            conn,
            sector_id=swe.sector.id,
            user_id=user_id,
            device_id=device.id,
            movement_mode=payload.movement_mode,
            battery_at_join=90,
            powerbank_attested=True,
        )
        expires_at = datetime.now(timezone.utc) + timedelta(hours=_SESSION_TTL_HOURS)
        approved = await memberships_repo.approve(
            conn,
            membership.id,
            approved_by=user_id,
            key_epoch=swe.sector.key_epoch,
            session_expires_at=expires_at,
        )

    key_row = await sector_keys_repo.get(conn, swe.sector.id, swe.sector.key_epoch)
    if key_row is None:
        raise NotFound("sector has no key material")
    sector_key = envelope.unwrap(settings.sector_key_wrap_secret, key_row.key_wrapped)

    token = issue_session_token(
        settings,
        user_id=user_id,
        device_id=device.id,
        sector_id=swe.sector.id,
        membership_id=approved.id,
        role=approved.role,
        key_epoch=swe.sector.key_epoch,
        movement_mode=payload.movement_mode,
        expires_at=expires_at,
    )

    unit_id = uuid.uuid4().hex[:12]
    _UNITS[unit_id] = _SimUnit(
        unit_id=unit_id,
        name=payload.name,
        user_id=user_id,
        device_id=device.id,
        wire_id=device.wire_id,
        sector_id=swe.sector.id,
        signing_key=signing_key,
        sector_key=sector_key,
        session_token=token,
    )
    logger.info(
        "[dev-sim] unit created name=%s device_id=%s sector_id=%s",
        payload.name, device.id, swe.sector.id,
    )
    return SimUnitOut(
        unit_id=unit_id,
        name=payload.name,
        sector_id=swe.sector.id,
        device_id=device.id,
        user_id=user_id,
        wire_id=device.wire_id,
        session_token=token,
    )


@router.get("/units", response_model=list[SimUnitOut])
async def list_units(settings: SettingsDep) -> list[SimUnitOut]:
    _require_local(settings)
    return [
        SimUnitOut(
            unit_id=u.unit_id,
            name=u.name,
            sector_id=u.sector_id,
            device_id=u.device_id,
            user_id=u.user_id,
            wire_id=u.wire_id,
            session_token=u.session_token,
        )
        for u in _UNITS.values()
    ]


def _unit_or_404(unit_id: str) -> _SimUnit:
    unit = _UNITS.get(unit_id)
    if unit is None:
        # Also the post-restart case: the registry is in-process only.
        raise NotFound("simulated unit not found (was the backend restarted?)")
    return unit


# --- Encoding --------------------------------------------------------------


@router.post("/units/{unit_id}/encode-points", response_model=SimEncodeResponse)
async def encode_points(
    unit_id: str, payload: SimEncodeRequest, settings: SettingsDep
) -> SimEncodeResponse:
    """Turns plain lat/lng into real signed+encrypted ingest blobs.

    This is the whole reason the simulator has a Python half. The three lines
    that matter are identical to what the Dart client does and to what
    `tests/test_ingest_pipeline_db.py` does:

        packed    = wire_format.pack(payload)
        signature = signing_key.sign(packed).signature
        blob      = mesh_crypto.encrypt(sector_key, packed + signature)

    The caller POSTs the result to /ingest itself.
    """
    _require_local(settings)
    unit = _unit_or_404(unit_id)

    now_ms = int(datetime.now(timezone.utc).timestamp() * 1000)
    blobs: list[str] = []
    for point in payload.points:
        packed = wire_format.pack(
            wire_format.PointPayload(
                wire_id=unit.wire_id,
                recorded_at_ms=point.recorded_at_ms or now_ms,
                lat=point.lat,
                lng=point.lng,
                accuracy_m=point.accuracy_m,
                speed_mps=point.speed_mps,
                battery_pct=point.battery_pct,
                # See SimPoint.is_mocked -- False by default so simulated
                # traffic actually reaches the coverage ledger.
                is_mocked=point.is_mocked,
            )
        )
        signature = unit.signing_key.sign(packed).signature
        blobs.append(base64.b64encode(mesh_crypto.encrypt(unit.sector_key, packed + signature)).decode())

    return SimEncodeResponse(blobs=blobs, session_token=unit.session_token)


@router.post("/units/{unit_id}/encode-report", response_model=SimEncodeResponse)
async def encode_report(
    unit_id: str, payload: SimReportRequest, settings: SettingsDep
) -> SimEncodeResponse:
    """Same idea for field reports, using the variable-length report format."""
    _require_local(settings)
    unit = _unit_or_404(unit_id)

    packed = report_format.pack(
        report_format.ReportPayload(
            wire_id=unit.wire_id,
            recorded_at_ms=int(datetime.now(timezone.utc).timestamp() * 1000),
            kind=payload.kind,
            lat=payload.lat,
            lng=payload.lng,
            note=payload.note,
        )
    )
    signature = unit.signing_key.sign(packed).signature
    blob = base64.b64encode(mesh_crypto.encrypt(unit.sector_key, packed + signature)).decode()
    return SimEncodeResponse(blobs=[blob], session_token=unit.session_token)


# --- Teardown --------------------------------------------------------------


@router.delete("/units", status_code=status.HTTP_200_OK)
async def delete_all_units(conn: ConnDep, settings: SettingsDep) -> dict:
    """Removes every simulated unit and the traffic it generated.

    Ordered to respect foreign keys, and scoped strictly to rows this module
    created (matched by the SIM_LABEL on the device) so it can never touch
    real volunteer data.
    """
    _require_local(settings)

    async with conn.transaction():
        device_ids = [
            r["id"]
            for r in await conn.fetch(
                "SELECT id FROM devices WHERE label LIKE $1", f"{SIM_LABEL}%"
            )
        ]
        if device_ids:
            await conn.execute("DELETE FROM sos_alerts WHERE device_id = ANY($1::uuid[])", device_ids)
            await conn.execute("DELETE FROM reports WHERE device_id = ANY($1::uuid[])", device_ids)
            await conn.execute("DELETE FROM hex_contributions WHERE device_id = ANY($1::uuid[])", device_ids)
            await conn.execute("DELETE FROM track_points WHERE device_id = ANY($1::uuid[])", device_ids)
            await conn.execute("DELETE FROM device_presence WHERE device_id = ANY($1::uuid[])", device_ids)
            await conn.execute("DELETE FROM track_segments WHERE device_id = ANY($1::uuid[])", device_ids)
            await conn.execute("DELETE FROM sector_memberships WHERE device_id = ANY($1::uuid[])", device_ids)
            await conn.execute("DELETE FROM devices WHERE id = ANY($1::uuid[])", device_ids)
            await conn.execute(
                "DELETE FROM users WHERE display_name LIKE $1", f"{SIM_LABEL}%"
            )

    removed = len(_UNITS)
    _UNITS.clear()
    logger.info("[dev-sim] cleared %d unit(s), %d device row(s)", removed, len(device_ids))
    return {"units_cleared": removed, "devices_deleted": len(device_ids)}
