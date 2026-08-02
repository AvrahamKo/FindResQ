/// Sealed so the UI can exhaustively switch over sync status, mirroring
/// `AuthState`/`JoinState`/`TrackingState`.
sealed class SyncState {
  const SyncState();
}

class SyncIdle extends SyncState {
  const SyncIdle();
}

/// The one running state, covering every sub-phase (mid-upload, waiting for
/// the next normal tick, waiting out a backoff) -- the UI cares about the
/// same handful of fields regardless of which sub-phase it's in, so this
/// isn't split into separate subclasses the way `TrackingState` splits
/// `TrackingStarting`/`TrackingActive` (which really do need different UI).
class SyncActive extends SyncState {
  /// Packets still sitting in the local buffer, not yet acknowledged by the
  /// server.
  final int pendingCount;

  /// Cumulative across this controller's lifetime (resets on `start()`),
  /// not persisted -- a running total for the debug view, not an audit log.
  final int totalUploaded;

  /// Cumulative count of blobs the server terminally rejected (duplicate,
  /// decrypt-failed, bad signature, wrong device, malformed) -- still
  /// acknowledged and removed from the buffer, since retrying a
  /// deterministically-bad packet can never succeed. See `IngestResult`'s
  /// docstring for why these are bucketed together.
  final int totalRejected;

  /// Consecutive request-level failures (network down, timeout, non-2xx) --
  /// 0 when the most recent attempt succeeded or nothing has been attempted
  /// yet. Drives [SyncBackoffPolicy].
  final int consecutiveFailures;

  final bool isUploading;
  final DateTime? lastSyncAt;

  /// Non-null only when [consecutiveFailures] > 0 -- the most recent
  /// request-level failure's message, for the debug view.
  final String? lastError;

  const SyncActive({
    required this.pendingCount,
    required this.totalUploaded,
    required this.totalRejected,
    required this.consecutiveFailures,
    required this.isUploading,
    required this.lastSyncAt,
    required this.lastError,
  });
}

/// Can't run at all -- no active sector session to sync to. Mirrors
/// `TrackingError`'s `previous` field.
class SyncError extends SyncState {
  final String message;
  final SyncState previous;
  const SyncError({required this.message, required this.previous});
}
