import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lifesearch_mobile/core/api/api_client.dart';
import 'package:lifesearch_mobile/core/providers.dart';
import 'package:lifesearch_mobile/core/storage/stored_models.dart';
import 'package:lifesearch_mobile/ui/screens/report_form_view.dart';

import '../../helpers/fake_location_source.dart';
import '../../helpers/in_memory_key_value_store.dart';

http.Response _json(Object body, int status) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

Widget _wrap(ProviderContainer container) => UncontrolledProviderScope(
  container: container,
  child: const MaterialApp(home: ReportFormView()),
);

void main() {
  late ProviderContainer container;
  late FakeLocationSource location;
  late http.Response Function(http.Request) handler;

  setUp(() async {
    location = FakeLocationSource();
    handler = (r) => throw StateError('no handler configured');

    container = ProviderContainer(
      overrides: [
        keyValueStoreProvider.overrideWith((ref) => InMemoryKeyValueStore()),
        locationSourceProvider.overrideWithValue(location),
        apiClientProvider.overrideWith(
          (ref) => ApiClient(
            baseUrl: 'http://test.invalid',
            httpClient: MockClient((request) async => handler(request)),
          ),
        ),
      ],
    );

    final storage = container.read(secureStorageManagerProvider);
    final sodium = await container.read(sodiumProvider.future);
    final identity = container.read(deviceIdentityProvider);

    final pair = identity.generateKeyPair();
    await storage.saveDeviceIdentity(
      StoredDeviceIdentity(
        publicKeyBase64: pair.publicKeyBase64,
        secretKeyBase64: base64Encode(pair.secretKey.extractBytes()),
        deviceId: 'device-1',
        wireId: 7,
      ),
    );
    pair.dispose();

    final sectorKey = sodium.secureRandom(32);
    await storage.saveSession(
      StoredSession(
        accessToken: 'session-tok',
        expiresAt: DateTime.now().add(const Duration(hours: 8)),
        keyEpoch: 1,
        sectorKeyBase64: base64Encode(sectorKey.extractBytes()),
        membershipId: 'm1',
        sectorId: 's1',
        eventId: 'e1',
        role: 'volunteer',
        movementMode: 'walker',
      ),
    );
    sectorKey.dispose();
  });

  tearDown(() => container.dispose());

  testWidgets('shows the form fields in the idle state', (tester) async {
    await tester.pumpWidget(_wrap(container));

    expect(find.byKey(const Key('report_kind_field')), findsOneWidget);
    expect(find.byKey(const Key('report_note_field')), findsOneWidget);
    expect(find.byKey(const Key('report_submit_button')), findsOneWidget);
  });

  testWidgets('submitting shows a success state naming the kind', (tester) async {
    handler = (r) => _json({
      'accepted': 1, 'duplicate': 0, 'decrypt_failed': 0,
      'signature_invalid': 0, 'wrong_device': 0, 'malformed': 0,
    }, 200);
    await tester.pumpWidget(_wrap(container));

    await tester.enterText(
      find.byKey(const Key('report_note_field')),
      'Fallen tree blocking the trail.',
    );
    await tester.tap(find.byKey(const Key('report_submit_button')));
    await tester.pumpAndSettle();

    expect(find.textContaining('report sent'), findsOneWidget);
    expect(find.byKey(const Key('report_file_another_button')), findsOneWidget);
  });

  testWidgets('tapping "File another report" returns to the form', (tester) async {
    handler = (r) => _json({
      'accepted': 1, 'duplicate': 0, 'decrypt_failed': 0,
      'signature_invalid': 0, 'wrong_device': 0, 'malformed': 0,
    }, 200);
    await tester.pumpWidget(_wrap(container));
    await tester.tap(find.byKey(const Key('report_submit_button')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('report_file_another_button')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('report_kind_field')), findsOneWidget);
  });

  testWidgets('a submission failure shows an error that can be dismissed', (
    tester,
  ) async {
    handler = (r) => _json({
      'error': {'code': 'internal', 'message': 'server exploded'},
    }, 500);
    await tester.pumpWidget(_wrap(container));

    await tester.tap(find.byKey(const Key('report_submit_button')));
    await tester.pumpAndSettle();

    expect(find.text('server exploded'), findsOneWidget);

    await tester.tap(find.byKey(const Key('report_error_dismiss')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('report_kind_field')), findsOneWidget);
  });

  testWidgets('a location failure shows an error without any network request', (
    tester,
  ) async {
    var requestCount = 0;
    handler = (r) {
      requestCount++;
      return _json({}, 200);
    };
    location.currentPositionError = Exception('GPS unavailable');
    await tester.pumpWidget(_wrap(container));

    await tester.tap(find.byKey(const Key('report_submit_button')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('report_error_dismiss')), findsOneWidget);
    expect(requestCount, equals(0));
  });
}
