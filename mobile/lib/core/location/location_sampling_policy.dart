/// Pure battery-aware GPS sampling policy -- no plugin, no platform channel,
/// no I/O. Mirrors the backend's "pure logic, no DB" modules (e.g.
/// `ingest/segmentation.py`): this file is a deterministic function of
/// (battery level, charging state) -> sampling tier, so it is testable
/// without a device or an emulator.
///
/// Distance-filtered sampling, not fixed-interval 1Hz polling, per the
/// original architecture review's Q8: GPS is the single biggest battery draw
/// on a multi-hour SAR shift, and a volunteer standing still (searching a
/// building, at a briefing) produces zero useful track data at 1Hz while
/// draining the battery a searcher may need for the entire operational
/// period. The distance filter means the OS only wakes the app for a new fix
/// once the device has actually moved -- the tiers below only change HOW FAR
/// it must move (and how eagerly the platform should try), not whether
/// motion produces a report at all.
library;

enum SamplingTierName { high, balanced, saver, critical }

/// A hint, not a platform type -- [LocationSource] implementations map this
/// onto whatever accuracy enum their underlying plugin exposes. Keeping this
/// file free of any plugin import is what makes it testable in a bare Dart
/// VM with zero setup.
enum AccuracyHint { best, high, medium, low }

class SamplingTier {
  final SamplingTierName name;
  final double distanceFilterM;
  final AccuracyHint accuracyHint;

  const SamplingTier({
    required this.name,
    required this.distanceFilterM,
    required this.accuracyHint,
  });

  @override
  String toString() => 'SamplingTier(${name.name}, ${distanceFilterM}m)';
}

class LocationSamplingPolicy {
  const LocationSamplingPolicy();

  static const SamplingTier high = SamplingTier(
    name: SamplingTierName.high,
    distanceFilterM: 10,
    accuracyHint: AccuracyHint.best,
  );

  static const SamplingTier balanced = SamplingTier(
    name: SamplingTierName.balanced,
    distanceFilterM: 25,
    accuracyHint: AccuracyHint.high,
  );

  static const SamplingTier saver = SamplingTier(
    name: SamplingTierName.saver,
    distanceFilterM: 50,
    accuracyHint: AccuracyHint.medium,
  );

  static const SamplingTier critical = SamplingTier(
    name: SamplingTierName.critical,
    distanceFilterM: 100,
    accuracyHint: AccuracyHint.low,
  );

  /// Resolves the tier to sample at right now.
  ///
  /// A device on charge is never battery-constrained -- even at 5%, a
  /// searcher plugged into a vehicle or a power bank should get full-fidelity
  /// tracking, so [isCharging] short-circuits straight to [high] regardless
  /// of [batteryPct]. Off charge, thresholds step down coverage density as
  /// the battery drops, matching the same 30%/15% breakpoints already used
  /// for the join-time battery warning/block (see `JoinController` /
  /// `join_code_view.dart`) so the whole app agrees on what "low battery"
  /// means.
  SamplingTier resolve({required int batteryPct, required bool isCharging}) {
    if (isCharging) return high;
    if (batteryPct >= 60) return high;
    if (batteryPct >= 30) return balanced;
    if (batteryPct >= 15) return saver;
    return critical;
  }
}
