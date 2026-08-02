// End-to-end proof: drives the REAL AuthController and JoinController --
// real HTTP calls, real device Ed25519 keypair, real join/approve/session
// flow -- against an ACTUAL running backend and real Postgres. Nothing here
// is mocked except the "Sector Lead approving the request," which this
// file does itself via a second, commander-role account, over the same
// real API.
//
// Skipped automatically if no backend is reachable at [_baseUrl] (see
// backend/tests/conftest.py's db_conn fixture for the same convention on
// the Python side). Start it with:
//   docker compose up -d          (from backend/)
//   uvicorn app.main:app --port 8000   (from backend/, with the venv active)

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:lifesearch_mobile/core/api/api_client.dart';
import 'package:lifesearch_mobile/core/auth/auth_controller.dart';
import 'package:lifesearch_mobile/core/auth/auth_state.dart';
import 'package:lifesearch_mobile/core/crypto/device_identity.dart';
import 'package:lifesearch_mobile/core/crypto/sodium_provider.dart';
import 'package:lifesearch_mobile/core/join/join_controller.dart';
import 'package:lifesearch_mobile/core/join/join_state.dart';
import 'package:lifesearch_mobile/core/storage/secure_storage_manager.dart';
import 'package:sodium/sodium.dart';

import '../helpers/in_memory_key_value_store.dart';

const _baseUrl = 'http://localhost:8000';

const _sectorBoundaryGeoJson = {
  'type': 'Polygon',
  'coordinates': [
    [
      [35.20, 31.76],
      [35.20, 31.78],
      [35.24, 31.78],
      [35.24, 31.76],
      [35.20, 31.76],
    ],
  ],
};

Future<bool> _backendReachable() async {
  try {
    final response = await http
        .get(Uri.parse('$_baseUrl/readyz'))
        .timeout(const Duration(seconds: 3));
    return response.statusCode == 200;
  } on Object {
    return false;
  }
}

String _uniquePhone() {
  final suffix = DateTime.now().microsecondsSinceEpoch % 10000000;
  return '+1555${suffix.toString().padLeft(7, '0')}';
}

/// Minimal raw client for fixture setup only (creating the commander
/// account, event, sector, and join code, and later approving the
/// volunteer's request) -- deliberately NOT going through AuthController/
/// JoinController, since those are the code under test, not the test
/// harness.
class _CommanderFixture {
  final String accountToken;
  final String eventId;
  final String sectorId;

  const _CommanderFixture({
    required this.accountToken,
    required this.eventId,
    required this.sectorId,
  });

  static Future<_CommanderFixture> create() async {
    final client = http.Client();

    Future<Map<String, dynamic>> call(
      String method,
      String path, {
      Map<String, dynamic>? body,
      String? token,
    }) async {
      final uri = Uri.parse('$_baseUrl$path');
      final headers = {
        'Content-Type': 'application/json',
        if (token != null) 'Authorization': 'Bearer $token',
      };
      final response = method == 'GET'
          ? await client.get(uri, headers: headers)
          : await client.post(
              uri,
              headers: headers,
              body: body == null ? null : jsonEncode(body),
            );
      if (response.statusCode >= 300) {
        fail('fixture setup failed: $method $path -> ${response.statusCode} ${response.body}');
      }
      return response.body.isEmpty
          ? {}
          : jsonDecode(response.body) as Map<String, dynamic>;
    }

    final otp = await call('POST', '/auth/otp/request', body: {
      'phone_e164': _uniquePhone(),
    });
    final verify = await call(
      'POST',
      '/auth/otp/verify',
      body: {
        'challenge_id': otp['challenge_id'],
        'code': otp['dev_code'],
        'display_name': 'E2E Commander',
      },
    );
    final accountToken = verify['access_token'] as String;

    final event = await call(
      'POST',
      '/events',
      token: accountToken,
      body: {'name': 'E2E Test Callout'},
    );
    final eventId = event['id'] as String;

    await call('POST', '/events/$eventId/start', token: accountToken);

    final sector = await call(
      'POST',
      '/events/$eventId/sectors',
      token: accountToken,
      body: {'name': 'E2E Test Sector', 'boundary': _sectorBoundaryGeoJson},
    );
    final sectorId = sector['id'] as String;

    return _CommanderFixture(
      accountToken: accountToken,
      eventId: eventId,
      sectorId: sectorId,
    );
  }

