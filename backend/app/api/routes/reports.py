"""Field reports: encrypted, signed submission (same shape as `/ingest`,
same `CurrentSession` device auth), visible to any sector member (unlike
SOS's Lead/Commander-only actions -- a "subject found" or "hazard" report is
exactly the kind of thing every searcher benefits from seeing), and
acknowledgeable by a Lead/Commander as a lightweight triage signal.
"""

from __future__ import annotations

import base64
import logging
import uuid
from dataclasses import asdict

from fastapi import APIRouter, status

from ..deps import ConnDep, CurrentSession, CurrentUser, SettingsDep
from ..rbac import require_lead_or_commander
from .sectors import _require_sector_visibility
from ..schemas.reports import ReportIngestRequest, ReportIngestResponse, ReportOut
from ...errors import Conflict, NotFound, ValidationFailed
from ...reports.pipeline import ingest_reports
from ...repositories import devices as devices_repo
from ...repositories import reports as reports_repo
from ...repositories import sector_keys as sector_keys_repo
from ...security import envelope

logger = logging.getLogger(__name__)

router = APIRouter(tags=["reports"])


def _to_out(report: reports_repo.Report) -> ReportOut:
    return ReportOut(**asdict(report))


@router.post("/reports", response_model=ReportIngestResponse, status_code=status.HTTP_200_OK)
async def submit_reports(
    payload: ReportIngestRequest, session: CurrentSession, conn: ConnDep, settings: SettingsDep
) -> ReportIngestResponse:
    try:
        blobs = [base64.b64decode(b, validate=True) for b in payload.blobs]
    except Exception as exc:  # noqa: BLE001 - any malformed base64 is a client error
        raise ValidationFailed("one or more blobs are not valid base64") from exc

    device = await devices_repo.get(conn, session.claims.device_id)
    if device is None or device.revoked_at is not None:
        raise Conflict("device is no longer valid")

    key_row = await sector_keys_repo.get(conn, session.sector.id, session.sector.key_epoch)
    if key_row is None:
        raise Conflict("sector has no active key material")
    sector_key = envelope.unwrap(settings.sector_key_wrap_secret, key_row.key_wrapped)

    async with conn.transaction():
        outcome = await ingest_reports(
            conn,
            sector=session.sector,
            device_id=device.id,
            device_wire_id=device.wire_id,
            device_public_key=device.ed25519_public_key,
            user_id=session.claims.user_id,
            sector_key=sector_key,
            blobs=blobs,
        )

    logger.info(
        "reports ingested device_id=%s sector_id=%s accepted=%d duplicate=%d rejected=%d",
        device.id,
        session.sector.id,
        outcome.accepted,
        outcome.duplicate,
        outcome.decrypt_failed + outcome.signature_invalid + outcome.wrong_device + outcome.malformed,
    )
    return ReportIngestResponse(**asdict(outcome))


@router.get("/sectors/{sector_id}/reports", response_model=list[ReportOut])
async def list_reports(
    sector_id: uuid.UUID,
    user: CurrentUser,
    conn: ConnDep,
    kind: str | None = None,
) -> list[ReportOut]:
    await _require_sector_visibility(conn, sector_id, user)
    rows = await reports_repo.list_for_sector(conn, sector_id, kind=kind)
    return [_to_out(r) for r in rows]


@router.post("/reports/{report_id}/acknowledge", response_model=ReportOut)
async def acknowledge_report(report_id: uuid.UUID, user: CurrentUser, conn: ConnDep) -> ReportOut:
    existing = await reports_repo.get(conn, report_id)
    if existing is None:
        raise NotFound("report not found")
    await require_lead_or_commander(conn, existing.sector_id, user)

    report = await reports_repo.acknowledge(conn, report_id, by_user_id=user.id)
    if report is None:
        raise Conflict("this report is already acknowledged")
    logger.info("report acknowledged id=%s by=%s", report_id, user.id)
    return _to_out(report)
