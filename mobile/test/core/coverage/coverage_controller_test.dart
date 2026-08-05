import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lifesearch_mobile/core/api/api_client.dart';
import 'package:lifesearch_mobile/core/coverage/coverage_controller.dart';
import 'package:lifesearch_mobile/core/storage/search_map_store.dart';
import 'package:lifesearch_mobile/core/storage/secure_storage_manager.dart';
import 'package:lifesearch_mobile/core/storage/stored_models.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../helpers/in_memory_key_value_store.dart';

http.Response _json(Object body, int status) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

void main() {
  setUpAll(sqfliteFfiInit);

  test(
    'refreshes from server then retains the cached snapshot offline',
    () async {
      final storage = SecureStorageManager(InMemoryKeyValueStore());
      await storage.saveAccount(
        StoredAccount(
          accessToken: 'account-token',
          expiresAt: DateTime.now().add(const Duration(days: 1)),
          userId: 'u1',
          phoneE164: '+15551234567',
          displayName: 'Searcher',
        ),
      );
      await storage.saveSession(
        StoredSession(
          accessToken: 'session-token',
          expiresAt: DateTime.now().add(const Duration(hours: 8)),
          keyEpoch: 1,
          sectorKeyBase64: 'a2V5',
          membershipId: 'm1',
          sectorId: 's1',
          eventId: 'e1',
          role: 'volunteer',
          movementMode: 'walker',
        ),
      );
      final mapStore = SearchMapStore(
        factory: databaseFactoryFfi,
        path: inMemoryDatabasePath,
      );
      final onlineApi = ApiClient(
        baseUrl: 'http://test.invalid',
        httpClient: MockClient(
          (_) async => _json({
            'sector_id': 's1',
            'resolution': 12,
            'hexes': [
              {
                'hex_id': '8c2db2b25155dff',
                'cumulative_pod': 0.4,
                'valid_contributions': 1,
                'distinct_searchers': 1,
                'last_contribution_at': null,
                'boundary': [
                  [31.7, 35.2],
                  [31.8, 35.2],
                  [31.8, 35.3],
                ],
              },
            ],
          }, 200),
        ),
      );
      final online = CoverageController(
        api: onlineApi,
        storage: storage,
        mapStore: mapStore,
      );

      await online.start();
      expect(online.state.teamCells, hasLength(1));
      expect(online.state.lastServerSyncAt, isNotNull);
      final successfulSync = online.state.lastServerSyncAt;
      online.dispose();
      onlineApi.close();

      final offlineApi = ApiClient(
        baseUrl: 'http://test.invalid',
        httpClient: MockClient(
          (_) async => _json({
            'error': {'code': 'offline', 'message': 'no signal'},
          }, 503),
        ),
      );
      final offline = CoverageController(
        api: offlineApi,
        storage: storage,
        mapStore: mapStore,
      );

      await offline.start();
      expect(offline.state.teamCells, hasLength(1));
      expect(offline.state.teamCells.single.hexId, '8c2db2b25155dff');
      expect(
        offline.state.lastServerSyncAt?.millisecondsSinceEpoch,
        successfulSync?.millisecondsSinceEpoch,
      );
      expect(offline.state.lastError, isNotNull);

      offline.dispose();
      offlineApi.close();
      await mapStore.close();
    },
  );
}
