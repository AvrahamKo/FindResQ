/// Pure exponential-backoff calculation for ingest sync retries -- no I/O,
/// no `Timer`, just deterministic math. Mirrors
/// `core/location/location_sampling_policy.dart`'s role for the location
/// tracker: keeping the policy testable with zero setup, and letting
/// [IngestSyncController] depend on a plain function of "how many
/// consecutive failures so far" rather than owning the math itself.
library;

class SyncBackoffPolicy {
  final Duration initialBackoff;
  final Duration maxBackoff;

  const SyncBackoffPolicy({
    this.initialBackoff = const Duration(seconds: 5),
    this.maxBackoff = const Duration(minutes: 5),
  });

  /// [consecutiveFailures] is 1 for the first failure, 2 for the second,
  /// and so on -- 0 (or less) means "not backing off," which returns
  /// [Duration.zero]. Doubles each additional failure, capped at
  /// [maxBackoff] so a long offline stretch settles into a steady retry
  /// cadence instead of growing without bound.
  Duration delayFor(int consecutiveFailures) {
    if (consecutiveFailures <= 0) return Duration.zero;

    // Shift is clamped well below the point an Int64 could overflow --
    // maxBackoff.clamp below already takes over long before that matters,
    // this just keeps the intermediate multiplication itself safe.
    final shift = (consecutiveFailures - 1).clamp(0, 20);
    final scaledMs = initialBackoff.inMilliseconds * (1 << shift);
    final cappedMs = scaledMs.clamp(0, maxBackoff.inMilliseconds);
    return Duration(milliseconds: cappedMs);
  }
}
