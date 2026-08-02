"""Stage 8: segment assembly. The most important pure logic in the pipeline --
this is what enforces "never draw coverage across a gap or an untrusted fix."
"""

from __future__ import annotations

import uuid

from app.ingest.plausibility import LOW_ACCURACY, MOCKED, usability
from app.ingest.segmentation import (
    PriorTail,
    ScoredPoint,
    SegmentTuning,
    assign_runs,
)

TUNING = SegmentTuning(
    max_gap_seconds=30, max_gap_meters=50, max_walker_speed_mps=3.0, movement_mode="walker"
)

BASE_MS = 1_700_000_000_000


def _pt(t_offset_s: float, lat: float, lng: float, *, reasons: tuple[str, ...] = ()) -> ScoredPoint:
    return ScoredPoint(
        recorded_at_ms=BASE_MS + int(t_offset_s * 1000),
        lat=lat,
        lng=lng,
        accuracy_m=5.0,
        speed_reported_mps=1.4,
        battery_pct=80,
        is_mocked=False,
        signature=f"sig-{t_offset_s}-{lat}-{lng}".encode(),
        disqualify_reasons=reasons,
    )


def test_continuous_walk_stays_one_run() -> None:
    points = [_pt(0, 31.7700, 35.2100), _pt(10, 31.77005, 35.21005), _pt(20, 31.7701, 35.2101)]
    runs = assign_runs(points, TUNING, prior_tail=None)

    assert len(runs) == 1
    assert runs[0].is_valid
    assert len(runs[0].points) == 3
    assert runs[0].continues_segment_id is None


def test_time_gap_breaks_into_two_runs() -> None:
    points = [
        _pt(0, 31.7700, 35.2100),
        _pt(10, 31.77005, 35.21005),
        _pt(10 + 3600, 31.7701, 35.2101),  # 1 hour later
    ]
    runs = assign_runs(points, TUNING, prior_tail=None)

    assert len(runs) == 2
    assert [len(r.points) for r in runs] == [2, 1]
    assert all(r.is_valid for r in runs)


def test_distance_gap_breaks_into_two_runs() -> None:
    points = [
        _pt(0, 31.7700, 35.2100),
        _pt(10, 31.9000, 35.4000),  # ~24km away, well past max_gap_meters, within time
    ]
    runs = assign_runs(points, TUNING, prior_tail=None)

    assert len(runs) == 2
    assert [len(r.points) for r in runs] == [1, 1]


def test_out_of_order_points_are_sorted_before_segmenting() -> None:
    """The mesh can deliver an earlier point after a later one."""
    points = [_pt(20, 31.7701, 35.2101), _pt(0, 31.7700, 35.2100), _pt(10, 31.77005, 35.21005)]
    runs = assign_runs(points, TUNING, prior_tail=None)

    assert len(runs) == 1
    timestamps = [p.recorded_at_ms for p in runs[0].points]
    assert timestamps == sorted(timestamps)


def test_batch_continues_an_open_segment_within_thresholds() -> None:
    segment_id = uuid.uuid4()
    prior = PriorTail(segment_id=segment_id, recorded_at_ms=BASE_MS, lat=31.7700, lng=35.2100)
    points = [_pt(10, 31.77005, 35.21005)]

    runs = assign_runs(points, TUNING, prior_tail=prior)

    assert len(runs) == 1
    assert runs[0].continues_segment_id == segment_id


def test_batch_does_not_continue_an_open_segment_after_a_gap() -> None:
    segment_id = uuid.uuid4()
    prior = PriorTail(segment_id=segment_id, recorded_at_ms=BASE_MS, lat=31.7700, lng=35.2100)
    points = [_pt(3600, 31.7701, 35.2101)]  # 1 hour later -- gap

    runs = assign_runs(points, TUNING, prior_tail=prior)

    assert len(runs) == 1
    assert runs[0].continues_segment_id is None


def test_continuation_flag_never_appears_on_a_later_run() -> None:
    """By contract, only runs[0] can ever continue the prior segment --
    the pipeline relies on this to decide whether to close it."""
    segment_id = uuid.uuid4()
    prior = PriorTail(segment_id=segment_id, recorded_at_ms=BASE_MS, lat=31.7700, lng=35.2100)
    points = [
        _pt(10, 31.77005, 35.21005),      # continues
        _pt(10 + 3600, 31.9000, 35.4000),  # gap: new run
        _pt(20 + 3600, 31.90005, 35.40005),  # extends that new run
    ]

    runs = assign_runs(points, TUNING, prior_tail=prior)

    assert len(runs) == 2
    assert runs[0].continues_segment_id == segment_id
    assert runs[1].continues_segment_id is None


def test_disqualified_point_becomes_its_own_invalid_run() -> None:
    points = [
        _pt(0, 31.7700, 35.2100),
        _pt(10, 31.77005, 35.21005, reasons=usability(is_mocked=True, accuracy_m=5, min_accuracy_m=30)),
        _pt(20, 31.7701, 35.2101),
    ]
    runs = assign_runs(points, TUNING, prior_tail=None)

    assert len(runs) == 3
    assert runs[0].is_valid and len(runs[0].points) == 1
    assert not runs[1].is_valid and runs[1].plausibility_flags == (MOCKED,)
    assert runs[2].is_valid and len(runs[2].points) == 1


def test_disqualified_point_prevents_bridging_even_within_gap_thresholds() -> None:
    """The core false-clearance guard: a good point immediately before and
    after a disqualified point must NOT be joined into one trusted run, even
    though they'd easily pass the time/distance gap check on their own."""
    reasons = usability(is_mocked=False, accuracy_m=999, min_accuracy_m=30)
    points = [_pt(0, 31.7700, 35.2100), _pt(5, 31.77002, 35.21002, reasons=reasons), _pt(10, 31.77004, 35.21004)]

    runs = assign_runs(points, TUNING, prior_tail=None)

    assert [len(r.points) for r in runs] == [1, 1, 1]
    assert [r.is_valid for r in runs] == [True, False, True]
    # Neither surviving good run should claim to continue anything -- the
    # second one starts fresh precisely because it can't trust what's behind it.
    assert all(r.continues_segment_id is None for r in runs)


def test_fast_walker_run_is_flagged_speed_role_mismatch() -> None:
    # ~43.8m in 5s => ~8.76 m/s: within max_gap_meters (stays one run), but
    # well over a walker's max_walker_speed_mps (3.0).
    points = [_pt(0, 31.7700, 35.2100), _pt(5, 31.77030, 35.21030)]
    runs = assign_runs(points, TUNING, prior_tail=None)

    assert len(runs) == 1
    assert runs[0].plausibility_flags == ("speed_role_mismatch",)


def test_vehicle_mode_is_never_speed_flagged() -> None:
    vehicle_tuning = SegmentTuning(
        max_gap_seconds=30, max_gap_meters=200, max_walker_speed_mps=3.0, movement_mode="vehicle"
    )
    points = [_pt(0, 31.7700, 35.2100), _pt(5, 31.77030, 35.21030)]
    runs = assign_runs(points, vehicle_tuning, prior_tail=None)

    assert runs[0].plausibility_flags == ()
