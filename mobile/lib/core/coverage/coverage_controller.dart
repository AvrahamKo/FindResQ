import 'package:state_notifier/state_notifier.dart';

import '../api/api_client.dart';
import '../api/api_models.dart';
import '../storage/search_map_store.dart';
import '../storage/secure_storage_manager.dart';
import 'coverage_state.dart';

class CoverageController extends StateNotifier<CoverageMapState> {
  final ApiClient _api;
  final SecureStorageManager _storage;
  final SearchMapStore _mapStore;
  bool _refreshing = false;

  CoverageController({
    required ApiClient api,
    required SecureStorageManager storage,
    required SearchMapStore mapStore,
  }) : _api = api,
       _storage = storage,
       _mapStore = mapStore,
       super(const CoverageMapState(loading: true));

  Future<void> start() async {
    final session = await _storage.loadSession();
    if (session == null) {
      state = const CoverageMapState(lastError: 'No active sector session.');
      return;
    }

    final cached = await _mapStore.loadCoverage(session.sectorId);
    if (cached != null) {
      state = CoverageMapState(
        teamCells: cached.snapshot.cells,
        lastServerSyncAt: cached.syncedAt,
      );
    }

    // A full fetch on screen entry repairs any stale/incomplete old cache.
    // Subsequent calls use the database checkpoint and merge only deltas.
    await refresh(full: true);
  }

  Future<void> refresh({bool full = false}) async {
    if (_refreshing) return;
    _refreshing = true;
    try {
      final session = await _storage.loadSession();
      final account = await _storage.loadAccount();
      if (session == null || account == null) return;
      state = state.copyWith(loading: state.teamCells.isEmpty);
      final since = full ? null : state.lastServerSyncAt;
      final snapshot = await _api.getSectorCoverage(
        accountToken: account.accessToken,
        sectorId: session.sectorId,
        since: since,
      );

      final merged = <String, CoverageCell>{
        if (since != null)
          for (final cell in state.teamCells) cell.hexId: cell,
        for (final cell in snapshot.cells) cell.hexId: cell,
      };
      final checkpoint = snapshot.serverTime ?? DateTime.now().toUtc();
      final cachedSnapshot = CoverageSnapshot(
        sectorId: snapshot.sectorId,
        resolution: snapshot.resolution,
        cells: merged.values.toList(growable: false),
        serverTime: checkpoint,
      );
      await _mapStore.saveCoverage(cachedSnapshot, checkpoint);
      state = CoverageMapState(
        teamCells: cachedSnapshot.cells,
        lastServerSyncAt: checkpoint,
      );
    } catch (error) {
      // Keep the last cached snapshot visible while offline.
      state = state.copyWith(loading: false, lastError: '$error');
    } finally {
      _refreshing = false;
    }
  }
}
