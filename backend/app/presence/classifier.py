"""The four-state presence classifier, including the "correlated silence"
heuristic (Q8 of the architecture review): distinguishing a genuine
emergency (one searcher goes dark while their neighbours keep reporting)
from a dead zone (several searchers walk into the same canyon together and
all lose signal at once).

Pure -- no database, no clock reads (the caller supplies `now`). The DB
orchestrator lives in presence/sweep.py.
"""

from __future__ import annotations

import uuid
from dataclasses import dataclass
from datetime import datetime

import h3

ACTIVE = "active"
STALE = "stale"
DEAD_ZONE = "dead_zone"
BATTERY_DEAD = "battery_dead"
MIA = "mia"


@dataclass(frozen=True, slots=True)
class PresenceThresholds:
    active_seconds: int = 180  # Q8: green while telemetry is under 3 minutes old
    mia_seconds: int = 900  # Q8: the stale/MIA boundary, at 15 minutes
    battery_dead_pct: int = 5  # Q8: "phone simply died" floor
    correlation_resolution: int = 9  # coarser than the sector's tracking
    # resolution -- this is "same vicinity", not "same 9m hex"
    correlation_window_seconds: int = 60
    correlation_min_devices: int = 3


@dataclass(frozen=True, slots=True)
class DeviceSnapshot:
    device_id: uuid.UUID
    last_point_at: datetime  # must be timezone-aware
    last_lat: float
    last_lng: float
    last_battery_pct: int | None


def _base_state(
    snapshot: DeviceSnapshot, now: datetime, thresholds: PresenceThresholds
) -> str:
    """Everything except the MIA/dead-zone split, which needs the whole
    sector's candidates at once (see `_correlate`)."""
    silence_s = (now - snapshot.last_point_at).total_seconds()

    if silence_s <= thresholds.active_seconds:
        return ACTIVE
    if (
        snapshot.last_battery_pct is not None
        and snapshot.last_battery_pct <= thresholds.battery_dead_pct
    ):
        return BATTERY_DEAD
    if silence_s <= thresholds.mia_seconds:
        return STALE
    return MIA  # a candidate -- correlation may downgrade this to DEAD_ZONE


def _group_by_vicinity(
    candidates: list[DeviceSnapshot], resolution: int
) -> list[list[DeviceSnapshot]]:
    """Groups candidates whose coarse H3 cells are the same or adjacent
    (grid distance <= 1), via union-find over pairwise adjacency.

    Grouping by EXACT cell equality would miss two searchers standing 20
    metres apart who simply happen to be on opposite sides of a cell
    boundary -- an entirely ordinary occurrence, not an edge case, since
    device positions are not chosen with H3's grid in mind. Adjacency
    (rather than equality) is what "same vicinity" actually has to mean.
    """
    cell_of: dict[uuid.UUID, str] = {
        snap.device_id: h3.latlng_to_cell(snap.last_lat, snap.last_lng, resolution)
        for snap in candidates
    }
    parent: dict[uuid.UUID, uuid.UUID] = {snap.device_id: snap.device_id for snap in candidates}

    def find(x: uuid.UUID) -> uuid.UUID:
        while parent[x] != x:
            parent[x] = parent[parent[x]]
            x = parent[x]
        return x

    def union(a: uuid.UUID, b: uuid.UUID) -> None:
        ra, rb = find(a), find(b)
        if ra != rb:
            parent[ra] = rb

    ids = list(cell_of)
    for i in range(len(ids)):
        for j in range(i + 1, len(ids)):
            if h3.grid_distance(cell_of[ids[i]], cell_of[ids[j]]) <= 1:
                union(ids[i], ids[j])

    by_snapshot = {snap.device_id: snap for snap in candidates}
    groups: dict[uuid.UUID, list[DeviceSnapshot]] = {}
    for device_id in ids:
        groups.setdefault(find(device_id), []).append(by_snapshot[device_id])
    return list(groups.values())


def _correlate(
    candidates: list[DeviceSnapshot], thresholds: PresenceThresholds
) -> set[uuid.UUID]:
    """Returns the subset of MIA candidates that are actually a dead zone.

    Candidates are grouped by vicinity (see `_group_by_vicinity`), then
    within each group a sliding time-window finds clusters of 3+ devices
    whose silence began within `correlation_window_seconds` of each other.
    Overlapping qualifying windows chain together -- e.g. three searchers
    losing signal 20 seconds apart each (a rolling wave entering a canyon)
    correlates the whole chain, even if the first and last are more than
    60 seconds apart overall. That's deliberate: a search team losing signal
    in sequence over 90 seconds while walking the same route is one dead-zone
    event, not one flagged incident bookended by two isolated ones.
    """
    dead_zone_ids: set[uuid.UUID] = set()

    for group in _group_by_vicinity(candidates, thresholds.correlation_resolution):
        if len(group) < thresholds.correlation_min_devices:
            continue

        ordered = sorted(group, key=lambda s: s.last_point_at)
        left = 0
        for right in range(len(ordered)):
            while (
                ordered[right].last_point_at - ordered[left].last_point_at
            ).total_seconds() > thresholds.correlation_window_seconds:
                left += 1
            if right - left + 1 >= thresholds.correlation_min_devices:
                dead_zone_ids.update(s.device_id for s in ordered[left : right + 1])

    return dead_zone_ids


def classify(
    snapshots: list[DeviceSnapshot], now: datetime, thresholds: PresenceThresholds
) -> dict[uuid.UUID, str]:
    """Returns {device_id: state} for every device given. The caller
    (presence/sweep.py) is responsible for diffing this against currently
    stored state and writing only the devices that actually changed."""
    states: dict[uuid.UUID, str] = {}
    mia_candidates: list[DeviceSnapshot] = []

    for snap in snapshots:
        state = _base_state(snap, now, thresholds)
        if state == MIA:
            mia_candidates.append(snap)
        else:
            states[snap.device_id] = state

    dead_zone_ids = _correlate(mia_candidates, thresholds)
    for snap in mia_candidates:
        states[snap.device_id] = DEAD_ZONE if snap.device_id in dead_zone_ids else MIA

    return states
