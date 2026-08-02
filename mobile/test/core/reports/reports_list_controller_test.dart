import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lifesearch_mobile/core/api/api_client.dart';
import 'package:lifesearch_mobile/core/reports/reports_list_controller.dart';
import 'package:lifesearch_mobile/core/reports/reports_list_state.dart';
import 'package:lifesearch_mobile/core/storage/secure_storage_manager.dart';
import 'package:lifesearch_mobile/core/storage/stored_models.dart';

import '../../helpers/in_memory_key_value_store.dart';

http.Response _json(Object body, int status) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

Map<String, dynamic> _reportJson({String status = 'open', String id = 'report-1'}) => {
  'id': id,
  'sector_id': 's1',
  'device_id': 'device-1',
  'user_id': 'u1',
  'kind': 'hazard',
  'lat': 31.7715,
  'lng': 35.2170,
  'note': 'test',
  'recorded_at': '2030-01-01T00:00:00Z',
  'received_at': '2030-01-01T00:00:01Z',
  'delivery_path': 'direct',
  'status': status,
  'acknowledged_by': null,
  'acknowledged_at': null,
  'updated_at': '2030-01-01T00:00:01Z',
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
      userId: 'user-1',
      phoneE164: '+15551234567',
      displayName: 'Test User',
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
      role: 'volunteer',
      movementMode: 'walker',
    ),
  );
  return store;
}

ReportsListController _buildController(_Router router, InMemoryKeyValueStore store) {
  final api = ApiClient(
    baseUrl: 'http://test.invalid',
    httpClient: MockClient(router.call),
  );
  return ReportsListController(api: api, storage: SecureStorageManager(store));
}

void main() {
  group('load', () {
    test('populates ReportsListLoaded with the sector\'s reports', () async {
      final router = _Router()
        ..on(
          'GET',
          '/sectors/s1/reports',
          (r) => http.Response(
            jsonEncode([_reportJson(), _reportJson(id: 'report-2', status: 'acknowledged')]),
            200,
            headers: {'content-type': 'application/json'},
          ),
        );
      final controller = _buildController(router, await _storeSignedInWithSession());

      await controller.load();

      final state = controller.state;
      expect(state, isA<ReportsListLoaded>());
      expect((state as ReportsListLoaded).reports, hasLength(2));
    });

    test('fails when not signed in to a sector', () async {
      final controller = _buildController(_Router(), InMemoryKeyValueStore());

      await controller.load();

      expect(controller.state, isA<ReportsListFailed>());
    });

    test('a 403 surfaces as ReportsListFailed', () async {
      final router = _Router()
        ..on(
          'GET',
          '/sectors/s1/reports',
          (r) => _json({
            'error': {'code': 'forbidden', 'message': 'you have no role in this sector'},
          }, 403),
        );
      final controller = _buildController(router, await _storeSignedInWithSession());

      await controller.load();

      expect(controller.state, isA<ReportsListFailed>());
    });
  });

  group('acknowledge', () {
    test('acknowledges then reloads the list', () async {
      var loadCount = 0;
      final router = _Router()
        ..on('GET', '/sectors/s1/reports', (r) {
          loadCount++;
          final status = loadCount == 1 ? 'open' : 'acknowledged';
          return http.Response(
            jsonEncode([_reportJson(status: status)]),
            200,
            headers: {'content-type': 'application/json'},
          );
        })
        ..on(
          'POST',
          '/reports/report-1/acknowledge',
          (r) => _json(_reportJson(status: 'acknowledged'), 200),
        );
      final controller = _buildController(router, await _storeSignedInWithSession());
      await controller.load();

      await controller.acknowledge('report-1');

      final state = controller.state as ReportsListLoaded;
      expect(state.reports.single.status, equals('acknowledged'));
      expect(loadCount, equals(2), reason: 'acknowledge must trigger a reload');
    });
  });
}
