import '../api/api_models.dart';

class CoverageMapState {
  final List<CoverageCell> teamCells;
  final DateTime? lastServerSyncAt;
  final bool loading;
  final String? lastError;

  const CoverageMapState({
    this.teamCells = const [],
    this.lastServerSyncAt,
    this.loading = false,
    this.lastError,
  });

  CoverageMapState copyWith({
    List<CoverageCell>? teamCells,
    DateTime? lastServerSyncAt,
    bool? loading,
    String? lastError,
    bool clearError = false,
  }) => CoverageMapState(
    teamCells: teamCells ?? this.teamCells,
    lastServerSyncAt: lastServerSyncAt ?? this.lastServerSyncAt,
    loading: loading ?? this.loading,
    lastError: clearError ? null : (lastError ?? this.lastError),
  );
}
