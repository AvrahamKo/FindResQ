"""Stage 7: per-point plausibility scoring (pure).

Two independent checks, deliberately kept separate because they mean
different things to a Commander looking at the coverage map:

* `is_mocked` / low accuracy -- the FIX itself is not trustworthy. The point
  is stored for audit but contributes nothing to coverage, full stop.
* speed-vs-role mismatch -- the fix is probably genuine, but the SEGMENT it
  belongs to looks like a vehicle pretending to be a walker (or vice versa).
  This flags the segment for review; it does not by itself disqualify points.

A point failing accuracy or mocked-detection is excluded from the swath
entirely (Q3: "its contribution... is drastically diluted or discarded
entirely" -- discarded, for the MVP, is simpler and safer than a partial
weight that has to be threaded through the POD math).
"""

from __future__ import annotations

MOCKED = "mocked"
LOW_ACCURACY = "low_accuracy"
SPEED_ROLE_MISMATCH = "speed_role_mismatch"


def usability(*, is_mocked: bool, accuracy_m: float, min_accuracy_m: float) -> tuple[str, ...]:
    """Reasons a point is unusable for coverage. Empty tuple == usable."""
    reasons = []
    if is_mocked:
        reasons.append(MOCKED)
    if accuracy_m > min_accuracy_m:
        reasons.append(LOW_ACCURACY)
    return tuple(reasons)


def is_speed_implausible(
    *, distance_m: float, elapsed_s: float, movement_mode: str, max_walker_speed_mps: float
) -> bool:
    """Only walkers have an upper speed bound -- a vehicle legitimately
    travels at highway speed, so there is no analogous "too fast" check for
    `movement_mode == 'vehicle'`."""
    if movement_mode != "walker":
        return False
    if elapsed_s <= 0:
        # Zero or negative elapsed time with nonzero distance is exactly the
        # "teleportation" shape a segment break should already have caught;
        # treat it as implausible if it somehow reaches this check.
        return distance_m > 0
    return (distance_m / elapsed_s) > max_walker_speed_mps
