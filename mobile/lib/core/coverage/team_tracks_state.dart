import '../api/api_models.dart';

/// The team's scan paths as currently known to this device.
///
/// [tracks] is keyed by `segmentId` because the backend's delta responses
/// RE-SEND a growing segment with its full current polyline rather than
/// appending to it. Keeping a map, not a list, is what makes "apply a
/// delta" a set of replacements instead of a merge that would double every
/// still-moving teammate's trail on each poll.
class TeamTracksState {
  final Map<String, TeamTrack> tracks;

  /// The server's clock at the last successful fetch -- the `since` for the
  /// next one. Null until the first response lands.
  final DateTime? syncedAt;

  final bool loading;
  final String? lastError;

  const TeamTracksState({
    this.tracks = const {},
    this.syncedAt,
    this.loading = false,
    this.lastError,
  });

  List<TeamTrack> get ordered {
    final values = tracks.values.toList(growable: false);
    // Oldest first, so the newest traverses paint on top -- a live track
    // must never be buried under a finished one from three hours ago.
    values.sort((a, b) => a.startedAt.compareTo(b.startedAt));
    return values;
  }

  TeamTracksState copyWith({
    Map<String, TeamTrack>? tracks,
    DateTime? syncedAt,
    bool? loading,
    String? lastError,
    bool clearError = false,
  }) => TeamTracksState(
    tracks: tracks ?? this.tracks,
    syncedAt: syncedAt ?? this.syncedAt,
    loading: loading ?? this.loading,
    lastError: clearError ? null : (lastError ?? this.lastError),
  );
}
