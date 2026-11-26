// Drives the ENTIRE phone -> OTP -> device registration -> join code ->
// approval -> session-claim flow through the real widget tree (not just
// the controllers in isolation, as in test/core/*). Only the HTTP layer is
// faked; every screen, form, and state transition in between is real.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lifesearch_mobile/app.dart';
import 'package:lifesearch_mobile/core/api/api_client.dart';
import 'package:lifesearch_mobile/core/providers.dart';

import '../helpers/in_memory_key_value_store.dart';

http.Response _json(Object body, int status) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

class _Router {
  final List<MapEntry<String, http.Response Function(http.Request)>> _routes = [];

  void on(String method, String pathPrefix, http.Response Function(http.Request) handler) {
    _routes.add(MapEntry('$method $pathPrefix', handler));
  }

  Future<http.Response> call(http.Request request) async {
    for (final entry in _routes) {
      final parts = entry.key.split(' ');
      if (request.method == parts[0] && request.url.path.startsWith(parts[1])) {
        return entry.value(request);
      }
    }
    fail('unexpected request: ${request.method} ${request.url.path}');
  }
}

void main() {
  testWidgets(
    'phone entry through to an active sector session',
    (tester) async {
      final router = _Router()
        ..on(
          'POST',
          '/auth/otp/request',
          (r) => _json({
            'challenge_id': 'c1',
            'expires_at': '2030-01-01T00:00:00Z',
            'dev_code': '123456',
          }, 201),
        )
        ..on(
          'POST',
          '/auth/otp/verify',
          (r) => _json({
            'access_token': 'account-tok',
            'token_type': 'Bearer',
            'expires_at': '2030-01-01T00:00:00Z',
            'user': {
              'id': 'u1',
              'phone_e164': '+15551234567',
              'display_name': '',
              'verification_status': 'unverified',
            },
          }, 200),
        )
        ..on(
          'POST',
          '/devices/key-challenge',
          (r) => _json({
            'challenge_id': 'kc1',
            'nonce': base64Encode(List.filled(32, 7)),
            'expires_at': '2030-01-01T00:00:00Z',
          }, 201),
        )
        ..on(
          'POST',
          '/devices',
          (r) => _json({
            'id': 'device-1',
            'wire_id': 42,
            'public_key': (jsonDecode(r.body) as Map)['public_key'],
            'platform': 'android',
            'mesh_capable': true,
            'label': null,
            'registered_at': '2030-01-01T00:00:00Z',
            'revoked_at': null,
          }, 201),
        )
        ..on(
          'POST',
          '/join',
          (r) => _json({
            'membership_id': 'm1',
            'sector_id': 's1',
            'status': 'pending',
          }, 201),
        )
        ..on(
          'GET',
          '/memberships/',
          (r) => _json({
            'id': 'm1',
            'sector_id': 's1',
            'status': 'approved',
            'role': 'volunteer',
            'movement_mode': 'walker',
            'session_expires_at': '2030-01-01T00:00:00Z',
          }, 200),
        )
        // The active-session map asks for these as soon as it appears.
        // Registered before the catch-alls above would matter, and kept
        // explicit so an unexpected sector request still fails the test.
        ..on(
          'GET',
          '/sectors/s1/tracks',
          (r) => _json({
            'sector_id': 's1',
            'tracks': <Map<String, dynamic>>[],
            'server_time': '2030-01-01T00:00:00Z',
          }, 200),
        )
        ..on(
          'GET',
          '/sectors/s1/permissions',
          (r) => _json({
            'sector_id': 's1',
            'role': 'volunteer',
            'is_commander': false,
            'is_sector_manager': false,
            'can_acknowledge_alerts': false,
            'can_delete_alerts': false,
            'can_moderate_members': false,
          }, 200),
        )
        ..on(
          'POST',
          '/memberships/m1/session',
          (r) => _json({
            'access_token': 'session-tok',
            'token_type': 'Bearer',
            'expires_at': '2030-01-01T00:00:00Z',
            'key_epoch': 1,
            'sector_key': 'a2V5Ynl0ZXM=',
            'sector': {
              'id': 's1',
              'event_id': 'e1',
              'name': 'North Ridge',
              'status': 'open',
            },
          }, 200),
        );

      final container = ProviderContainer(
        overrides: [
          baseUrlProvider.overrideWithValue('http://test.invalid'),
          apiClientProvider.overrideWith(
            (ref) => ApiClient(
              baseUrl: 'http://test.invalid',
              httpClient: MockClient(router.call),
            ),
          ),
          keyValueStoreProvider.overrideWith((ref) => InMemoryKeyValueStore()),
          // Live map polling timers would outlive the pump and trip the
          // binding's pending-timer check.
          coveragePollIntervalProvider.overrideWithValue(null),
          teamTracksPollIntervalProvider.overrideWithValue(null),
        ],
      );
      addTearDown(container.dispose);

      // Let sodium finish initializing before pumping the widget tree, so
      // the splash screen isn't what this test spends its time on.
      await container.read(sodiumProvider.future);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const LifeSearchApp(),
        ),
      );
      await tester.pumpAndSettle();

      // --- Phone entry -----------------------------------------------
      expect(find.byKey(const Key('phone_field')), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('phone_field')),
        '+15551234567',
      );
      await tester.tap(find.byKey(const Key('request_otp_button')));
      await tester.pumpAndSettle();

      // --- OTP entry (dev_code pre-filled by the backend) -------------
      expect(find.byKey(const Key('otp_field')), findsOneWidget);
      await tester.tap(find.byKey(const Key('verify_otp_button')));
      await tester.pumpAndSettle();

      // --- Signed in: now on the join-code screen ---------------------
      expect(find.byKey(const Key('join_code_field')), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('join_code_field')),
        '654321',
      );
      await tester.tap(find.byKey(const Key('submit_join_button')));
      // Deliberately NOT pumpAndSettle here: PendingApprovalView starts a
      // real Timer.periodic(4s) polling loop, and pumpAndSettle advances
      // Flutter's fake test clock in its own internal steps -- given enough
      // iterations it will happily fast-forward PAST that 4-second mark,
      // firing the real timer and racing the whole flow to completion
      // before this test ever gets to see the intermediate "pending"
      // screen. A few zero-duration pumps drain the submit call's own
      // microtasks without advancing fake time far enough to trip it.
      await tester.pump();
      await tester.pump();
      await tester.pump();

      // --- Pending approval --------------------------------------------
      expect(find.text('Waiting for your Sector Lead to approve you.'), findsOneWidget);

      // Drive the poll manually instead of waiting on the real timer.
      container.read(joinControllerProvider.notifier).pollOnce();
      await tester.pumpAndSettle();

      // --- Session active ------------------------------------------------
      expect(find.textContaining('North Ridge'), findsOneWidget);
    },
  );
}
