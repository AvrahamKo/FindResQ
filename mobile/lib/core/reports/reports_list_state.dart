import '../api/api_models.dart';

/// Sealed states for the sector's report list -- UI-driven polling, same
/// convention as `SosAlertsState`/`PendingApprovalView`'s timer.
sealed class ReportsListState {
  const ReportsListState();
}

class ReportsListLoading extends ReportsListState {
  const ReportsListLoading();
}

class ReportsListLoaded extends ReportsListState {
  final List<Report> reports;
  const ReportsListLoaded(this.reports);
}

class ReportsListFailed extends ReportsListState {
  final String message;
  const ReportsListFailed(this.message);
}
