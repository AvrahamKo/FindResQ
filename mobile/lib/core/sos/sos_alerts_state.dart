import '../api/api_models.dart';

/// Sealed states for the Lead/Commander SOS list -- UI-driven polling, same
/// convention as `JoinController.pollOnce()`, not a background self-timer
/// like `LocationTrackingController`/`IngestSyncController`: this is only
/// ever relevant while a Lead/Commander has this screen open.
sealed class SosAlertsState {
  const SosAlertsState();
}

class SosAlertsLoading extends SosAlertsState {
  const SosAlertsLoading();
}

class SosAlertsLoaded extends SosAlertsState {
  final List<SosAlert> alerts;
  const SosAlertsLoaded(this.alerts);
}

class SosAlertsFailed extends SosAlertsState {
  final String message;
  const SosAlertsFailed(this.message);
}
