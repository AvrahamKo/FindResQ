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

  const TrackingActive({
    required this.tier,
    required this.sampleCount,
    required this.bufferedCount,
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
