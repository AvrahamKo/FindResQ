"""The four-state presence classifier and the correlated-silence heuristic.
Pure -- no database."""

from __future__ import annotations

import uuid
from datetime import datetime, timedelta, timezone

from app.presence.classifier import (
    ACTIVE,
    BATTERY_DEAD,
    DEAD_ZONE,
    MIA,
    STALE,
    DeviceSnapshot,
    PresenceThresholds,
    classify,
)

NOW = datetime(2026, 6, 1, 12, 0, 0, tzinfo=timezone.utc)
THRESHOLDS = PresenceThresholds()

BASE_LAT, BASE_LNG = 31.7700, 35.2200


def _snap(
    seconds_ago: float,
    *,
    battery: int | None = 80,
    lat: float = BASE_LAT,
    lng: float = BASE_LNG,
    device_id: uuid.UUID | None = None,
) -> DeviceSnapshot:
    return DeviceSnapshot(
        device_id=device_id or uuid.uuid4(),
        last_point_at=NOW - timedelta(seconds=seconds_ago),
        last_lat=lat,
        last_lng=lng,
        last_battery_pct=battery,
    )


class TestBaseStates:
    def test_recent_telemetry_is_active(self) -> None:
        snap = _snap(60)  # 1 minute ago
        assert classify([snap], NOW, THRESHOLDS)[snap.device_id] == ACTIVE

    def test_just_under_active_threshold_is_active(self) -> None:
        snap = _snap(THRESHOLDS.active_seconds - 1)
        assert classify([snap], NOW, THRESHOLDS)[snap.device_id] == ACTIVE

    def test_just_over_active_threshold_with_healthy_battery_is_stale(self) -> None:
        snap = _snap(THRESHOLDS.active_seconds + 1, battery=80)
        assert classify([snap], NOW, THRESHOLDS)[snap.device_id] == STALE

    def test_moderate_silence_with_healthy_battery_is_stale(self) -> None:
        snap = _snap(600, battery=50)  # 10 minutes, well within the 15-min MIA boundary
        assert classify([snap], NOW, THRESHOLDS)[snap.device_id] == STALE

    def test_low_battery_is_battery_dead_regardless_of_silence_length(self) -> None:
        snap = _snap(200, battery=4)  # just past active, battery already critical
        assert classify([snap], NOW, THRESHOLDS)[snap.device_id] == BATTERY_DEAD

    def test_battery_dead_overrides_even_very_long_silence(self) -> None:
        snap = _snap(3600 * 5, battery=1)
        assert classify([snap], NOW, THRESHOLDS)[snap.device_id] == BATTERY_DEAD

    def test_battery_exactly_at_dead_threshold_counts_as_dead(self) -> None:
        snap = _snap(200, battery=THRESHOLDS.battery_dead_pct)
        assert classify([snap], NOW, THRESHOLDS)[snap.device_id] == BATTERY_DEAD

    def test_low_battery_while_still_actively_reporting_is_active(self) -> None:
        """A low reading doesn't retroactively mark a currently-transmitting
        device as presumed dead -- the state describes why telemetry
        stopped, and this device hasn't stopped yet."""
        snap = _snap(10, battery=2)
        assert classify([snap], NOW, THRESHOLDS)[snap.device_id] == ACTIVE

    def test_isolated_long_silence_with_healthy_battery_is_mia(self) -> None:
        snap = _snap(THRESHOLDS.mia_seconds + 60, battery=90)
        assert classify([snap], NOW, THRESHOLDS)[snap.device_id] == MIA

    def test_just_under_mia_threshold_is_stale_not_mia(self) -> None:
        snap = _snap(THRESHOLDS.mia_seconds - 1, battery=90)
        assert classify([snap], NOW, THRESHOLDS)[snap.device_id] == STALE


