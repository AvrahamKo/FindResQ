/// Local, capacity-bounded FIFO buffer for encrypted telemetry packets --
/// the offline fallback when there is no cellular connection to reach
/// `/ingest` directly. Built on `sqflite_common`'s [DatabaseFactory]
/// abstraction rather than the `sqflite` plugin directly, so the SAME code
/// runs against a real SQLite engine in both production (the `sqflite`
/// plugin's platform-channel-backed factory on Android/iOS) and tests (the
/// `sqflite_common_ffi` package's in-process factory) -- consistent with
/// this project's "prefer real infrastructure over mocks" testing
/// philosophy: nothing here is faked, only the factory implementation
/// differs.
///
/// Each packet is already a fully-formed encrypted blob by the time it
/// reaches [enqueue] (see `TelemetryPacketBuilder`); this store has no
/// knowledge of wire format, keys, or plaintext -- it just persists and
/// FIFO-evicts opaque bytes.
///
/// Capacity defaults to 10,000 packets per the original PRD. Enforcement is
/// FIFO eviction of the OLDEST rows, not a hard write failure: a searcher
/// who has been offline for hours should keep tracking (recent position is
/// what search planning needs most), not have tracking silently break
/// because a bound was hit.
library;

import 'dart:typed_data';

import 'package:sqflite_common/sqlite_api.dart';
import 'package:sqflite_common/utils/utils.dart';

class BufferedPacket {
  final int id;
  final Uint8List blob;
  final int createdAtMs;

  const BufferedPacket({
    required this.id,
    required this.blob,
    required this.createdAtMs,
  });
}

class TelemetryBufferStore {
  static const _table = 'telemetry_packets';
  static const defaultCapacity = 10000;

  final DatabaseFactory _factory;
  final String _path;
  final int _capacity;

  Database? _db;

  TelemetryBufferStore({
    required DatabaseFactory factory,
    required String path,
    int capacity = defaultCapacity,
  }) : _factory = factory,
       _path = path,
       _capacity = capacity;

  Future<Database> _open() async {
    final existing = _db;
    if (existing != null) return existing;

    final db = await _factory.openDatabase(
      _path,
      // singleInstance: false -- this store owns its connection's lifecycle
      // outright rather than sharing the factory's path-keyed instance
      // cache. Without this, two stores opened against the same literal
      // path (e.g. every test using `inMemoryDatabasePath`, ':memory:')
      // would silently share one underlying connection, so one test's data
      // leaks into the next depending on close()/open() timing -- exactly
      // the kind of cross-test nondeterminism this project's tests
      // otherwise avoid by using real, isolated infrastructure.
      options: OpenDatabaseOptions(
        version: 1,
        singleInstance: false,
        onCreate: (db, version) => db.execute(
          'CREATE TABLE $_table ('
          'id INTEGER PRIMARY KEY AUTOINCREMENT, '
          'created_at_ms INTEGER NOT NULL, '
          'blob BLOB NOT NULL'
          ')',
        ),
      ),
    );
    _db = db;
    return db;
  }

  /// Appends [blob] and, if that pushes the buffer over capacity, evicts
  /// however many of the OLDEST rows are needed to bring it back within
  /// bounds -- both in one transaction, so a crash mid-eviction can never
  /// leave the buffer over capacity.
  Future<void> enqueue(Uint8List blob) async {
    final db = await _open();
    await db.transaction((txn) async {
      await txn.insert(_table, {
        'created_at_ms': DateTime.now().millisecondsSinceEpoch,
        'blob': blob,
      });

      final total =
          firstIntValue(await txn.rawQuery('SELECT COUNT(*) FROM $_table')) ??
          0;
      final overflow = total - _capacity;
      if (overflow > 0) {
        await txn.delete(
          _table,
          where:
              'id IN (SELECT id FROM $_table ORDER BY id ASC LIMIT $overflow)',
        );
      }
    });
  }

  /// The oldest [limit] buffered packets, oldest first -- does NOT remove
  /// them. Phase 5d's upload path is expected to peek a batch, attempt the
  /// `/ingest` POST, and only [acknowledge] the ids that the server actually
  /// accepted, so a dropped connection mid-upload never silently loses
  /// buffered points.
  Future<List<BufferedPacket>> peekOldest(int limit) async {
    final db = await _open();
    final rows = await db.query(_table, orderBy: 'id ASC', limit: limit);
    return rows
        .map(
          (row) => BufferedPacket(
            id: row['id']! as int,
            blob: row['blob']! as Uint8List,
            createdAtMs: row['created_at_ms']! as int,
          ),
        )
        .toList();
  }

  Future<void> acknowledge(List<int> ids) async {
    if (ids.isEmpty) return;
    final db = await _open();
    final placeholders = List.filled(ids.length, '?').join(',');
    await db.delete(_table, where: 'id IN ($placeholders)', whereArgs: ids);
  }

  Future<int> count() async {
    final db = await _open();
    return firstIntValue(await db.rawQuery('SELECT COUNT(*) FROM $_table')) ??
        0;
  }

  Future<void> close() async {
    await _db?.close();
    _db = null;
  }
}
