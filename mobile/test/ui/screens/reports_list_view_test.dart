import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lifesearch_mobile/core/api/api_client.dart';
import 'package:lifesearch_mobile/core/providers.dart';
import 'package:lifesearch_mobile/core/storage/stored_models.dart';
import 'package:lifesearch_mobile/ui/screens/reports_list_view.dart';

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
  'note': 'Fallen tree',
  'recorded_at': '2030-01-01T00:00:00Z',
  'received_at': '2030-01-01T00:00:01Z',
  'delivery_path': 'direct',
  'status': status,
  'acknowledged_by': null,
  'acknowledged_at': null,
  'updated_at': '2030-01-01T00:00:01Z',
};

Widget _wrap(ProviderContainer container) => UncontrolledProviderScope(
  container: container,
  child: const MaterialApp(home: ReportsListView()),
);

void main() {
  late ProviderContainer container;

  Future<void> setUpWithHandler(
    http.Response Function(http.Request) handler,
  ) async {
    container = ProviderContainer(
      overrides: [
        keyValueStoreProvider.overrideWith((ref) => InMemoryKeyValueStore()),
        apiClientProvider.overrideWith(
          (ref) => ApiClient(
            baseUrl: 'http://test.invalid',
            httpClient: MockClient((request) async => handler(request)),
          ),
        ),
      ],
    );
    final storage = container.read(secureStorageManagerProvider);
    await storage.saveAccount(
      StoredAccount(
        accessToken: 'account-tok',
        expiresAt: DateTime.now().add(const Duration(days: 1)),
        userId: 'user-1',
        phoneE164: '+15551234567',
        displayName: 'Test User',
      ),
    );
    await storage.saveSession(
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
  }

  tearDown(() => container.dispose());

  testWidgets('shows an empty state when there are no reports', (tester) async {
    await setUpWithHandler(
      (r) => http.Response('[]', 200, headers: {'content-type': 'application/json'}),
    );

    await tester.pumpWidget(_wrap(container));
    await tester.pumpAndSettle();

    expect(find.text('No reports for this sector yet.'), findsOneWidget);
  });

  testWidgets('shows a failure message on a 403', (tester) async {
    await setUpWithHandler(
      (r) => _json({
        'error': {'code': 'forbidden', 'message': 'you have no role in this sector'},
      }, 403),
    );

    await tester.pumpWidget(_wrap(container));
    await tester.pumpAndSettle();

    expect(find.textContaining('role'), findsOneWidget);
  });

  testWidgets('lists an open report with an Acknowledge action', (tester) async {
    await setUpWithHandler(
      (r) => http.Response(
        jsonEncode([_reportJson()]),
        200,
        headers: {'content-type': 'application/json'},
      ),
    );

    await tester.pumpWidget(_wrap(container));
    await tester.pumpAndSettle();

    expect(find.text('hazard'), findsOneWidget);
    expect(find.text('Fallen tree'), findsOneWidget);
    expect(find.byKey(const Key('report_acknowledge_report-1')), findsOneWidget);
  });

  testWidgets('acknowledging removes the action button', (tester) async {
    var acknowledged = false;
    await setUpWithHandler((r) {
      if (r.method == 'POST' && r.url.path == '/reports/report-1/acknowledge') {
        acknowledged = true;
        return _json(_reportJson(status: 'acknowledged'), 200);
      }
      return http.Response(
        jsonEncode([_reportJson(status: acknowledged ? 'acknowledged' : 'open')]),
        200,
        headers: {'content-type': 'application/json'},
      );
    });

    await tester.pumpWidget(_wrap(container));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('report_acknowledge_report-1')), findsOneWidget);

    await tester.tap(find.byKey(const Key('report_acknowledge_report-1')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('report_acknowledge_report-1')), findsNothing);
  });
}
