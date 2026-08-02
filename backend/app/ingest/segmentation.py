"""Stage 8: segment assembly (pure).

Three independent reasons force a break between consecutive points -- a time
gap, a distance gap, or the earlier point being disqualified by plausibility
scoring (plausibility.py). All three are treated identically: the swath must
never be drawn across a point the pipeline doesn't trust, for the same
"teleportation capsule" reason a time/distance gap breaks a segment (Q4) --
an untrusted fix is exactly as dangerous to bridge across as an unknown gap.
A disqualified point still gets a row (for audit), it just never joins a
run of points that will be buffered into a swath.

This function is pure: no database, no clock reads. The caller supplies
`prior_tail` -- the open segment's last known point, if any -- so a batch
that continues a segment started in an earlier upload correctly extends it
rather than spuriously starting a new one every time a device happens to
flush its buffer.
"""

from __future__ import annotations

from dataclasses import dataclass

from .geometry import haversine_distance_m


@dataclass(frozen=True, slots=True)
class ScoredPoint:
    recorded_at_ms: int
    lat: float
    lng: float
    accuracy_m: float
    speed_reported_mps: float
    battery_pct: int
    is_mocked: bool
    signature: bytes
    disqualify_reasons: tuple[str, ...] = ()

    @property
    def usable(self) -> bool:
        return not self.disqualify_reasons


@dataclass(frozen=True, slots=True)
class SegmentTuning:
    max_gap_seconds: int
    max_gap_meters: float
    max_walker_speed_mps: float
    movement_mode: str  # 'walker' | 'vehicle'


@dataclass(frozen=True, slots=True)
class PriorTail:
    """The open segment's last known point, as stored on `track_segments`
    (`last_recorded_at`, `last_lat`, `last_lng`) -- an O(1) lookup, no scan
    over `track_points` needed to resume it."""

    segment_id: object  # uuid.UUID; kept untyped here to avoid importing uuid for a passthrough
    recorded_at_ms: int
    lat: float
    lng: float


@dataclass(frozen=True, slots=True)
class Run:
    points: tuple[ScoredPoint, ...]
    is_valid: bool
    continues_segment_id: object | None  # uuid.UUID | None
    plausibility_flags: tuple[str, ...]


def _speed_flags(points: tuple[ScoredPoint, ...], tuning: SegmentTuning) -> tuple[str, ...]:
    from .plausibility import SPEED_ROLE_MISMATCH, is_speed_implausible

    for prev, curr in zip(points, points[1:]):
        dt_s = (curr.recorded_at_ms - prev.recorded_at_ms) / 1000
        dist_m = haversine_distance_m(prev.lat, prev.lng, curr.lat, curr.lng)
        if is_speed_implausible(
            distance_m=dist_m,
            elapsed_s=dt_s,
            movement_mode=tuning.movement_mode,
            max_walker_speed_mps=tuning.max_walker_speed_mps,
        ):
            return (SPEED_ROLE_MISMATCH,)
    return ()


def assign_runs(
    points: list[ScoredPoint],
    tuning: SegmentTuning,
    prior_tail: PriorTail | None,
) -> list[Run]:
    """Returns runs in chronological order. By construction, only `runs[0]`
    can ever have `continues_segment_id` set -- continuity is permanently
    severed the moment any break occurs, and never resumes later in the same
    batch. The caller therefore knows to close `prior_tail`'s segment in the
    database whenever `not runs or runs[0].continues_segment_id is None`
    (given `prior_tail` was not None to begin with).
    """
    ordered = sorted(points, key=lambda p: p.recorded_at_ms)

    results: list[Run] = []
    current: list[ScoredPoint] = []
    continues_open_segment = prior_tail.segment_id if prior_tail is not None else None
    anchor: tuple[float, float, int] | None = (
        (prior_tail.lat, prior_tail.lng, prior_tail.recorded_at_ms)
        if prior_tail is not None
        else None
    )

    def flush() -> None:
        nonlocal current, continues_open_segment
        if current:
            run_points = tuple(current)
            results.append(
                Run(
                    points=run_points,
                    is_valid=True,
                    continues_segment_id=continues_open_segment,
                    plausibility_flags=_speed_flags(run_points, tuning),
                )
            )
            current = []
        continues_open_segment = None

    for point in ordered:
        if not point.usable:
            flush()
            results.append(
                Run(
                    points=(point,),
                    is_valid=False,
                    continues_segment_id=None,
                    plausibility_flags=point.disqualify_reasons,
                )
            )
            anchor = None
            continue

        if anchor is not None:
            a_lat, a_lng, a_ms = anchor
            dt_s = (point.recorded_at_ms - a_ms) / 1000
            dist_m = haversine_distance_m(a_lat, a_lng, point.lat, point.lng)
            if dt_s <= 0 or dt_s > tuning.max_gap_seconds or dist_m > tuning.max_gap_meters:
                flush()

        current.append(point)
        anchor = (point.lat, point.lng, point.recorded_at_ms)

    flush()
    return results
