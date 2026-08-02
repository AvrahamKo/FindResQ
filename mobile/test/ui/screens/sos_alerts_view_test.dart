import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lifesearch_mobile/core/api/api_client.dart';
import 'package:lifesearch_mobile/core/providers.dart';
import 'package:lifesearch_mobile/core/storage/stored_models.dart';
import 'package:lifesearch_mobile/ui/screens/sos_alerts_view.dart';

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

Widget _wrap(ProviderContainer container) => UncontrolledProviderScope(
  container: container,
  child: const MaterialApp(home: SosAlertsView()),
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
        userId: 'lead-1',
        phoneE164: '+15551234567',
        displayName: 'Test Lead',
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
        role: 'lead',
        movementMode: 'walker',
      ),
    );
  }

  tearDown(() => container.dispose());

  testWidgets('shows an empty state when there are no alerts', (tester) async {
    await setUpWithHandler(
      (r) => http.Response('[]', 200, headers: {'content-type': 'application/json'}),
    );

    await tester.pumpWidget(_wrap(container));
    await tester.pumpAndSettle();

    expect(find.text('No SOS alerts for this sector.'), findsOneWidget);
  });

  testWidgets('shows a failure message on a 403', (tester) async {
    await setUpWithHandler(
      (r) => _json({
        'error': {'code': 'forbidden', 'message': 'only this sector\'s lead can do this'},
      }, 403),
    );

    await tester.pumpWidget(_wrap(container));
    await tester.pumpAndSettle();

    expect(find.textContaining('lead'), findsOneWidget);
  });

  testWidgets('lists an active alert with an Acknowledge action', (tester) async {
    await setUpWithHandler(
      (r) => http.Response(
        jsonEncode([_alertJson()]),
        200,
        headers: {'content-type': 'application/json'},
      ),
    );

    await tester.pumpWidget(_wrap(container));
    await tester.pumpAndSettle();

    expect(find.text('SOS active'), findsOneWidget);
    expect(find.byKey(const Key('sos_acknowledge_alert-1')), findsOneWidget);
    expect(find.byKey(const Key('sos_resolve_alert-1')), findsNothing);
  });

  testWidgets('acknowledging moves the alert to acknowledged with a Resolve action', (
    tester,
  ) async {
    var acknowledged = false;
    await setUpWithHandler((r) {
      if (r.method == 'POST' && r.url.path == '/sos/alert-1/acknowledge') {
        acknowledged = true;
        return _json(_alertJson(status: 'acknowledged'), 200);
      }
      return http.Response(
        jsonEncode([_alertJson(status: acknowledged ? 'acknowledged' : 'active')]),
        200,
        headers: {'content-type': 'application/json'},
      );
    });

    await tester.pumpWidget(_wrap(container));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('sos_acknowledge_alert-1')), findsOneWidget);

    await tester.tap(find.byKey(const Key('sos_acknowledge_alert-1')));
    await tester.pumpAndSettle();

    expect(find.text('SOS acknowledged'), findsOneWidget);
    expect(find.byKey(const Key('sos_resolve_alert-1')), findsOneWidget);
  });

  testWidgets('resolving removes the action button', (tester) async {
    var resolved = false;
    await setUpWithHandler((r) {
      if (r.method == 'POST' && r.url.path == '/sos/alert-1/resolve') {
        resolved = true;
        return _json(_alertJson(status: 'resolved'), 200);
      }
      return http.Response(
        jsonEncode([_alertJson(status: resolved ? 'resolved' : 'acknowledged')]),
        200,
        headers: {'content-type': 'application/json'},
      );
    });

    await tester.pumpWidget(_wrap(container));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('sos_resolve_alert-1')), findsOneWidget);

    await tester.tap(find.byKey(const Key('sos_resolve_alert-1')));
    await tester.pumpAndSettle();

    expect(find.text('SOS resolved'), findsOneWidget);
    expect(find.byKey(const Key('sos_acknowledge_alert-1')), findsNothing);
    expect(find.byKey(const Key('sos_resolve_alert-1')), findsNothing);
  });
}