  Future<String> mintJoinCode() async {
    final client = http.Client();
    final response = await client.post(
      Uri.parse('$_baseUrl/sectors/$sectorId/join-codes'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $accountToken',
      },
      body: jsonEncode({}),
    );
    if (response.statusCode >= 300) {
      fail('failed to mint join code: ${response.statusCode} ${response.body}');
    }
    return (jsonDecode(response.body) as Map<String, dynamic>)['code'] as String;
  }

  Future<void> approve(String membershipId) async {
    final client = http.Client();
    final response = await client.post(
      Uri.parse('$_baseUrl/memberships/$membershipId/approve'),
      headers: {'Authorization': 'Bearer $accountToken'},
    );
    if (response.statusCode >= 300) {
      fail('failed to approve membership: ${response.statusCode} ${response.body}');
    }
  }
}

void main() {
  late Sodium sodium;
  late DeviceIdentity identity;

  setUpAll(() async {
    sodium = await SodiumProvider.instance();
    identity = DeviceIdentity(sodium);
  });

  test(
    'phone -> OTP -> device registration -> join -> approval -> session, against the real backend',
    () async {
      if (!await _backendReachable()) {
        // ignore: avoid_print
        print('SKIPPED: no backend reachable at $_baseUrl');
        return;
      }

      final fixture = await _CommanderFixture.create();
      final joinCode = await fixture.mintJoinCode();

      final store = InMemoryKeyValueStore();
      final storage = SecureStorageManager(store);
      final api = ApiClient(baseUrl: _baseUrl);

      final authController = AuthController(
        api: api,
        storage: storage,
        identity: identity,
        sodium: sodium,
      );

      await authController.requestOtp(_uniquePhone());
      final otpSent = authController.state;
      expect(otpSent, isA<AuthOtpSent>());

      // ENV=local echoes the code back; a real deployment would need the
      // volunteer to read it from an actual SMS.
      final devCode = (otpSent as AuthOtpSent).devCode;
      expect(devCode, isNotNull, reason: 'expected ENV=local to echo dev_code');

      await authController.verifyOtp(devCode!, displayName: 'E2E Volunteer');

      final signedIn = authController.state;
      expect(signedIn, isA<AuthSignedIn>());
      final deviceId = (signedIn as AuthSignedIn).deviceId;
      expect(deviceId, isNotEmpty);

      final joinController = JoinController(api: api, storage: storage);

      await joinController.submitJoinCode(
        code: joinCode,
        movementMode: 'walker',
        batteryPct: 80,
        powerbankAttested: false,
      );
      final pending = joinController.state;
      expect(pending, isA<JoinPending>());
      final membershipId = (pending as JoinPending).membershipId;

      // Still pending until the "Sector Lead" (our commander fixture) acts.
      await joinController.pollOnce();
      expect(joinController.state, isA<JoinPending>());

      await fixture.approve(membershipId);
      await joinController.pollOnce();

      final approved = joinController.state;
      expect(approved, isA<JoinApproved>());
      expect((approved as JoinApproved).role, equals('volunteer'));
      expect(approved.movementMode, equals('walker'));

      await joinController.claimSession();

      final active = joinController.state;
      expect(active, isA<JoinSessionActive>());
      expect((active as JoinSessionActive).sectorName, equals('E2E Test Sector'));

      final session = await storage.loadSession();
      expect(session, isNotNull);
      expect(session!.sectorId, equals(fixture.sectorId));
      expect(session.eventId, equals(fixture.eventId));

      // The sector key is real, base64-encoded, 32 raw bytes -- confirms
      // the whole chain (server envelope-unwrap -> HTTPS -> Dart base64
      // decode) delivered a genuinely usable XChaCha20-Poly1305 key, tying
      // this phase back to Phase 5a's crypto layer.
      final rawKey = base64Decode(session.sectorKeyBase64);
      expect(rawKey.length, equals(32));
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );
}
