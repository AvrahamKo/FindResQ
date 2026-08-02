// IngestSyncController orchestration: real SQLite buffer (sqflite_common_ffi,
// in-memory), real SecureStorageManager over an in-memory KeyValueStore --
// only the HTTP transport is mocked (via `http`'s MockClient), matching this
// project's "only mock at the outermost I/O boundary" philosophy. Mirrors
// `location_tracking_controller_test.dart`'s harness shape.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lifesearch_mobile/core/api/api_client.dart';
import 'package:lifesearch_mobile/core/storage/secure_storage_manager.dart';
import 'package:lifesearch_mobile/core/storage/stored_models.dart';
import 'package:lifesearch_mobile/core/storage/telemetry_buffer_store.dart';
import 'package:lifesearch_mobile/core/sync/ingest_sync_controller.dart';
import 'package:lifesearch_mobile/core/sync/sync_backoff_policy.dart';
import 'package:lifesearch_mobile/core/sync/sync_state.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../helpers/in_memory_key_value_store.dart';

http.Response _json(Object body, int status) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

Map<String, dynamic> _ingestCounts({
  int accepted = 0,
  int duplicate = 0,
  int decryptFailed = 0,
  int signatureInvalid = 0,
  int wrongDevice = 0,
  int malformed = 0,
  int hexesTouched = 0,
}) => {
  'accepted': accepted,
  'duplicate': duplicate,
  'decrypt_failed': decryptFailed,
  'signature_invalid': signatureInvalid,
  'wrong_device': wrongDevice,
  'malformed': malformed,
  'segments_opened': 0,
  'segments_extended': 0,
  'segments_closed': 0,
  'hexes_touched': hexesTouched,
};

Future<SecureStorageManager> _storageWithSession({String token = 'session-tok'}) async {
  final store = InMemoryKeyValueStore();
  final manager = SecureStorageManager(store);
  await manager.saveSession(
    StoredSession(
      accessToken: token,
      expiresAt: DateTime.now().add(const Duration(hours: 8)),
      keyEpoch: 1,
      sectorKeyBase64: 'a2V5Ynl0ZXM=',
      membershipId: 'm1',
      sectorId: 's1',
      eventId: 'e1',
      role: 'volunteer',
      movementMode: 'walker',
    ),
  );
  return manager;
}

TelemetryBufferStore _buildBuffer() =>
    TelemetryBufferStore(factory: databaseFactoryFfi, path: inMemoryDatabasePath);

Future<void> _seedPackets(TelemetryBufferStore buffer, int count) async {
  for (var i = 0; i < count; i++) {
    await buffer.enqueue(Uint8List.fromList(List.filled(8, i)));
  }
}

