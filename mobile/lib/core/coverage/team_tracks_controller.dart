/// Fetches and maintains the scan paths of EVERY searcher in the sector.
///
/// This is the fix for "the Team view only ever showed my own trail". The
/// personal trail ([PersonalTrailController]) is a local, offline-first
/// record of this handset's own GPS fixes and is all a searcher has in a
/// dead zone. It is not, and cannot be, the team's paths: those exist only
/// on the server, assembled from what every other device has uploaded.
/// Rendering the local trail under a "Team" label meant the toggle silently
/// showed the same line twice.
///
/// Polls rather than streams: the mobile app has no WebSocket (the socket
/// transport is dashboard-only, see backend/app/api/routes/ws.py), and a
/// field handset on intermittent LTE is better served by a cheap delta
/// request it can simply miss than by a connection it must keep alive.
library;

import 'package:state_notifier/state_notifier.dart';

import '../api/api_client.dart';
import '../api/api_exception.dart';
import '../api/api_models.dart';
import '../storage/secure_storage_manager.dart';
import 'team_tracks_state.dart';

class TeamTracksController extends StateNotifier<TeamTracksState> {
  final ApiClient _api;
  final SecureStorageManager _storage;
  bool _inFlight = false;

  TeamTracksController({
    required ApiClient api,
    required SecureStorageManager storage,
  }) : _api = api,
       _storage = storage,
       super(const TeamTracksState(loading: true));

  /// Full refresh from scratch -- drops the local delta checkpoint so the
  /// next fetch returns every track, not just what changed. Used on first
  /// load and after an error, where the checkpoint may be ahead of what was
  /// actually applied.
  Future<void> reload() => _fetch(fromScratch: true);

  /// Incremental poll: only segments that have moved since the last
  /// successful response.
  Future<void> refresh() => _fetch(fromScratch: false);

  Future<void> _fetch({required bool fromScratch}) async {
    // Overlapping polls would apply two deltas computed from the same
    // checkpoint, and the later (staler) one would win.
    if (_inFlight) return;
    _inFlight = true;
    try {
      final session = await _storage.loadSession();
      final account = await _storage.loadAccount();
      if (session == null || account == null) {
        if (mounted) {
          state = const TeamTracksState(
            lastError: 'No active sector session.',
          );
        }
        return;
      }

      if (mounted && state.tracks.isEmpty) {
        state = state.copyWith(loading: true);
      }

      final since = fromScratch ? null : state.syncedAt;
      final snapshot = await _api.getSectorTracks(
        accountToken: account.accessToken,
        sectorId: session.sectorId,
        since: since,
      );
      if (!mounted) return;

      // A delta merges into what is already held; a full reload replaces it,
      // so a segment that was invalidated server-side (a Commander
      // retracting an implausible track) actually disappears rather than
      // lingering because no delta ever mentions it again.
      final merged = <String, TeamTrack>{
        if (since != null) ...state.tracks,
        for (final track in snapshot.tracks) track.segmentId: track,
      };

      state = TeamTracksState(
        tracks: merged,
        syncedAt: snapshot.serverTime,
      );
    } on ApiException catch (error) {
      // Keep whatever is already drawn. Losing the team's last known
      // positions because one poll 403'd or timed out is strictly worse
      // than showing a slightly stale picture, and the status bar already
      // reports the connection state.
      if (mounted) state = state.copyWith(loading: false, lastError: error.message);
    } on Exception catch (error) {
      if (mounted) state = state.copyWith(loading: false, lastError: '$error');
    } finally {
      _inFlight = false;
    }
  }
}
