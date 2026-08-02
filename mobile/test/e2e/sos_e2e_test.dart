// End-to-end proof of the SOS state machine against a REAL running backend
// and real Postgres: a searcher triggers a real SOS via [SosController],
// the Commander sees it via [SosAlertsController] (GET /sectors/{id}/sos),
// acknowledges it, and resolves it -- nothing in this chain is mocked.
//
// [SosAlertsController] reads the acting user's sector from their OWN
// `StoredSession`, which means the "Commander" character here also
// completes a real join/session flow in their own sector (getting a
// `volunteer`-role membership) purely so their storage has a `sectorId` to
// read client-side -- the actual authorization for acknowledge/resolve/list
// comes from the backend's Commander check (`event.commander_id ==
// user.id`), independent of that membership role. A pure Commander who
// never joins any sector as a member has no way to discover a sector's id
// through today's mobile client; see HANDOVER.md for this as a known scope
// boundary, not an oversight.
//
// Skipped automatically if no backend is reachable at [baseUrl] -- see
// `helpers/commander_fixture.dart` and `auth_join_e2e_test.dart` for the
// same convention.

import 'package:flutter_test/flutter_test.dart';
import 'package:lifesearch_mobile/core/api/api_client.dart';
import 'package:lifesearch_mobile/core/auth/auth_controller.dart';
import 'package:lifesearch_mobile/core/auth/auth_state.dart';
import 'package:lifesearch_mobile/core/crypto/device_identity.dart';
import 'package:lifesearch_mobile/core/crypto/sodium_provider.dart';
import 'package:lifesearch_mobile/core/join/join_controller.dart';
import 'package:lifesearch_mobile/core/join/join_state.dart';
import 'package:lifesearch_mobile/core/sos/sos_alerts_controller.dart';
import 'package:lifesearch_mobile/core/sos/sos_alerts_state.dart';
import 'package:lifesearch_mobile/core/sos/sos_controller.dart';
import 'package:lifesearch_mobile/core/sos/sos_state.dart';
import 'package:lifesearch_mobile/core/storage/secure_storage_manager.dart';
import 'package:lifesearch_mobile/core/storage/stored_models.dart';
import 'package:sodium/sodium.dart';

import '../helpers/commander_fixture.dart';
import '../helpers/in_memory_key_value_store.dart';

void main() {
  late Sodium sodium;
  late DeviceIdentity identity;
  late ApiClient api;

  setUpAll(() async {
    sodium = await SodiumProvider.instance();
    identity = DeviceIdentity(sodium);
    api = ApiClient(baseUrl: baseUrl);
  });

  /// Real phone -> OTP -> device registration -> join -> approve -> claim
  /// session, exactly like `auth_join_e2e_test.dart` -- returns the fully
  /// signed-in device's own storage.
  Future<SecureStorageManager> registerAndJoin({
    required CommanderFixture fixture,
    required String joinCode,
    required String displayName,
  }) async {
    final storage = SecureStorageManager(InMemoryKeyValueStore());
    final authController = AuthController(
      api: api,
      storage: storage,
      identity: identity,
      sodium: sodium,
    );

    await authController.requestOtp(uniquePhone());
    final devCode = (authController.state as AuthOtpSent).devCode!;
    await authController.verifyOtp(devCode, displayName: displayName);
    expect(authController.state, isA<AuthSignedIn>());

    final joinController = JoinController(api: api, storage: storage);
    await joinController.submitJoinCode(
      code: joinCode,
      movementMode: 'walker',
      batteryPct: 80,
      powerbankAttested: false,
    );
    final membershipId = (joinController.state as JoinPending).membershipId;

    await fixture.approve(membershipId);
    await joinController.pollOnce();
    expect(joinController.state, isA<JoinApproved>());

    await joinController.claimSession();
    expect(joinController.state, isA<JoinSessionActive>());

    return storage;
  }

  test(
    'a real SOS trigger is visible, acknowledgeable, and resolvable by the Commander',
    () async {
      if (!await backendReachable()) {
        // ignore: avoid_print
        print('SKIPPED: no backend reachable at $baseUrl');
        return;
      }

      final fixture = await CommanderFixture.create();

      final searcherStorage = await registerAndJoin(
        fixture: fixture,
        joinCode: await fixture.mintJoinCode(),
        displayName: 'E2E SOS Searcher',
      );
      // The commander also joins their OWN sector purely to get a
      // `sectorId` into their own storage -- see the file docstring.
      final commanderStorage = await registerAndJoin(
        fixture: fixture,
        joinCode: await fixture.mintJoinCode(),
        displayName: 'E2E SOS Commander (self-joined)',
      );
      // Overwrite the account with the REAL commander account (the
      // fixture's) so acknowledge/resolve are authorized as the actual
      // event commander, not this newly-registered volunteer identity --
      // only the session (for sectorId) needs to come from the join above.
      final selfJoinedAccount = (await commanderStorage.loadAccount())!;
      await commanderStorage.saveAccount(
        StoredAccount(
          accessToken: fixture.accountToken,
          expiresAt: selfJoinedAccount.expiresAt,
          userId: selfJoinedAccount.userId,
          phoneE164: selfJoinedAccount.phoneE164,
          displayName: selfJoinedAccount.displayName,
        ),
      );

      final sosController = SosController(api: api, storage: searcherStorage);
      await sosController.trigger(lat: 31.7715, lng: 35.2170);

      final triggered = sosController.state;
      expect(triggered, isA<SosActive>());
      final alertId = (triggered as SosActive).alert.id;
      expect(triggered.alert.status, equals('active'));

      final alertsController = SosAlertsController(api: api, storage: commanderStorage);
      await alertsController.load();
      final loaded = alertsController.state as SosAlertsLoaded;
      expect(loaded.alerts.map((a) => a.id), contains(alertId));
      expect(
        loaded.alerts.firstWhere((a) => a.id == alertId).status,
        equals('active'),
      );

      await alertsController.acknowledge(alertId);
      final afterAck = (alertsController.state as SosAlertsLoaded).alerts
          .firstWhere((a) => a.id == alertId);
      expect(afterAck.status, equals('acknowledged'));

      // The searcher's own controller state is independent of the server
      // once set -- `trigger()` is a no-op while already `SosActive` (see
      // its guard), so `reset()` first, then re-trigger (idempotent
      // server-side, see SosController's docstring) to pick up the
      // acknowledged status.
      sosController.reset();
      await sosController.trigger();
      final afterReTrigger = sosController.state;
      expect(afterReTrigger, isA<SosActive>());
      expect((afterReTrigger as SosActive).alert.status, equals('acknowledged'));

      await alertsController.resolve(alertId);
      final afterResolve = (alertsController.state as SosAlertsLoaded).alerts
          .firstWhere((a) => a.id == alertId);
      expect(afterResolve.status, equals('resolved'));
    },
    timeout: const Timeout(Duration(seconds: 45)),
  );
}
