import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lifesearch_mobile/core/api/api_client.dart';
import 'package:lifesearch_mobile/core/providers.dart';
import 'package:lifesearch_mobile/core/storage/stored_models.dart';
import 'package:lifesearch_mobile/ui/screens/sos_button_view.dart';

import '../../helpers/in_memory_key_value_store.dart';

http.Response _json(Object body, int status) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

Map<String, dynamic> _alertJson({String status = 'active'}) => {
  'id': 'alert-1',
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

http.Response _errorJson(String message, int status) =>
    _json({'error': {'code': 'error', 'message': message}}, status);

Widget _wrap(ProviderContainer container) => UncontrolledProviderScope(
  container: container,
  child: const MaterialApp(home: SosButtonView()),
);

void main() {
  late ProviderContainer container;
  late int requestCount;
  // Full control per-test over exactly what each request gets back.
  late http.Response Function(http.Request) handler;

  setUp(() async {
    requestCount = 0;
    handler = (r) => throw StateError('no handler configured for ${r.url.path}');

    container = ProviderContainer(
      overrides: [
        keyValueStoreProvider.overrideWith((ref) => InMemoryKeyValueStore()),
        apiClientProvider.overrideWith(
          (ref) => ApiClient(
            baseUrl: 'http://test.invalid',
            httpClient: MockClient((request) async {
              requestCount++;
              return handler(request);
            }),
          ),
        ),
      ],
    );

    final storage = container.read(secureStorageManagerProvider);
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
  });

  tearDown(() => container.dispose());

  testWidgets('shows the SOS button in the idle state', (tester) async {
    await tester.pumpWidget(_wrap(container));

    expect(find.byKey(const Key('sos_trigger_button')), findsOneWidget);
  });

  testWidgets('tapping SOS then Cancel in the dialog sends no request', (tester) async {
    await tester.pumpWidget(_wrap(container));

    await tester.tap(find.byKey(const Key('sos_trigger_button')));
    await tester.pumpAndSettle();
    expect(find.text('Send SOS?'), findsOneWidget);

    await tester.tap(find.byKey(const Key('sos_confirm_cancel')));
    await tester.pumpAndSettle();

    expect(requestCount, equals(0));
    expect(find.byKey(const Key('sos_trigger_button')), findsOneWidget);
  });

  testWidgets('confirming the dialog triggers SOS and shows the active state', (
    tester,
  ) async {
    handler = (r) => _json(_alertJson(), 201);
    await tester.pumpWidget(_wrap(container));

    await tester.tap(find.byKey(const Key('sos_trigger_button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('sos_confirm_send')));
    await tester.pumpAndSettle();

    expect(requestCount, equals(1));
    expect(find.text('SOS ACTIVE'), findsOneWidget);
    expect(find.text('Waiting for your Sector Lead to respond.'), findsOneWidget);
  });

  testWidgets('an already-acknowledged alert shows the acknowledged message', (
    tester,
  ) async {
    handler = (r) => _json(_alertJson(status: 'acknowledged'), 201);
    await tester.pumpWidget(_wrap(container));

    await tester.tap(find.byKey(const Key('sos_trigger_button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('sos_confirm_send')));
    await tester.pumpAndSettle();

    expect(find.text('SOS ACTIVE'), findsOneWidget);
    expect(find.text('Your Sector Lead has acknowledged this.'), findsOneWidget);
  });

  testWidgets('cancelling with confirmation returns to idle', (tester) async {
    handler = (r) => r.url.path == '/sos'
        ? _json(_alertJson(), 201)
        : _json(_alertJson(status: 'cancelled'), 200);
    await tester.pumpWidget(_wrap(container));
    await tester.tap(find.byKey(const Key('sos_trigger_button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('sos_confirm_send')));
    await tester.pumpAndSettle();
    expect(find.text('SOS ACTIVE'), findsOneWidget);

    await tester.tap(find.byKey(const Key('sos_cancel_button')));
    await tester.pumpAndSettle();
    expect(find.text('Cancel SOS?'), findsOneWidget);
    await tester.tap(find.byKey(const Key('sos_cancel_confirm_yes')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('sos_trigger_button')), findsOneWidget);
  });

  testWidgets('declining the cancel confirmation keeps SOS active', (tester) async {
    handler = (r) => _json(_alertJson(), 201);
    await tester.pumpWidget(_wrap(container));
    await tester.tap(find.byKey(const Key('sos_trigger_button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('sos_confirm_send')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('sos_cancel_button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('sos_cancel_confirm_no')));
    await tester.pumpAndSettle();

    expect(find.text('SOS ACTIVE'), findsOneWidget);
    expect(requestCount, equals(1), reason: 'no cancel request should have been sent');
  });

  testWidgets('a trigger failure shows an error that can be dismissed', (tester) async {
    handler = (r) => _errorJson('server exploded', 500);
    await tester.pumpWidget(_wrap(container));

    await tester.tap(find.byKey(const Key('sos_trigger_button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('sos_confirm_send')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('sos_error_dismiss')), findsOneWidget);
    expect(find.text('server exploded'), findsOneWidget);

    await tester.tap(find.byKey(const Key('sos_error_dismiss')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('sos_trigger_button')), findsOneWidget);
  });
}
