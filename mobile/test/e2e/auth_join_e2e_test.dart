// End-to-end proof: drives the REAL AuthController and JoinController --
// real HTTP calls, real device Ed25519 keypair, real join/approve/session
// flow -- against an ACTUAL running backend and real Postgres. Nothing here
// is mocked except the "Sector Lead approving the request," which this
// file does itself via a second, commander-role account, over the same
// real API (see `helpers/commander_fixture.dart`).
//
// Skipped automatically if no backend is reachable at [baseUrl] (see
// backend/tests/conftest.py's db_conn fixture for the same convention on
// the Python side). Start it with:
//   docker compose up -d          (from backend/)
//   uvicorn app.main:app --port 8000   (from backend/, with the venv active)

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lifesearch_mobile/core/api/api_client.dart';
import 'package:lifesearch_mobile/core/auth/auth_controller.dart';
import 'package:lifesearch_mobile/core/auth/auth_state.dart';
import 'package:lifesearch_mobile/core/crypto/device_identity.dart';
import 'package:lifesearch_mobile/core/crypto/sodium_provider.dart';
import 'package:lifesearch_mobile/core/join/join_controller.dart';
import 'package:lifesearch_mobile/core/join/join_state.dart';
import 'package:lifesearch_mobile/core/storage/secure_storage_manager.dart';
import 'package:sodium/sodium.dart';

import '../helpers/commander_fixture.dart';
import '../helpers/in_memory_key_value_store.dart';

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
      if (!await backendReachable()) {
        // ignore: avoid_print
        print('SKIPPED: no backend reachable at $baseUrl');
        return;
      }

      final fixture = await CommanderFixture.create();
      final joinCode = await fixture.mintJoinCode();

      final store = InMemoryKeyValueStore();
      final storage = SecureStorageManager(store);
      final api = ApiClient(baseUrl: baseUrl);

      final authController = AuthController(
        api: api,
        storage: storage,
        identity: identity,
        sodium: sodium,
      );

      await authController.requestOtp(uniquePhone());
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