class TestCorrelatedSilence:
    def test_three_devices_silent_together_in_same_vicinity_is_dead_zone(self) -> None:
        silent_for = THRESHOLDS.mia_seconds + 30
        snaps = [
            _snap(silent_for, lat=BASE_LAT, lng=BASE_LNG),
            _snap(silent_for - 10, lat=BASE_LAT + 0.0001, lng=BASE_LNG + 0.0001),
            _snap(silent_for - 20, lat=BASE_LAT - 0.0001, lng=BASE_LNG - 0.0001),
        ]
        states = classify(snaps, NOW, THRESHOLDS)
        assert all(state == DEAD_ZONE for state in states.values())

    def test_two_devices_silent_together_stay_mia_not_dead_zone(self) -> None:
        """Below the minimum correlation count (3), it's still an alert."""
        silent_for = THRESHOLDS.mia_seconds + 30
        snaps = [
            _snap(silent_for, lat=BASE_LAT, lng=BASE_LNG),
            _snap(silent_for - 10, lat=BASE_LAT + 0.0001, lng=BASE_LNG + 0.0001),
        ]
        states = classify(snaps, NOW, THRESHOLDS)
        assert all(state == MIA for state in states.values())

    def test_isolated_device_far_from_others_stays_mia(self) -> None:
        """The core safety property: one searcher going dark while everyone
        else keeps reporting must NOT be suppressed."""
        silent_for = THRESHOLDS.mia_seconds + 30
        far_lat, far_lng = BASE_LAT + 0.5, BASE_LNG + 0.5  # a different vicinity entirely
        snaps = [
            _snap(silent_for, lat=far_lat, lng=far_lng),  # isolated
            _snap(silent_for - 5, lat=BASE_LAT, lng=BASE_LNG),
            _snap(silent_for - 10, lat=BASE_LAT + 0.0001, lng=BASE_LNG + 0.0001),
        ]
        states = classify(snaps, NOW, THRESHOLDS)
        isolated_id = snaps[0].device_id
        assert states[isolated_id] == MIA
        # The other two are only 2 in their vicinity -- also below the
        # correlation minimum, so they stay MIA too, just for a different reason.
        assert states[snaps[1].device_id] == MIA

    def test_same_vicinity_but_silence_spread_too_far_apart_in_time_stays_mia(self) -> None:
        """Same location, but their silence onsets are hours apart -- not a
        single dead-zone event, three coincidentally-isolated incidents."""
        base_silent = THRESHOLDS.mia_seconds + 30
        snaps = [
            _snap(base_silent, lat=BASE_LAT, lng=BASE_LNG),
            _snap(base_silent + 3600, lat=BASE_LAT, lng=BASE_LNG),
            _snap(base_silent + 7200, lat=BASE_LAT, lng=BASE_LNG),
        ]
        states = classify(snaps, NOW, THRESHOLDS)
        assert all(state == MIA for state in states.values())

    def test_chained_overlapping_windows_correlate_the_whole_group(self) -> None:
        """A rolling wave of searchers losing signal 20s apart each (total
        spread 90s > the 60s window) still correlates as one dead-zone event,
        via overlapping windows -- this is a deliberate interpretation, see
        classifier.py's docstring."""
        base = THRESHOLDS.mia_seconds
        snaps = [
            _snap(base + 90, lat=BASE_LAT, lng=BASE_LNG),
            _snap(base + 70, lat=BASE_LAT, lng=BASE_LNG),
            _snap(base + 50, lat=BASE_LAT, lng=BASE_LNG),
            _snap(base + 30, lat=BASE_LAT, lng=BASE_LNG),
            _snap(base + 10, lat=BASE_LAT, lng=BASE_LNG),
        ]
        states = classify(snaps, NOW, THRESHOLDS)
        assert all(state == DEAD_ZONE for state in states.values())

    def test_active_and_stale_devices_are_never_candidates_for_correlation(self) -> None:
        """Correlation only ever considers MIA candidates -- an active
        device sitting in the same hex as MIA candidates must not be pulled
        into a dead-zone classification itself."""
        silent_for = THRESHOLDS.mia_seconds + 30
        active_nearby = _snap(30, lat=BASE_LAT, lng=BASE_LNG)  # still actively reporting
        candidates = [
            _snap(silent_for, lat=BASE_LAT, lng=BASE_LNG),
            _snap(silent_for - 5, lat=BASE_LAT, lng=BASE_LNG),
            _snap(silent_for - 10, lat=BASE_LAT, lng=BASE_LNG),
        ]
        states = classify([active_nearby, *candidates], NOW, THRESHOLDS)
        assert states[active_nearby.device_id] == ACTIVE
        assert all(states[s.device_id] == DEAD_ZONE for s in candidates)

    def test_battery_dead_device_is_not_pulled_into_correlation(self) -> None:
        """A device that died of a flat battery isn't part of a 'dead zone'
        cluster even if co-located with genuinely MIA neighbours -- it has
        its own, different, known explanation."""
        silent_for = THRESHOLDS.mia_seconds + 30
        dead_battery = _snap(silent_for, lat=BASE_LAT, lng=BASE_LNG, battery=2)
        mia_candidates = [
            _snap(silent_for - 5, lat=BASE_LAT, lng=BASE_LNG),
            _snap(silent_for - 10, lat=BASE_LAT, lng=BASE_LNG),
        ]
        states = classify([dead_battery, *mia_candidates], NOW, THRESHOLDS)
        assert states[dead_battery.device_id] == BATTERY_DEAD
        # Only 2 genuine MIA candidates remain in this vicinity -- below the
        # correlation minimum, so they stay MIA rather than being padded out
        # by the battery-dead device to reach 3.
        assert all(states[s.device_id] == MIA for s in mia_candidates)


def test_empty_input_returns_empty_result() -> None:
    assert classify([], NOW, THRESHOLDS) == {}
