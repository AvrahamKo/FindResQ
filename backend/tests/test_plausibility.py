"""Stage 7: per-point plausibility scoring. Pure."""

from __future__ import annotations

import pytest

from app.ingest import plausibility as p


class TestUsability:
    def test_clean_point_is_usable(self) -> None:
        assert p.usability(is_mocked=False, accuracy_m=5.0, min_accuracy_m=30.0) == ()

    def test_mocked_point_is_flagged(self) -> None:
        assert p.usability(is_mocked=True, accuracy_m=5.0, min_accuracy_m=30.0) == (p.MOCKED,)

    def test_low_accuracy_point_is_flagged(self) -> None:
        reasons = p.usability(is_mocked=False, accuracy_m=65.0, min_accuracy_m=30.0)
        assert reasons == (p.LOW_ACCURACY,)

    def test_accuracy_exactly_at_threshold_is_usable(self) -> None:
        assert p.usability(is_mocked=False, accuracy_m=30.0, min_accuracy_m=30.0) == ()

    def test_both_reasons_can_apply_at_once(self) -> None:
        reasons = p.usability(is_mocked=True, accuracy_m=65.0, min_accuracy_m=30.0)
        assert set(reasons) == {p.MOCKED, p.LOW_ACCURACY}


class TestSpeedImplausibility:
    def test_normal_walking_speed_is_plausible(self) -> None:
        # ~1.4 m/s over 10s covering 14m
        assert not p.is_speed_implausible(
            distance_m=14.0, elapsed_s=10.0, movement_mode="walker", max_walker_speed_mps=3.0
        )

    def test_fast_walker_segment_is_flagged(self) -> None:
        # 100m in 10s = 10 m/s -- a car, not a person on foot
        assert p.is_speed_implausible(
            distance_m=100.0, elapsed_s=10.0, movement_mode="walker", max_walker_speed_mps=3.0
        )

    def test_vehicle_mode_has_no_upper_bound(self) -> None:
        # Highway speed is legitimate for a vehicle-mode searcher.
        assert not p.is_speed_implausible(
            distance_m=500.0, elapsed_s=10.0, movement_mode="vehicle", max_walker_speed_mps=3.0
        )

    def test_zero_elapsed_time_with_movement_is_implausible(self) -> None:
        assert p.is_speed_implausible(
            distance_m=5.0, elapsed_s=0.0, movement_mode="walker", max_walker_speed_mps=3.0
        )

    def test_zero_elapsed_time_with_no_movement_is_plausible(self) -> None:
        assert not p.is_speed_implausible(
            distance_m=0.0, elapsed_s=0.0, movement_mode="walker", max_walker_speed_mps=3.0
        )
