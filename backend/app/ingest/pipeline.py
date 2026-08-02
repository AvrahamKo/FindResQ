"""The ingest orchestrator: stages 3-11 for the direct-upload path.

Deliberately decoupled from FastAPI/the api package -- this module takes
plain values (sector, device identity, movement mode, the already-unwrapped
sector key), not `ActiveSession`. The route layer is responsible for
authentication and translating its session object into these arguments;
this module is just the pipeline.

Stage order, and why decrypt/dedup happens in that order specifically:
signature-based replay dedup (stage 6) can only run AFTER decryption, because
the signature lives inside the encrypted bundle -- it is not recoverable
before a packet is decrypted and its own signature verified. So every packet
is decrypted and verified independently first; only once we know each
packet's real signature can duplicates be filtered as a batch, before
segmentation ever sees them (a duplicate must not influence gap/speed
calculations as if it were new data).
"""

from __future__ import annotations

import logging
import uuid
from dataclasses import dataclass, field
from datetime import datetime, timezone

import asyncpg

from ..repositories import hex_contributions as hex_contrib_repo
from ..repositories import presence as presence_repo
from ..repositories import track_points as track_points_repo
from ..repositories.sectors import Sector
from ..security import mesh_crypto, signatures
from ..mesh import wire_format
from .coverage import polygon_geojson_to_hex_ids, select_base_pod
from .geometry import linestring_wkt, point_wkt
from .plausibility import usability
from .segmentation import PriorTail, ScoredPoint, SegmentTuning, assign_runs

logger = logging.getLogger(__name__)

_EXPECTED_PLAINTEXT_BYTES = wire_format.PAYLOAD_BYTES + signatures.ED25519_SIGNATURE_BYTES


@dataclass
class PacketOutcome:
    accepted: int = 0
    duplicate: int = 0
    decrypt_failed: int = 0
    signature_invalid: int = 0
    wrong_device: int = 0
    malformed: int = 0


@dataclass
class IngestResult:
    packets: PacketOutcome = field(default_factory=PacketOutcome)
    segments_opened: int = 0
    segments_extended: int = 0
    segments_closed: int = 0
    hexes_touched: int = 0


def _to_datetime(ms: int) -> datetime:
    return datetime.fromtimestamp(ms / 1000, tz=timezone.utc)


