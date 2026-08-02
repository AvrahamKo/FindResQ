import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lifesearch_mobile/core/api/api_client.dart';
import 'package:lifesearch_mobile/core/sos/sos_controller.dart';
import 'package:lifesearch_mobile/core/sos/sos_state.dart';
import 'package:lifesearch_mobile/core/storage/secure_storage_manager.dart';
import 'package:lifesearch_mobile/core/storage/stored_models.dart';

import '../../helpers/in_memory_key_value_store.dart';

http.Response _json(Object body, int status) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

Map<String, dynamic> _alertJson({String status = 'active', String id = 'alert-1'}) => {
  'id': id,
  'sector_id': 's1',
  'device_id': 'device-1',
  'user_id': 'u1',
  'status': status,
  'lat': 31.77,
  'lng': 35.21,
  'triggered_at': '2030-01-01T00:00:00Z',
  'acknowledged_at': null,
  'acknowledged_by': null,
  'resolved_at': null,
  'resolved_by': null,
  'cancelled_at': null,
  'updated_at': '2030-01-01T00:00:00Z',
};

class _Router {
  final Map<String, http.Response Function(http.Request)> _routes = {};

  void on(String method, String path, http.Response Function(http.Request) handler) {
    _routes['$method $path'] = handler;
  }

  Future<http.Response> call(http.Request request) async {
    final handler = _routes['${request.method} ${request.url.path}'];
    if (handler == null) {
      fail('unexpected request: ${request.method} ${request.url.path}');
    }
    return handler(request);
  }
}

Future<InMemoryKeyValueStore> _storeWithSession() async {
  final store = InMemoryKeyValueStore();
  final manager = SecureStorageManager(store);
  await manager.saveSession(
    StoredSession(
      accessToken: 'session-tok',
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
  return store;
}

SosController _buildController(_Router router, InMemoryKeyValueStore store) {
  final api = ApiClient(
    baseUrl: 'http://test.invalid',
    httpClient: MockClient(router.call),
  );
  return SosController(api: api, storage: SecureStorageManager(store));
}

void main() {
  group('trigger', () {
    test('moves to SosActive on success', () async {
      final router = _Router()
        ..on('POST', '/sos', (r) => _json(_alertJson(), 201));
      final controller = _buildController(router, await _storeWithSession());

      await controller.trigger();

      final state = controller.state;
      expect(state, isA<SosActive>());
      expect((state as SosActive).alert.id, equals('alert-1'));
      expect(state.alert.status, equals('active'));
    });

    test('fails when there is no active session', () async {
      final controller = _buildController(_Router(), InMemoryKeyValueStore());

      await controller.trigger();

      expect(controller.state, isA<SosError>());
    });

    test('a backend error produces SosError', () async {
      final router = _Router()
        ..on(
          'POST',
          '/sos',
          (r) => _json({
            'error': {'code': 'internal', 'message': 'boom'},
          }, 500),
        );
      final controller = _buildController(router, await _storeWithSession());

      await controller.trigger();

      final state = controller.state;
      expect(state, isA<SosError>());
      expect((state as SosError).message, equals('boom'));
    });

    test('calling trigger while already active is a no-op', () async {
      var requestCount = 0;
      final router = _Router()
        ..on('POST', '/sos', (r) {
          requestCount++;
          return _json(_alertJson(), 201);
        });
      final controller = _buildController(router, await _storeWithSession());

      await controller.trigger();
      await controller.trigger();

      expect(requestCount, equals(1));
    });
  });

  group('cancel', () {
    test('moves an active alert to SosIdle when the server cancels it', () async {
      final router = _Router()
        ..on('POST', '/sos', (r) => _json(_alertJson(), 201))
        ..on(
          'POST',
          '/sos/alert-1/cancel',
          (r) => _json(_alertJson(status: 'cancelled'), 200),
        );
      final controller = _buildController(router, await _storeWithSession());
      await controller.trigger();

      await controller.cancel();

      expect(controller.state, isA<SosIdle>());
    });

    test('is a no-op when nothing is active', () async {
      final controller = _buildController(_Router(), await _storeWithSession());

      await controller.cancel();

      expect(controller.state, isA<SosIdle>());
    });

    test('a cancel failure surfaces SosError but keeps the alert reachable', () async {
      final router = _Router()
        ..on('POST', '/sos', (r) => _json(_alertJson(), 201))
        ..on(
          'POST',
          '/sos/alert-1/cancel',
          (r) => _json({
            'error': {'code': 'conflict', 'message': 'already resolved'},
          }, 409),
        );
      final controller = _buildController(router, await _storeWithSession());
      await controller.trigger();

      await controller.cancel();

      final state = controller.state;
      expect(state, isA<SosError>());
      expect((state as SosError).previous, isA<SosActive>());
    });
  });

  test('reset returns to SosIdle', () async {
    final router = _Router()
      ..on(
        'POST',
        '/sos',
        (r) => _json({
          'error': {'code': 'internal', 'message': 'boom'},
        }, 500),
      );
    final controller = _buildController(router, await _storeWithSession());
    await controller.trigger();
    expect(controller.state, isA<SosError>());

    controller.reset();

    expect(controller.state, isA<SosIdle>());
  });
}
