import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lifesearch_mobile/core/api/api_client.dart';
import 'package:lifesearch_mobile/core/join/join_controller.dart';
import 'package:lifesearch_mobile/core/join/join_state.dart';
import 'package:lifesearch_mobile/core/storage/secure_storage_manager.dart';
import 'package:lifesearch_mobile/core/storage/stored_models.dart';

import '../../helpers/in_memory_key_value_store.dart';

http.Response _json(Object body, int status) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

class _Router {
  final Map<String, http.Response Function(http.Request)> _routes = {};

  void on(String method, String pathPrefix, http.Response Function(http.Request) handler) {
    _routes['$method $pathPrefix'] = handler;
  }

  Future<http.Response> call(http.Request request) async {
    for (final entry in _routes.entries) {
      final parts = entry.key.split(' ');
      if (request.method == parts[0] && request.url.path.startsWith(parts[1])) {
        return entry.value(request);
      }
    }
    fail('unexpected request: ${request.method} ${request.url.path}');
  }
}

Future<InMemoryKeyValueStore> _signedInStore() async {
  final store = InMemoryKeyValueStore();
  final manager = SecureStorageManager(store);
  await manager.saveAccount(
    StoredAccount(
      accessToken: 'account-tok',
      expiresAt: DateTime.now().add(const Duration(days: 1)),
      userId: 'u1',
      phoneE164: '+15551234567',
      displayName: 'Test',
    ),
  );
  await manager.saveDeviceIdentity(
    const StoredDeviceIdentity(
      publicKeyBase64: 'pub==',
      secretKeyBase64: 'sec==',
      deviceId: 'device-1',
    ),
  );
  return store;
}

JoinController buildController(_Router router, InMemoryKeyValueStore store) {
  final api = ApiClient(
    baseUrl: 'http://test.invalid',
    httpClient: MockClient(router.call),
  );
  return JoinController(api: api, storage: SecureStorageManager(store));
}