async def ingest_batch(
    conn: asyncpg.Connection,
    *,
    sector: Sector,
    device_id: uuid.UUID,
    device_wire_id: int,
    device_public_key: bytes,
    user_id: uuid.UUID,
    movement_mode: str,
    sector_key: bytes,
    blobs: list[bytes],
) -> IngestResult:
    outcome = PacketOutcome()
    decrypted: list[ScoredPoint] = []

    # --- Stages 3-4: decrypt, then verify Ed25519 -----------------------
    for blob in blobs:
        try:
            plaintext = mesh_crypto.decrypt(sector_key, blob)
        except mesh_crypto.MeshCryptoError:
            outcome.decrypt_failed += 1
            continue

        if len(plaintext) != _EXPECTED_PLAINTEXT_BYTES:
            outcome.malformed += 1
            continue

        payload_bytes = plaintext[: wire_format.PAYLOAD_BYTES]
        signature = plaintext[wire_format.PAYLOAD_BYTES :]

        try:
            payload = wire_format.unpack(payload_bytes)
        except wire_format.WireFormatError:
            outcome.malformed += 1
            continue

        # Direct-upload scope (see module docstring in mesh/reassembly.py):
        # a device may only upload points signed as itself.
        if payload.wire_id != device_wire_id:
            outcome.wrong_device += 1
            continue

        if not signatures.verify(device_public_key, payload_bytes, signature):
            outcome.signature_invalid += 1
            continue

        reasons = usability(
            is_mocked=payload.is_mocked,
            accuracy_m=payload.accuracy_m,
            min_accuracy_m=float(sector.min_accuracy_m),
        )
        decrypted.append(
            ScoredPoint(
                recorded_at_ms=payload.recorded_at_ms,
                lat=payload.lat,
                lng=payload.lng,
                accuracy_m=payload.accuracy_m,
                speed_reported_mps=payload.speed_mps,
                battery_pct=payload.battery_pct,
                is_mocked=payload.is_mocked,
                signature=signature,
                disqualify_reasons=reasons,
            )
        )

    if not decrypted:
        return IngestResult(packets=outcome)

    # A genuinely verified packet proves the device transmitted right now,
    # regardless of whether its content turns out to be new or a duplicate
    # resubmission -- so presence is updated from `decrypted`, before dedup
    # filtering, and unconditionally on every path past this point.
    latest = max(decrypted, key=lambda p: p.recorded_at_ms)
    await presence_repo.upsert_active(
        conn,
        sector_id=sector.id,
        device_id=device_id,
        last_point_at=_to_datetime(latest.recorded_at_ms),
        last_lat=latest.lat,
        last_lng=latest.lng,
        last_battery_pct=latest.battery_pct,
        last_delivery_path="direct",
    )

    # --- Stage 6: signature dedup, as a batch pre-filter ----------------
    existing = await conn.fetch(
        "SELECT signature FROM track_points WHERE signature = ANY($1::bytea[])",
        [p.signature for p in decrypted],
    )
    existing_sigs = {row["signature"] for row in existing}
    survivors = [p for p in decrypted if p.signature not in existing_sigs]
    outcome.duplicate = len(decrypted) - len(survivors)
    outcome.accepted = len(survivors)

    if not survivors:
        return IngestResult(packets=outcome)

    # --- Stage 8: segment assembly ---------------------------------------
    tuning = SegmentTuning(
        max_gap_seconds=sector.max_gap_seconds,
        max_gap_meters=float(sector.max_gap_meters),
        max_walker_speed_mps=float(sector.max_walker_speed_mps),
        movement_mode=movement_mode,
    )

    prior = await track_points_repo.get_open_segment_tail(conn, device_id)
    prior_tail = (
        PriorTail(
            segment_id=prior.segment_id,
            recorded_at_ms=int(prior.last_recorded_at.timestamp() * 1000),
            lat=prior.last_lat,
            lng=prior.last_lng,
        )
        if prior is not None
        else None
    )

    runs = assign_runs(survivors, tuning, prior_tail)

    result = IngestResult(packets=outcome)
    all_touched_hexes: set[int] = set()

    # Per segmentation.assign_runs' contract, only runs[0] can ever continue
    # the prior open segment. If it didn't, that segment is over and must be
    # closed explicitly -- nothing else will ever close it.
    if prior is not None and (
        not runs or runs[0].continues_segment_id != prior.segment_id
    ):
        await track_points_repo.close_segment(conn, prior.segment_id)
        result.segments_closed += 1

    radius_m = (
        float(sector.vehicle_base_radius_m)
        if movement_mode == "vehicle"
        else float(sector.walker_radius_m)
    )

    for index, run in enumerate(runs):
        if not run.is_valid:
            # A disqualified point gets its own closed, invalid segment: it
            # never resumes, and closing it immediately keeps the "one open
            # segment per device" invariant intact for whatever comes next.
            point = run.points[0]
            recorded_at = _to_datetime(point.recorded_at_ms)
            segment_id = await track_points_repo.open_segment(
                conn,
                sector_id=sector.id,
                device_id=device_id,
                user_id=user_id,
                movement_mode=movement_mode,
                is_valid=False,
                plausibility_flags=run.plausibility_flags,
                started_at=recorded_at,
                last_lat=point.lat,
                last_lng=point.lng,
            )
            inserted = await track_points_repo.insert_point(
                conn,
                segment_id=segment_id,
                sector_id=sector.id,
                device_id=device_id,
                lat=point.lat,
                lng=point.lng,
                recorded_at=recorded_at,
                accuracy_m=point.accuracy_m,
                speed_mps=point.speed_reported_mps,
                battery_pct=point.battery_pct,
                is_mocked=point.is_mocked,
                delivery_path="direct",
                hop_count=0,
                signature=point.signature,
            )
            if not inserted:
                logger.warning("race on signature dedup for device_id=%s", device_id)
            await track_points_repo.close_segment(conn, segment_id)
            result.segments_closed += 1
            continue

        is_continuation = index == 0 and run.continues_segment_id is not None and prior is not None
        anchor: tuple[float, float] | None = None

        if is_continuation:
            segment_id = prior.segment_id
            segment_started_at = prior.started_at
            anchor = (prior.last_lat, prior.last_lng)
        else:
            first_point = run.points[0]
            segment_started_at = _to_datetime(first_point.recorded_at_ms)
            segment_id = await track_points_repo.open_segment(
                conn,
                sector_id=sector.id,
                device_id=device_id,
                user_id=user_id,
                movement_mode=movement_mode,
                is_valid=True,
                plausibility_flags=run.plausibility_flags,
                started_at=segment_started_at,
                last_lat=first_point.lat,
                last_lng=first_point.lng,
            )
            result.segments_opened += 1

        for point in run.points:
            inserted = await track_points_repo.insert_point(
                conn,
                segment_id=segment_id,
                sector_id=sector.id,
                device_id=device_id,
                lat=point.lat,
                lng=point.lng,
                recorded_at=_to_datetime(point.recorded_at_ms),
                accuracy_m=point.accuracy_m,
                speed_mps=point.speed_reported_mps,
                battery_pct=point.battery_pct,
                is_mocked=point.is_mocked,
                delivery_path="direct",
                hop_count=0,
                signature=point.signature,
            )
            if not inserted:
                logger.warning("race on signature dedup for device_id=%s", device_id)

        # open_segment already accounts for the run's first point when this
        # is a fresh segment; a continuation accounts for none of them yet.
        already_counted = 0 if is_continuation else 1
        additional = len(run.points) - already_counted
        if additional > 0 or is_continuation:
            last_point = run.points[-1]
            await track_points_repo.extend_segment(
                conn,
                segment_id,
                last_recorded_at=_to_datetime(last_point.recorded_at_ms),
                last_lat=last_point.lat,
                last_lng=last_point.lng,
                additional_points=additional,
            )
        if is_continuation:
            result.segments_extended += 1

        # --- Stage 9: swath geometry (delta only) -----------------------
        coords = ([anchor] if anchor is not None else []) + [
            (p.lat, p.lng) for p in run.points
        ]
        wkt = linestring_wkt(coords) if len(coords) >= 2 else point_wkt(*coords[0])

        geojson = await track_points_repo.buffer_wkt_to_geojson(conn, wkt, radius_m)

        # --- Stage 10: hexify + ledger -----------------------------------
        hex_ids = polygon_geojson_to_hex_ids(geojson, sector.h3_resolution)
        if hex_ids:
            base_pod = select_base_pod(
                base_pod_day=sector.base_pod_day,
                base_pod_night=sector.base_pod_night,
                recorded_at_ms=run.points[0].recorded_at_ms,
            )
            await hex_contrib_repo.insert_contributions(
                conn,
                sector_id=sector.id,
                hex_ids=hex_ids,
                user_id=user_id,
                device_id=device_id,
                segment_id=segment_id,
                segment_started_at=segment_started_at,
                base_pod=base_pod,
            )
            all_touched_hexes.update(hex_ids)

        # A batch can contain more than one valid run when a gap occurs
        # mid-batch (device buffered offline, gap, then more points before
        # finally reconnecting). Per assign_runs' contract only runs[0] can
        # ever continue into a future batch -- every run before the last one
        # is definitively over the moment segmentation moved past it, so it
        # must be closed now. Leaving it open would violate the "one open
        # segment per device" invariant the instant the next run tries to
        # open its own segment.
        if index < len(runs) - 1:
            await track_points_repo.close_segment(conn, segment_id)
            result.segments_closed += 1

    # --- Stage 11: recalc + publish --------------------------------------
    if all_touched_hexes:
        await hex_contrib_repo.recalc(conn, sector.id, all_touched_hexes)
        result.hexes_touched = len(all_touched_hexes)

    return result
