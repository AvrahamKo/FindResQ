import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lifesearch_mobile/core/api/api_client.dart';
import 'package:lifesearch_mobile/core/coverage/team_tracks_controller.dart';
import 'package:lifesearch_mobile/core/storage/secure_storage_manager.dart';
import 'package:lifesearch_mobile/core/storage/stored_models.dart';

import '../../helpers/in_memory_key_value_store.dart';

http.Response _json(Object body, int status) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

Map<String, dynamic> _track({
  required String segmentId,
  required String userId,
  String? endedAt,
  int points = 2,
}) => {
  'segment_id': segmentId,
  'user_id': userId,
  'device_id': 'dev-$userId',
  'movement_mode': 'walker',
  'started_at': '2030-01-01T00:00:00Z',
  'ended_at': endedAt,
  'point_count': points,
  'points': List.generate(
    points,
    (i) => [31.70 + i * 0.001, 35.20 + i * 0.001],
  ),
};

Future<SecureStorageManager> _storageWithSession() async {
  final storage = SecureStorageManager(InMemoryKeyValueStore());
  await storage.saveAccount(
    StoredAccount(
      accessToken: 'acct-tok',
      expiresAt: DateTime.now().add(const Duration(days: 1)),
      userId: 'me',
      phoneE164: '+15551234567',
      displayName: 'Me',
    ),
  );
  await storage.saveSession(
    StoredSession(
      accessToken: 'sess-tok',
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
  return storage;
}

void main() {
  test('reload loads every teammate, not just this device', () async {
    final storage = await _storageWithSession();
    final controller = TeamTracksController(
      api: ApiClient(
        baseUrl: 'http://test.invalid',
        httpClient: MockClient(
          (r) async => _json({
            'sector_id': 's1',
            'tracks': [
              _track(segmentId: 'seg-a', userId: 'alice'),
              _track(segmentId: 'seg-b', userId: 'bob'),
              _track(segmentId: 'seg-c', userId: 'me'),
            ],
            'server_time': '2030-01-01T01:00:00Z',
          }, 200),
        ),
      ),
      storage: storage,
    );

    await controller.reload();

    expect(
      controller.state.tracks.values.map((t) => t.userId).toSet(),
      {'alice', 'bob', 'me'},
    );
    expect(controller.state.syncedAt, DateTime.parse('2030-01-01T01:00:00Z'));
  });

  test('a delta REPLACES a growing segment instead of duplicating it', () async {
    // The failure this guards against: a still-moving teammate is re-sent on
    // every poll with their full current polyline. Appending instead of
    // replacing would stack the same trail over and over.
    final storage = await _storageWithSession();
    var call = 0;
    final controller = TeamTracksController(
      api: ApiClient(
        baseUrl: 'http://test.invalid',
        httpClient: MockClient((r) async {
          call += 1;
          return _json({
            'sector_id': 's1',
            'tracks': [
              _track(segmentId: 'seg-a', userId: 'alice', points: call == 1 ? 2 : 5),
            ],
            'server_time': '2030-01-01T0$call:00:00Z',
          }, 200);
        }),
      ),
      storage: storage,
    );

    await controller.reload();
    expect(controller.state.tracks['seg-a']!.points.length, 2);

    await controller.refresh();

    expect(controller.state.tracks.length, 1);
    expect(controller.state.tracks['seg-a']!.points.length, 5);
  });

  test('a delta keeps segments it does not mention', () async {
    final storage = await _storageWithSession();
    var call = 0;
    final controller = TeamTracksController(
      api: ApiClient(
        baseUrl: 'http://test.invalid',
        httpClient: MockClient((r) async {
          call += 1;
          return _json({
            'sector_id': 's1',
            'tracks': call == 1
                ? [
                    _track(segmentId: 'seg-a', userId: 'alice'),
                    _track(segmentId: 'seg-b', userId: 'bob'),
                  ]
                // Bob has stopped moving, so he is absent from the delta --
                // his trail must stay on the map regardless.
                : [_track(segmentId: 'seg-a', userId: 'alice', points: 4)],
            'server_time': '2030-01-01T0$call:00:00Z',
          }, 200);
        }),
      ),
      storage: storage,
    );

    await controller.reload();
    await controller.refresh();

    expect(controller.state.tracks.keys.toSet(), {'seg-a', 'seg-b'});
  });

  test('reload drops a segment the server no longer returns', () async {
    // A full reload is authoritative: a segment invalidated server-side (a
    // Commander retracting an implausible track) must actually disappear,
    // which a delta merge alone would never do.
    final storage = await _storageWithSession();
    var call = 0;
    final controller = TeamTracksController(
      api: ApiClient(
        baseUrl: 'http://test.invalid',
        httpClient: MockClient((r) async {
          call += 1;
          return _json({
            'sector_id': 's1',
            'tracks': call == 1
                ? [
                    _track(segmentId: 'seg-a', userId: 'alice'),
                    _track(segmentId: 'seg-b', userId: 'bob'),
                  ]
                : [_track(segmentId: 'seg-a', userId: 'alice')],
            'server_time': '2030-01-01T0$call:00:00Z',
          }, 200);
        }),
      ),
      storage: storage,
    );

    await controller.reload();
    await controller.reload();

    expect(controller.state.tracks.keys.toSet(), {'seg-a'});
  });

  test('a failed poll keeps the last known picture on screen', () async {
    final storage = await _storageWithSession();
    var call = 0;
    final controller = TeamTracksController(
      api: ApiClient(
        baseUrl: 'http://test.invalid',
        httpClient: MockClient((r) async {
          call += 1;
          if (call > 1) {
            return _json({
              'error': {'code': 'unavailable', 'message': 'no uplink'},
            }, 503);
          }
          return _json({
            'sector_id': 's1',
            'tracks': [_track(segmentId: 'seg-a', userId: 'alice')],
            'server_time': '2030-01-01T01:00:00Z',
          }, 200);
        }),
      ),
      storage: storage,
    );

    await controller.reload();
    await controller.refresh();

    // Stale beats blank: losing teammates' last known positions because one
    // request timed out is worse than showing a slightly old picture.
    expect(controller.state.tracks.keys.toSet(), {'seg-a'});
    expect(controller.state.lastError, isNotNull);
  });

  test('reports no session rather than throwing when signed out', () async {
    final controller = TeamTracksController(
      api: ApiClient(
        baseUrl: 'http://test.invalid',
        httpClient: MockClient((r) async => fail('should not reach the network')),
      ),
      storage: SecureStorageManager(InMemoryKeyValueStore()),
    );

    await controller.reload();

    expect(controller.state.tracks, isEmpty);
    expect(controller.state.lastError, contains('No active sector session'));
  });

  test('ordered puts the newest traverse last so it paints on top', () async {
    final storage = await _storageWithSession();
    final controller = TeamTracksController(
      api: ApiClient(
        baseUrl: 'http://test.invalid',
        httpClient: MockClient(
          (r) async => _json({
            'sector_id': 's1',
            'tracks': [
              {
                ..._track(segmentId: 'old', userId: 'alice'),
                'started_at': '2030-01-01T00:00:00Z',
              },
              {
                ..._track(segmentId: 'new', userId: 'bob'),
                'started_at': '2030-01-01T05:00:00Z',
              },
            ],
            'server_time': '2030-01-01T06:00:00Z',
          }, 200),
        ),
      ),
      storage: storage,
    );

    await controller.reload();

    expect(
      controller.state.ordered.map((t) => t.segmentId),
      ['old', 'new'],
    );
  });
}