void main() {
  group('submitJoinCode', () {
    test('moves to JoinPending, carrying the battery warning', () async {
      final router = _Router()
        ..on(
          'POST',
          '/join',
          (r) => _json({
            'membership_id': 'm1',
            'sector_id': 's1',
            'status': 'pending',
            'battery_warning': 'Battery is at 25%. Consider a power bank.',
          }, 201),
        );
      final controller = buildController(router, await _signedInStore());

      await controller.submitJoinCode(
        code: '123456',
        movementMode: 'walker',
        batteryPct: 25,
        powerbankAttested: false,
      );

      final state = controller.state;
      expect(state, isA<JoinPending>());
      expect((state as JoinPending).membershipId, equals('m1'));
      expect(state.batteryWarning, contains('25%'));
    });

    test('fails when not signed in on a registered device', () async {
      final controller = buildController(_Router(), InMemoryKeyValueStore());

      await controller.submitJoinCode(
        code: '123456',
        movementMode: 'walker',
        batteryPct: 80,
        powerbankAttested: false,
      );

      expect(controller.state, isA<JoinFailed>());
    });

    test('an invalid code produces JoinFailed with the backend message', () async {
      final router = _Router()
        ..on(
          'POST',
          '/join',
          (r) => _json({
            'error': {'code': 'unauthorized', 'message': 'invalid or expired join code'},
          }, 401),
        );
      final controller = buildController(router, await _signedInStore());

      await controller.submitJoinCode(
        code: '000000',
        movementMode: 'walker',
        batteryPct: 80,
        powerbankAttested: false,
      );

      final state = controller.state;
      expect(state, isA<JoinFailed>());
      expect((state as JoinFailed).message, equals('invalid or expired join code'));
    });
  });

  group('pollOnce', () {
    Future<JoinController> pendingController(_Router router) async {
      final joinRouter = _Router()
        ..on(
          'POST',
          '/join',
          (r) => _json({
            'membership_id': 'm1',
            'sector_id': 's1',
            'status': 'pending',
          }, 201),
        );
      for (final entry in router._routes.entries) {
        joinRouter._routes[entry.key] = entry.value;
      }
      final controller = buildController(joinRouter, await _signedInStore());
      await controller.submitJoinCode(
        code: '123456',
        movementMode: 'walker',
        batteryPct: 80,
        powerbankAttested: false,
      );
      expect(controller.state, isA<JoinPending>());
      return controller;
    }

    test('stays JoinPending while status is still pending', () async {
      final router = _Router()
        ..on(
          'GET',
          '/memberships/',
          (r) => _json({
            'id': 'm1',
            'sector_id': 's1',
            'status': 'pending',
            'role': 'volunteer',
            'movement_mode': 'walker',
            'session_expires_at': null,
          }, 200),
        );
      final controller = await pendingController(router);

      await controller.pollOnce();

      expect(controller.state, isA<JoinPending>());
    });

    test('moves to JoinApproved, carrying role and movement mode', () async {
      final router = _Router()
        ..on(
          'GET',
          '/memberships/',
          (r) => _json({
            'id': 'm1',
            'sector_id': 's1',
            'status': 'approved',
            'role': 'lead',
            'movement_mode': 'vehicle',
            'session_expires_at': '2030-01-01T00:00:00Z',
          }, 200),
        );
      final controller = await pendingController(router);

      await controller.pollOnce();

      final state = controller.state;
      expect(state, isA<JoinApproved>());
      expect((state as JoinApproved).role, equals('lead'));
      expect(state.movementMode, equals('vehicle'));
    });

    test('moves to JoinRejected', () async {
      final router = _Router()
        ..on(
          'GET',
          '/memberships/',
          (r) => _json({
            'id': 'm1',
            'sector_id': 's1',
            'status': 'rejected',
            'role': 'volunteer',
            'movement_mode': 'walker',
          }, 200),
        );
      final controller = await pendingController(router);

      await controller.pollOnce();

      expect(controller.state, isA<JoinRejected>());
    });

    test('moves to JoinRevoked on revoked or ended', () async {
      final router = _Router()
        ..on(
          'GET',
          '/memberships/',
          (r) => _json({
            'id': 'm1',
            'sector_id': 's1',
            'status': 'ended',
            'role': 'volunteer',
            'movement_mode': 'walker',
          }, 200),
        );
      final controller = await pendingController(router);

      await controller.pollOnce();

      expect(controller.state, isA<JoinRevoked>());
    });

    test('a transient 500 does not knock the user out of JoinPending', () async {
      final router = _Router()
        ..on(
          'GET',
          '/memberships/',
          (r) => _json({
            'error': {'code': 'internal', 'message': 'boom'},
          }, 500),
        );
      final controller = await pendingController(router);

      await controller.pollOnce();

      expect(controller.state, isA<JoinPending>());
    });

    test('a 4xx failure (not 500) does move to JoinFailed', () async {
      final router = _Router()
        ..on(
          'GET',
          '/memberships/',
          (r) => _json({
            'error': {'code': 'forbidden', 'message': 'no longer your membership'},
          }, 403),
        );
      final controller = await pendingController(router);

      await controller.pollOnce();

      expect(controller.state, isA<JoinFailed>());
    });
  });

  group('claimSession', () {
    test('persists the session and moves to JoinSessionActive', () async {
      final store = await _signedInStore();
      final router = _Router()
        ..on(
          'POST',
          '/join',
          (r) => _json({
            'membership_id': 'm1',
            'sector_id': 's1',
            'status': 'pending',
          }, 201),
        )
        ..on(
          'GET',
          '/memberships/',
          (r) => _json({
            'id': 'm1',
            'sector_id': 's1',
            'status': 'approved',
            'role': 'volunteer',
            'movement_mode': 'walker',
          }, 200),
        )
        ..on(
          'POST',
          '/memberships/m1/session',
          (r) => _json({
            'access_token': 'session-tok',
            'token_type': 'Bearer',
            'expires_at': '2030-01-01T00:00:00Z',
            'key_epoch': 3,
            'sector_key': 'a2V5Ynl0ZXM=',
            'sector': {
              'id': 's1',
              'event_id': 'e1',
              'name': 'North Ridge',
              'status': 'open',
            },
          }, 200),
        );

      final controller = buildController(router, store);
      await controller.submitJoinCode(
        code: '123456',
        movementMode: 'walker',
        batteryPct: 80,
        powerbankAttested: false,
      );
      await controller.pollOnce();
      expect(controller.state, isA<JoinApproved>());

      await controller.claimSession();

      final state = controller.state;
      expect(state, isA<JoinSessionActive>());
      expect((state as JoinSessionActive).sectorName, equals('North Ridge'));

      final session = await SecureStorageManager(store).loadSession();
      expect(session?.accessToken, equals('session-tok'));
      expect(session?.sectorKeyBase64, equals('a2V5Ynl0ZXM='));
      expect(session?.keyEpoch, equals(3));
      expect(session?.role, equals('volunteer'));
      expect(session?.movementMode, equals('walker'));
    });
  });

  test('reset returns to JoinIdle', () async {
    final controller = buildController(_Router(), await _signedInStore());
    controller.reset();
    expect(controller.state, isA<JoinIdle>());
  });
}
