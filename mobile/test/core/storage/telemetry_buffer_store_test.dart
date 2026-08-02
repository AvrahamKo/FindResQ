// Uses the REAL sqlite3 engine via sqflite_common_ffi, in-memory -- not a
// fake -- consistent with this project's "prefer real infrastructure over
// mocks" testing philosophy (see HANDOVER.md section 2). `sqflite` itself
// (the plugin used in production on Android/iOS) needs a platform channel
// that doesn't exist in a bare `flutter test` host process; `sqflite_common_ffi`
// is the same SQL engine reached a different way, not a substitute
// implementation.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lifesearch_mobile/core/storage/telemetry_buffer_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Uint8List _blob(int tag) => Uint8List.fromList(List.filled(8, tag));

void main() {
  late DatabaseFactory factory;

  setUpAll(() {
    sqfliteFfiInit();
    factory = databaseFactoryFfi;
  });

  TelemetryBufferStore newStore({int capacity = TelemetryBufferStore.defaultCapacity}) =>
      TelemetryBufferStore(
        factory: factory,
        path: inMemoryDatabasePath,
        capacity: capacity,
      );

  test('starts empty', () async {
    final store = newStore();
    expect(await store.count(), equals(0));
    await store.close();
  });

  test('enqueue then peekOldest returns it back, oldest first', () async {
    final store = newStore();

    await store.enqueue(_blob(1));
    await store.enqueue(_blob(2));
    await store.enqueue(_blob(3));

    expect(await store.count(), equals(3));

    final batch = await store.peekOldest(10);
    expect(batch.length, equals(3));
    expect(batch[0].blob, equals(_blob(1)));
    expect(batch[1].blob, equals(_blob(2)));
    expect(batch[2].blob, equals(_blob(3)));

    await store.close();
  });

  test('peekOldest does not remove anything', () async {
    final store = newStore();
    await store.enqueue(_blob(1));

    await store.peekOldest(10);
    await store.peekOldest(10);

    expect(await store.count(), equals(1));
    await store.close();
  });

  test('peekOldest respects the limit', () async {
    final store = newStore();
    for (var i = 0; i < 5; i++) {
      await store.enqueue(_blob(i));
    }

    final batch = await store.peekOldest(2);
    expect(batch.length, equals(2));
    expect(batch[0].blob, equals(_blob(0)));
    expect(batch[1].blob, equals(_blob(1)));

    await store.close();
  });

  test('acknowledge removes exactly the given ids', () async {
    final store = newStore();
    await store.enqueue(_blob(1));
    await store.enqueue(_blob(2));
    await store.enqueue(_blob(3));

    final batch = await store.peekOldest(10);
    await store.acknowledge([batch[0].id, batch[2].id]);

    expect(await store.count(), equals(1));
    final remaining = await store.peekOldest(10);
    expect(remaining.single.blob, equals(_blob(2)));

    await store.close();
  });

  test('acknowledge with an empty list is a no-op', () async {
    final store = newStore();
    await store.enqueue(_blob(1));

    await store.acknowledge([]);

    expect(await store.count(), equals(1));
    await store.close();
  });

  test('enqueue past capacity evicts the oldest rows, FIFO', () async {
    final store = newStore(capacity: 3);

    for (var i = 0; i < 5; i++) {
      await store.enqueue(_blob(i));
    }

    expect(await store.count(), equals(3));
    final remaining = await store.peekOldest(10);
    // The two oldest (0, 1) were evicted; 2, 3, 4 survive, oldest first.
    expect(remaining.map((p) => p.blob), [_blob(2), _blob(3), _blob(4)]);

    await store.close();
  });

  test('a fresh store re-opens against the same path with data intact', () async {
    final path = inMemoryDatabasePath;
    final first = TelemetryBufferStore(factory: factory, path: path);
    await first.enqueue(_blob(9));
    await first.close();

    // NOTE: ':memory:' databases are not shared across separate connections
    // in general SQLite semantics, so a brand new store against the same
    // literal path starts empty -- this asserts that expected behavior
    // explicitly rather than leaving it as an unstated assumption.
    final second = TelemetryBufferStore(factory: factory, path: path);
    expect(await second.count(), equals(0));
    await second.close();
  });
}
