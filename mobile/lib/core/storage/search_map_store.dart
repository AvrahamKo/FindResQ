/// Persistent offline cache for the tactical map.
///
/// Team coverage is a replaceable server snapshot; the personal trail is an
/// append-only, capacity-bounded local record. Neither belongs in Secure
/// Storage (coverage snapshots can be large), and neither is mixed into the
/// encrypted upload FIFO, whose acknowledgement semantics are different.
library;

import 'dart:convert';

import 'package:sqflite_common/sqlite_api.dart';

import '../api/api_models.dart';

class CachedCoverage {
  final CoverageSnapshot snapshot;
  final DateTime syncedAt;

  const CachedCoverage({required this.snapshot, required this.syncedAt});
}

class PersonalTrackPoint {
  final double latitude;
  final double longitude;
  final double accuracyM;
  final int recordedAtMs;

  const PersonalTrackPoint({
    required this.latitude,
    required this.longitude,
    required this.accuracyM,
    required this.recordedAtMs,
  });
}

class SearchMapStore {
  static const defaultTrailCapacity = 5000;
  static const _coverageTable = 'coverage_snapshots';
  static const _trailTable = 'personal_trail';

  final DatabaseFactory _factory;
  final String _path;
  final int _trailCapacity;
  Database? _db;

  SearchMapStore({
    required DatabaseFactory factory,
    required String path,
    int trailCapacity = defaultTrailCapacity,
  }) : _factory = factory,
       _path = path,
       _trailCapacity = trailCapacity;

  Future<Database> _open() async {
    final existing = _db;
    if (existing != null) return existing;
    final db = await _factory.openDatabase(
      _path,
      options: OpenDatabaseOptions(
        version: 1,
        singleInstance: false,
        onCreate: (db, version) async {
          await db.execute(
            'CREATE TABLE $_coverageTable ('
            'sector_id TEXT PRIMARY KEY, '
            'synced_at_ms INTEGER NOT NULL, '
            'snapshot_json TEXT NOT NULL'
            ')',
          );
          await db.execute(
            'CREATE TABLE $_trailTable ('
            'id INTEGER PRIMARY KEY AUTOINCREMENT, '
            'sector_id TEXT NOT NULL, '
            'recorded_at_ms INTEGER NOT NULL, '
            'lat REAL NOT NULL, '
            'lng REAL NOT NULL, '
            'accuracy_m REAL NOT NULL'
            ')',
          );
          await db.execute(
            'CREATE INDEX personal_trail_sector_time_idx '
            'ON $_trailTable (sector_id, recorded_at_ms)',
          );
        },
      ),
    );
    _db = db;
    return db;
  }

  Future<CachedCoverage?> loadCoverage(String sectorId) async {
    final db = await _open();
    final rows = await db.query(
      _coverageTable,
      where: 'sector_id = ?',
      whereArgs: [sectorId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final row = rows.single;
    return CachedCoverage(
      snapshot: CoverageSnapshot.fromJson(
        jsonDecode(row['snapshot_json']! as String) as Map<String, dynamic>,
      ),
      syncedAt: DateTime.fromMillisecondsSinceEpoch(
        row['synced_at_ms']! as int,
      ),
    );
  }

  Future<void> saveCoverage(
    CoverageSnapshot snapshot,
    DateTime syncedAt,
  ) async {
    final db = await _open();
    await db.insert(_coverageTable, {
      'sector_id': snapshot.sectorId,
      'synced_at_ms': syncedAt.millisecondsSinceEpoch,
      'snapshot_json': jsonEncode(snapshot.toJson()),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<List<PersonalTrackPoint>> loadTrail(String sectorId) async {
    final db = await _open();
    final rows = await db.query(
      _trailTable,
      where: 'sector_id = ?',
      whereArgs: [sectorId],
      orderBy: 'recorded_at_ms ASC, id ASC',
    );
    return rows
        .map(
          (row) => PersonalTrackPoint(
            latitude: row['lat']! as double,
            longitude: row['lng']! as double,
            accuracyM: row['accuracy_m']! as double,
            recordedAtMs: row['recorded_at_ms']! as int,
          ),
        )
        .toList(growable: false);
  }

  Future<void> appendTrailPoint(
    String sectorId,
    PersonalTrackPoint point,
  ) async {
    final db = await _open();
    await db.transaction((txn) async {
      await txn.insert(_trailTable, {
        'sector_id': sectorId,
        'recorded_at_ms': point.recordedAtMs,
        'lat': point.latitude,
        'lng': point.longitude,
        'accuracy_m': point.accuracyM,
      });
      await txn.rawDelete(
        'DELETE FROM $_trailTable WHERE id IN ('
        'SELECT id FROM $_trailTable WHERE sector_id = ? '
        'ORDER BY recorded_at_ms DESC, id DESC LIMIT -1 OFFSET ?'
        ')',
        [sectorId, _trailCapacity],
      );
    });
  }

  Future<void> close() async {
    await _db?.close();
    _db = null;
  }
}
