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

/// The sector-permissions body. `canModerate` decides whether the backend
/// would accept an acknowledge from this user -- and therefore whether the
/// UI is allowed to offer one.
Map<String, dynamic> _permissionsJson({
  String role = 'lead',
  bool canModerate = true,
}) => {
  'sector_id': 's1',
  'role': role,
  'is_commander': role == 'commander',
  'is_sector_manager': role == 'lead',
  'can_acknowledge_alerts': canModerate,
  'can_delete_alerts': canModerate,
  'can_moderate_members': canModerate,
};

void main() {
  late ProviderContainer container;

  Future<void> setUpWithHandler(
    http.Response Function(http.Request) handler, {
    Map<String, dynamic>? permissions,
  }) async {
    container = ProviderContainer(
      overrides: [
        keyValueStoreProvider.overrideWith((ref) => InMemoryKeyValueStore()),
        apiClientProvider.overrideWith(
          (ref) => ApiClient(
            baseUrl: 'http://test.invalid',
            httpClient: MockClient((request) async {
              // Intercepted here rather than in each test's handler: every
              // test needs it, and the handlers below deliberately answer
              // any other path with the alert list.
              if (request.url.path == '/sectors/s1/permissions') {
                return _json(permissions ?? _permissionsJson(), 200);
              }
              return handler(request);
            }),
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

  group('alert moderation is restricted', () {
    testWidgets('a field volunteer sees the alert but gets NO Acknowledge', (
      tester,
    ) async {
      await setUpWithHandler(
        (r) => http.Response(
          jsonEncode([_alertJson()]),
          200,
          headers: {'content-type': 'application/json'},
        ),
        permissions: _permissionsJson(role: 'volunteer', canModerate: false),
      );

      await tester.pumpWidget(_wrap(container));
      await tester.pumpAndSettle();

      // Visibility is intentional: a searcher should know an alert exists.
      expect(find.text('SOS active'), findsOneWidget);
      // Acting on it is not theirs to do -- acknowledging clears the alarm
      // for the whole team and claims responsibility for the response.
      expect(find.byKey(const Key('sos_acknowledge_alert-1')), findsNothing);
      expect(find.byKey(const Key('sos_resolve_alert-1')), findsNothing);
    });

    testWidgets('a volunteer gets no Resolve on an acknowledged alert either', (
      tester,
    ) async {
      await setUpWithHandler(
        (r) => http.Response(
          jsonEncode([_alertJson(status: 'acknowledged')]),
          200,
          headers: {'content-type': 'application/json'},
        ),
        permissions: _permissionsJson(role: 'volunteer', canModerate: false),
      );

      await tester.pumpWidget(_wrap(container));
      await tester.pumpAndSettle();

      expect(find.text('SOS acknowledged'), findsOneWidget);
      expect(find.byKey(const Key('sos_resolve_alert-1')), findsNothing);
    });

    testWidgets('the event commander is a moderator too, not just the lead', (
      tester,
    ) async {
      await setUpWithHandler(
        (r) => http.Response(
          jsonEncode([_alertJson()]),
          200,
          headers: {'content-type': 'application/json'},
        ),
        permissions: _permissionsJson(role: 'commander', canModerate: true),
      );

      await tester.pumpWidget(_wrap(container));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('sos_acknowledge_alert-1')), findsOneWidget);
    });

    testWidgets('an unreachable permissions endpoint fails CLOSED', (
      tester,
    ) async {
      // The safe default when the server cannot be asked. Offering an
      // Acknowledge that will be refused would let a searcher believe an
      // emergency had been picked up when it had not.
      await setUpWithHandler(
        (r) => http.Response(
          jsonEncode([_alertJson()]),
          200,
          headers: {'content-type': 'application/json'},
        ),
        permissions: null,
      );
      // Rebuild the container with a permissions endpoint that errors.
      container.dispose();
      container = ProviderContainer(
        overrides: [
          keyValueStoreProvider.overrideWith((ref) => InMemoryKeyValueStore()),
          apiClientProvider.overrideWith(
            (ref) => ApiClient(
              baseUrl: 'http://test.invalid',
              httpClient: MockClient((request) async {
                if (request.url.path == '/sectors/s1/permissions') {
                  return _json({
                    'error': {'code': 'unavailable', 'message': 'down'},
                  }, 503);
                }
                return http.Response(
                  jsonEncode([_alertJson()]),
                  200,
                  headers: {'content-type': 'application/json'},
                );
              }),
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
          // Note: the STORED session still says 'lead'. The UI must not
          // trust it -- that field is a snapshot from claim time and the
          // server is the only authority on the current role.
          role: 'lead',
          movementMode: 'walker',
        ),
      );

      await tester.pumpWidget(_wrap(container));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('sos_acknowledge_alert-1')), findsNothing);
    });
  });
}
