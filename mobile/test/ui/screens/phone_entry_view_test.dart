import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lifesearch_mobile/core/api/api_client.dart';
import 'package:lifesearch_mobile/core/providers.dart';
import 'package:lifesearch_mobile/ui/screens/phone_entry_view.dart';

import '../../helpers/in_memory_key_value_store.dart';

Widget _wrap(Widget child, ProviderContainer container) => UncontrolledProviderScope(
  container: container,
  child: MaterialApp(home: child),
);

void main() {
  late ProviderContainer container;

  setUp(() async {
    container = ProviderContainer(
      overrides: [
        baseUrlProvider.overrideWithValue('http://test.invalid'),
        apiClientProvider.overrideWith(
          (ref) => ApiClient(
            baseUrl: 'http://test.invalid',
            // Real http.Client() would hit Flutter's test-mode network
            // block (all requests forced to 400) -- this test only cares
            // about form validation, so any canned success response works.
            httpClient: MockClient(
              (request) async => http.Response(
                jsonEncode({
                  'challenge_id': 'c1',
                  'expires_at': '2030-01-01T00:00:00Z',
                }),
                201,
                headers: {'content-type': 'application/json'},
              ),
            ),
          ),
        ),
        keyValueStoreProvider.overrideWith((ref) => InMemoryKeyValueStore()),
      ],
    );
    await container.read(sodiumProvider.future);
  });

  tearDown(() => container.dispose());

  testWidgets('rejects a phone number missing the country code', (tester) async {
    await tester.pumpWidget(
      _wrap(const PhoneEntryView(isSubmitting: false), container),
    );

    await tester.enterText(find.byKey(const Key('phone_field')), '5551234567');
    await tester.tap(find.byKey(const Key('request_otp_button')));
    await tester.pump();

    expect(
      find.textContaining('international format'),
      findsOneWidget,
    );
  });

  testWidgets('accepts a valid E.164 phone number', (tester) async {
    await tester.pumpWidget(
      _wrap(const PhoneEntryView(isSubmitting: false), container),
    );

    await tester.enterText(
      find.byKey(const Key('phone_field')),
      '+15551234567',
    );
    await tester.tap(find.byKey(const Key('request_otp_button')));
    await tester.pump();

    expect(find.textContaining('international format'), findsNothing);
  });

  testWidgets('disables the field and button while submitting', (tester) async {
    await tester.pumpWidget(
      _wrap(const PhoneEntryView(isSubmitting: true), container),
    );

    final field = tester.widget<TextFormField>(
      find.byKey(const Key('phone_field')),
    );
    expect(field.enabled, isFalse);

    final button = tester.widget<FilledButton>(
      find.byKey(const Key('request_otp_button')),
    );
    expect(button.onPressed, isNull);
  });

  testWidgets('shows a passed-in error message', (tester) async {
    await tester.pumpWidget(
      _wrap(
        const PhoneEntryView(isSubmitting: false, errorMessage: 'wait 30s'),
        container,
      ),
    );

    expect(find.text('wait 30s'), findsOneWidget);
  });
}
