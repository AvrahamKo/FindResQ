import 'location_sample.dart';
import 'location_sampling_policy.dart';

/// Sealed so the UI can exhaustively switch over every phase of location
/// tracking, mirroring `AuthState`/`JoinState`.
sealed class TrackingState {
  const TrackingState();
}

class TrackingIdle extends TrackingState {
  const TrackingIdle();
}

class TrackingStarting extends TrackingState {
  const TrackingStarting();
}

class TrackingActive extends TrackingState {
  final SamplingTierName tier;
  final int sampleCount;
  final int bufferedCount;

  /// The most recent fix. Null between `start()` and the first sample
  /// actually arriving from the platform -- "tracking is on but we have no
  /// fix yet" is a real, displayable state, not an error.
  ///
  /// Exposed so the session HUD can show position/accuracy WITHOUT opening a
  /// second platform location subscription just to draw a map marker: this
  /// app treats battery as a first-class constraint (see
  /// [LocationSamplingPolicy]), and a duplicate GPS stream would undercut
  /// the whole tiering scheme.
  final LocationSample? lastSample;

  /// Battery level read when the tier was last resolved -- i.e. the same
  /// reading that chose [tier], not an independent poll.
  final int? batteryPct;

  const TrackingActive({
    required this.tier,
    required this.sampleCount,
    required this.bufferedCount,
    this.lastSample,
    this.batteryPct,
  });
}

class TrackingError extends TrackingState {
  final String message;

  /// The state to fall back to -- mirrors `AuthFailed`/`JoinFailed`'s
  /// `previous` field so the UI can decide whether to offer "retry" (back to
  /// idle) vs. something more specific.
  final TrackingState previous;

  const TrackingError({required this.message, required this.previous});
}
