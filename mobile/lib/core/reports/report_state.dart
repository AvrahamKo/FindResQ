/// Sealed states for filing a single field report, mirroring
/// `AuthState`/`JoinState`/`TrackingState`/`SyncState`/`SosState`.
sealed class ReportState {
  const ReportState();
}

class ReportIdle extends ReportState {
  const ReportIdle();
}

class ReportSubmitting extends ReportState {
  const ReportSubmitting();
}

/// Terminal success -- the UI is expected to reset back to [ReportIdle]
/// (e.g. after showing a confirmation) rather than staying here, since
/// filing a report is a one-shot action, not an ongoing state like SOS.
class ReportSubmitted extends ReportState {
  final String kind;
  const ReportSubmitted(this.kind);
}

class ReportError extends ReportState {
  final String message;
  final ReportState previous;
  const ReportError({required this.message, required this.previous});
}