/// Polls [controller]'s state for real -- see
/// `location_tracking_controller_test.dart`'s identical helper for why:
/// `_tick()`'s continuation isn't something the caller can just `await`
/// when driven off a `Timer`, so tests wait on the observable result
/// instead of guessing how many event-loop turns are enough.
Future<void> _waitForState(
  IngestSyncController controller,
  bool Function(SyncState) predicate, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!predicate(controller.state)) {
    if (DateTime.now().isAfter(deadline)) {
      fail('state never matched predicate -- stuck at ${controller.state}');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
  });

  group('syncOnce', () {
    test('no active session yields SyncError and makes no request', () async {
      final buffer = _buildBuffer();
      await _seedPackets(buffer, 2);
      var requestCount = 0;
      final api = ApiClient(
        baseUrl: 'http://test.invalid',
        httpClient: MockClient((r) async {
          requestCount++;
          return _json(_ingestCounts(), 200);
        }),
      );
      final controller = IngestSyncController(
        api: api,
        storage: SecureStorageManager(InMemoryKeyValueStore()),
        buffer: buffer,
      );

      await controller.syncOnce();

      expect(controller.state, isA<SyncError>());
      expect(requestCount, equals(0));
      await buffer.close();
    });

    test('an empty buffer makes no request and reports zero pending', () async {
      final buffer = _buildBuffer();
      var requestCount = 0;
      final api = ApiClient(
        baseUrl: 'http://test.invalid',
        httpClient: MockClient((r) async {
          requestCount++;
          return _json(_ingestCounts(), 200);
        }),
      );
      final controller = IngestSyncController(
        api: api,
        storage: await _storageWithSession(),
        buffer: buffer,
      );

      await controller.syncOnce();

      expect(requestCount, equals(0));
      final state = controller.state as SyncActive;
      expect(state.pendingCount, equals(0));
      await buffer.close();
    });

    test('a successful upload acknowledges the whole batch and updates totals', () async {
      final buffer = _buildBuffer();
      await _seedPackets(buffer, 3);
      http.Request? captured;
      final api = ApiClient(
        baseUrl: 'http://test.invalid',
        httpClient: MockClient((r) async {
          captured = r;
          return _json(_ingestCounts(accepted: 2, duplicate: 1, hexesTouched: 5), 200);
        }),
      );
      final controller = IngestSyncController(
        api: api,
        storage: await _storageWithSession(token: 'session-tok'),
        buffer: buffer,
      );

      await controller.syncOnce();

      expect(captured!.headers['Authorization'], equals('Bearer session-tok'));
      final sentBlobs = (jsonDecode(captured!.body) as Map)['blobs'] as List;
      expect(sentBlobs, hasLength(3));

      expect(await buffer.count(), equals(0), reason: 'whole batch acknowledged on 200');

      final state = controller.state as SyncActive;
      expect(state.pendingCount, equals(0));
      expect(state.totalUploaded, equals(2));
      expect(state.totalRejected, equals(1));
      expect(state.consecutiveFailures, equals(0));
      expect(state.lastError, isNull);
      await buffer.close();
    });

    test('rejected-but-terminal blobs (malformed/duplicate/etc) are still acknowledged, not retried', () async {
      // The whole point of IngestResult.rejected: a decrypt failure or bad
      // signature will fail identically forever, so it must not stay stuck
      // in the buffer being retried on every tick.
      final buffer = _buildBuffer();
      await _seedPackets(buffer, 2);
      final api = ApiClient(
        baseUrl: 'http://test.invalid',
        httpClient: MockClient(
          (r) async => _json(_ingestCounts(malformed: 1, decryptFailed: 1), 200),
        ),
      );
      final controller = IngestSyncController(
        api: api,
        storage: await _storageWithSession(),
        buffer: buffer,
      );

      await controller.syncOnce();

      expect(await buffer.count(), equals(0));
      final state = controller.state as SyncActive;
      expect(state.totalUploaded, equals(0));
      expect(state.totalRejected, equals(2));
      await buffer.close();
    });

    test('a server error leaves the batch buffered and records a failure', () async {
      final buffer = _buildBuffer();
      await _seedPackets(buffer, 3);
      final api = ApiClient(
        baseUrl: 'http://test.invalid',
        httpClient: MockClient(
          (r) async => _json({
            'error': {'code': 'internal', 'message': 'boom'},
          }, 500),
        ),
      );
      final controller = IngestSyncController(
        api: api,
        storage: await _storageWithSession(),
        buffer: buffer,
      );

      await controller.syncOnce();

      expect(await buffer.count(), equals(3), reason: 'nothing acknowledged on failure');
      final state = controller.state as SyncActive;
      expect(state.pendingCount, equals(3));
      expect(state.consecutiveFailures, equals(1));
      expect(state.lastError, contains('boom'));
      await buffer.close();
    });

    test('a network-level failure (no valid response) also backs off without losing data', () async {
      final buffer = _buildBuffer();
      await _seedPackets(buffer, 2);
      final api = ApiClient(
        baseUrl: 'http://test.invalid',
        httpClient: MockClient(
          (r) async => http.Response('<html>502 Bad Gateway</html>', 502),
        ),
      );
      final controller = IngestSyncController(
        api: api,
        storage: await _storageWithSession(),
        buffer: buffer,
      );

      await controller.syncOnce();

      expect(await buffer.count(), equals(2));
      final state = controller.state as SyncActive;
      expect(state.consecutiveFailures, equals(1));
      await buffer.close();
    });

    test('consecutive failures accumulate across repeated calls, then reset on success', () async {
      final buffer = _buildBuffer();
      await _seedPackets(buffer, 1);
      var shouldFail = true;
      final api = ApiClient(
        baseUrl: 'http://test.invalid',
        httpClient: MockClient((r) async {
          if (shouldFail) {
            return _json({
              'error': {'code': 'internal', 'message': 'still down'},
            }, 500);
          }
          return _json(_ingestCounts(accepted: 1), 200);
        }),
      );
      final controller = IngestSyncController(
        api: api,
        storage: await _storageWithSession(),
        buffer: buffer,
      );

      await controller.syncOnce();
      expect((controller.state as SyncActive).consecutiveFailures, equals(1));
      await controller.syncOnce();
      expect((controller.state as SyncActive).consecutiveFailures, equals(2));
      await controller.syncOnce();
      expect((controller.state as SyncActive).consecutiveFailures, equals(3));

      shouldFail = false;
      await controller.syncOnce();
      final state = controller.state as SyncActive;
      expect(state.consecutiveFailures, equals(0));
      expect(state.totalUploaded, equals(1));
      await buffer.close();
    });

    test('only batchSize packets are sent per attempt', () async {
      final buffer = _buildBuffer();
      await _seedPackets(buffer, 5);
      http.Request? captured;
      final api = ApiClient(
        baseUrl: 'http://test.invalid',
        httpClient: MockClient((r) async {
          captured = r;
          return _json(_ingestCounts(accepted: 2), 200);
        }),
      );
      final controller = IngestSyncController(
        api: api,
        storage: await _storageWithSession(),
        buffer: buffer,
        batchSize: 2,
      );

      await controller.syncOnce();

      final sentBlobs = (jsonDecode(captured!.body) as Map)['blobs'] as List;
      expect(sentBlobs, hasLength(2));
      expect(await buffer.count(), equals(3), reason: 'un-batched packets stay buffered');
      await buffer.close();
    });
  });

  group('start/stop self-scheduling', () {
    test('start() uploads buffered packets automatically without manual syncOnce calls', () async {
      final buffer = _buildBuffer();
      await _seedPackets(buffer, 1);
      var requestCount = 0;
      final api = ApiClient(
        baseUrl: 'http://test.invalid',
        httpClient: MockClient((r) async {
          requestCount++;
          return _json(_ingestCounts(accepted: 1), 200);
        }),
      );
      final controller = IngestSyncController(
        api: api,
        storage: await _storageWithSession(),
        buffer: buffer,
        baseInterval: const Duration(milliseconds: 20),
        backoff: const SyncBackoffPolicy(
          initialBackoff: Duration(milliseconds: 10),
          maxBackoff: Duration(milliseconds: 50),
        ),
      );

      await controller.start();
      await _waitForState(controller, (s) => s is SyncActive && s.totalUploaded == 1);

      expect(await buffer.count(), equals(0));
      expect(requestCount, greaterThanOrEqualTo(1));

      controller.stop();
      expect(controller.state, isA<SyncIdle>());
    });

    test('automatically retries after a transient failure and recovers', () async {
      final buffer = _buildBuffer();
      await _seedPackets(buffer, 1);
      var failuresLeft = 2;
      final api = ApiClient(
        baseUrl: 'http://test.invalid',
        httpClient: MockClient((r) async {
          if (failuresLeft > 0) {
            failuresLeft--;
            return _json({
              'error': {'code': 'internal', 'message': 'flaky'},
            }, 500);
          }
          return _json(_ingestCounts(accepted: 1), 200);
        }),
      );
      final controller = IngestSyncController(
        api: api,
        storage: await _storageWithSession(),
        buffer: buffer,
        baseInterval: const Duration(milliseconds: 20),
        backoff: const SyncBackoffPolicy(
          initialBackoff: Duration(milliseconds: 10),
          maxBackoff: Duration(milliseconds: 30),
        ),
      );

      await controller.start();
      await _waitForState(
        controller,
        (s) => s is SyncActive && s.totalUploaded == 1,
        timeout: const Duration(seconds: 5),
      );

      expect(await buffer.count(), equals(0));
      controller.stop();
    });

    test('stop() halts further requests', () async {
      final buffer = _buildBuffer();
      await _seedPackets(buffer, 1);
      var requestCount = 0;
      final api = ApiClient(
        baseUrl: 'http://test.invalid',
        httpClient: MockClient((r) async {
          requestCount++;
          return _json(_ingestCounts(accepted: 1), 200);
        }),
      );
      final controller = IngestSyncController(
        api: api,
        storage: await _storageWithSession(),
        buffer: buffer,
        baseInterval: const Duration(milliseconds: 15),
      );

      await controller.start();
      await _waitForState(controller, (s) => s is SyncActive && s.totalUploaded == 1);
      controller.stop();
      final countAfterStop = requestCount;

      // Give any wrongly-still-scheduled tick a real chance to fire.
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(requestCount, equals(countAfterStop));
      expect(controller.state, isA<SyncIdle>());
    });

    test('calling start() while already running is a no-op', () async {
      final buffer = _buildBuffer();
      final api = ApiClient(
        baseUrl: 'http://test.invalid',
        httpClient: MockClient((r) async => _json(_ingestCounts(), 200)),
      );
      final controller = IngestSyncController(
        api: api,
        storage: await _storageWithSession(),
        buffer: buffer,
        baseInterval: const Duration(seconds: 30),
      );

      await controller.start();
      await controller.start();

      controller.stop();
      await buffer.close();
    });
  });
}
