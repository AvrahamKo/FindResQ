import 'package:flutter_test/flutter_test.dart';
import 'package:lifesearch_mobile/core/api/api_models.dart';
import 'package:lifesearch_mobile/core/storage/search_map_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late DatabaseFactory factory;

  setUpAll(() {
    sqfliteFfiInit();
    factory = databaseFactoryFfi;
  });

  SearchMapStore newStore({int trailCapacity = 5000}) => SearchMapStore(
    factory: factory,
    path: inMemoryDatabasePath,
    trailCapacity: trailCapacity,
  );

  test(
    'round-trips a team coverage snapshot and synchronization time',
    () async {
      final store = newStore();
      final syncedAt = DateTime(2026, 8, 5, 14, 30);
      const snapshot = CoverageSnapshot(
        sectorId: 's1',
        resolution: 12,
        cells: [
          CoverageCell(
            hexId: '8c2db2b25155dff',
            cumulativePod: 0.64,
            distinctSearchers: 2,
            lastContributionAt: null,
            boundary: [
              GeoPoint(latitude: 31.7, longitude: 35.2),
              GeoPoint(latitude: 31.8, longitude: 35.2),
              GeoPoint(latitude: 31.8, longitude: 35.3),
            ],
          ),
        ],
      );

      await store.saveCoverage(snapshot, syncedAt);
      final cached = await store.loadCoverage('s1');

      expect(cached, isNotNull);
      expect(cached!.syncedAt, syncedAt);
      expect(cached.snapshot.cells.single.hexId, '8c2db2b25155dff');
      expect(cached.snapshot.cells.single.boundary, hasLength(3));
      expect(cached.snapshot.cells.single.cumulativePod, 0.64);
      await store.close();
    },
  );

  test('personal trail is sector-scoped and evicts oldest points', () async {
    final store = newStore(trailCapacity: 2);
    for (var i = 0; i < 3; i++) {
      await store.appendTrailPoint(
        's1',
        PersonalTrackPoint(
          latitude: 31.7 + i / 1000,
          longitude: 35.2,
          accuracyM: 5,
          recordedAtMs: 1000 + i,
        ),
      );
    }
    await store.appendTrailPoint(
      's2',
      const PersonalTrackPoint(
        latitude: 32,
        longitude: 35,
        accuracyM: 6,
        recordedAtMs: 2000,
      ),
    );

    final sectorOne = await store.loadTrail('s1');
    final sectorTwo = await store.loadTrail('s2');
    expect(sectorOne.map((point) => point.recordedAtMs), [1001, 1002]);
    expect(sectorTwo, hasLength(1));
    expect(sectorTwo.single.latitude, 32);
    await store.close();
  });
}
