import '../api/api_models.dart';

/// Sealed so the UI can exhaustively switch over every phase, mirroring
/// `AuthState`/`JoinState`/`TrackingState`/`SyncState`.
sealed class SosState {
  const SosState();
}

class SosIdle extends SosState {
  const SosIdle();
}

class SosTriggering extends SosState {
  const SosTriggering();
}

/// The alert is open (`active` or `acknowledged` -- see [SosAlert.isOpen]).
/// Whether a Lead/Commander has acknowledged it is read straight off
/// [alert].
class SosActive extends SosState {
  final SosAlert alert;
  const SosActive(this.alert);
}

class SosCancelling extends SosState {
  final SosAlert alert;
  const SosCancelling(this.alert);
}

class SosError extends SosState {
  final String message;
  final SosState previous;
  const SosError({required this.message, required this.previous});
}
