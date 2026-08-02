import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lifesearch_mobile/core/api/api_client.dart';
import 'package:lifesearch_mobile/core/sos/sos_alerts_controller.dart';
import 'package:lifesearch_mobile/core/sos/sos_alerts_state.dart';
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

Future<InMemoryKeyValueStore> _storeSignedInWithSession() async {
  final store = InMemoryKeyValueStore();
  final manager = SecureStorageManager(store);
  await manager.saveAccount(
    StoredAccount(
      accessToken: 'account-tok',
      expiresAt: DateTime.now().add(const Duration(days: 1)),
      userId: 'lead-1',
      phoneE164: '+15551234567',
      displayName: 'Test Lead',
    ),
  );
  await manager.saveSession(
    StoredSession(
      accessToken: 'session-tok',
      expiresAt: DateTime.now().add(const Duration(hours: 8)),
      keyEpoch: 1,
      sectorKeyBase64: 'a2V5Ynl0ZXM=',
      membershipId: 'm1',
      sectorId: 's1',
      eventId: 'e1',
      role: 'lead',
      movementMode: 'walker',
    ),
  );
  return store;
}

SosAlertsController _buildController(_Router router, InMemoryKeyValueStore store) {
  final api = ApiClient(
    baseUrl: 'http://test.invalid',
    httpClient: MockClient(router.call),
  );
  return SosAlertsController(api: api, storage: SecureStorageManager(store));
}

void main() {
  group('load', () {
    test('populates SosAlertsLoaded with the sector\'s alerts', () async {
      final router = _Router()
        ..on(
          'GET',
          '/sectors/s1/sos',
          (r) => http.Response(
            jsonEncode([_alertJson(), _alertJson(id: 'alert-2', status: 'resolved')]),
            200,
            headers: {'content-type': 'application/json'},
          ),
        );
      final controller = _buildController(router, await _storeSignedInWithSession());

      await controller.load();

      final state = controller.state;
      expect(state, isA<SosAlertsLoaded>());
      expect((state as SosAlertsLoaded).alerts, hasLength(2));
    });

    test('fails when not signed in to a sector', () async {
      final controller = _buildController(_Router(), InMemoryKeyValueStore());

      await controller.load();

      expect(controller.state, isA<SosAlertsFailed>());
    });

    test('a 403 (not lead/commander) surfaces as SosAlertsFailed', () async {
      final router = _Router()
        ..on(
          'GET',
          '/sectors/s1/sos',
          (r) => _json({
            'error': {'code': 'forbidden', 'message': 'only this sector\'s lead can do this'},
          }, 403),
        );
      final controller = _buildController(router, await _storeSignedInWithSession());

      await controller.load();

      final state = controller.state;
      expect(state, isA<SosAlertsFailed>());
      expect((state as SosAlertsFailed).message, contains('lead'));
    });
  });

  group('acknowledge', () {
    test('acknowledges then reloads the list', () async {
      var loadCount = 0;
      final router = _Router()
        ..on('GET', '/sectors/s1/sos', (r) {
          loadCount++;
          final status = loadCount == 1 ? 'active' : 'acknowledged';
          return http.Response(
            jsonEncode([_alertJson(status: status)]),
            200,
            headers: {'content-type': 'application/json'},
          );
        })
        ..on(
          'POST',
          '/sos/alert-1/acknowledge',
          (r) => _json(_alertJson(status: 'acknowledged'), 200),
        );
      final controller = _buildController(router, await _storeSignedInWithSession());
      await controller.load();

      await controller.acknowledge('alert-1');

      final state = controller.state as SosAlertsLoaded;
      expect(state.alerts.single.status, equals('acknowledged'));
      expect(loadCount, equals(2), reason: 'acknowledge must trigger a reload');
    });
  });

  group('resolve', () {
    test('resolves then reloads the list', () async {
      var loadCount = 0;
      final router = _Router()
        ..on('GET', '/sectors/s1/sos', (r) {
          loadCount++;
          final status = loadCount == 1 ? 'acknowledged' : 'resolved';
          return http.Response(
            jsonEncode([_alertJson(status: status)]),
            200,
            headers: {'content-type': 'application/json'},
          );
        })
        ..on(
          'POST',
          '/sos/alert-1/resolve',
          (r) => _json(_alertJson(status: 'resolved'), 200),
        );
      final controller = _buildController(router, await _storeSignedInWithSession());
      await controller.load();

      await controller.resolve('alert-1');

      final state = controller.state as SosAlertsLoaded;
      expect(state.alerts.single.status, equals('resolved'));
      expect(loadCount, equals(2));
    });
  });
}
