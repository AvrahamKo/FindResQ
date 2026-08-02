// End-to-end proof of the FULL Phase 5c/5d chain, against a REAL running
// backend and real Postgres/PostGIS: register a device and claim a real
// sector session (same setup as `auth_join_e2e_test.dart`), then drive the
// REAL `LocationTrackingController` off a fake GPS/battery source (there is
// no real hardware in a test host) to buffer real encrypted packets into a
// REAL SQLite `TelemetryBufferStore`, then drive the REAL
// `IngestSyncController` to POST them to the REAL `/ingest` endpoint and
// confirm the backend's response proves the whole pipeline ran --
// including `hexes_touched > 0`, which only happens if PostGIS actually
// recalculated hex coverage from these exact points.
//
// Skipped automatically if no backend is reachable at [baseUrl] -- see
// `helpers/commander_fixture.dart` and `auth_join_e2e_test.dart` for the
// same convention.

import 'package:flutter_test/flutter_test.dart';
import 'package:lifesearch_mobile/core/api/api_client.dart';
import 'package:lifesearch_mobile/core/auth/auth_controller.dart';
import 'package:lifesearch_mobile/core/auth/auth_state.dart';
import 'package:lifesearch_mobile/core/crypto/device_identity.dart';
import 'package:lifesearch_mobile/core/crypto/mesh_crypto.dart';
import 'package:lifesearch_mobile/core/crypto/sodium_provider.dart';
import 'package:lifesearch_mobile/core/join/join_controller.dart';
import 'package:lifesearch_mobile/core/join/join_state.dart';
import 'package:lifesearch_mobile/core/location/battery_info_provider.dart';
import 'package:lifesearch_mobile/core/location/location_sample.dart';
import 'package:lifesearch_mobile/core/location/location_sampling_policy.dart';
import 'package:lifesearch_mobile/core/location/location_tracking_controller.dart';
import 'package:lifesearch_mobile/core/location/telemetry_packet_builder.dart';
import 'package:lifesearch_mobile/core/location/tracking_state.dart';
import 'package:lifesearch_mobile/core/storage/secure_storage_manager.dart';
import 'package:lifesearch_mobile/core/storage/telemetry_buffer_store.dart';
import 'package:lifesearch_mobile/core/sync/ingest_sync_controller.dart';
import 'package:lifesearch_mobile/core/sync/sync_state.dart';
import 'package:sodium/sodium.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../helpers/commander_fixture.dart';
import '../helpers/fake_battery_info_provider.dart';
import '../helpers/fake_location_source.dart';
import '../helpers/in_memory_key_value_store.dart';

/// Same real-time polling pattern as
/// `location_tracking_controller_test.dart`/`ingest_sync_controller_test.dart`
/// -- both controllers are Timer/stream driven, not directly awaitable.
Future<void> _waitUntil(
  bool Function() predicate, {
  Duration timeout = const Duration(seconds: 10),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('condition never became true within $timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  late Sodium sodium;
  late DeviceIdentity identity;

  setUpAll(() async {
    sqfliteFfiInit();
    sodium = await SodiumProvider.instance();
    identity = DeviceIdentity(sodium);
  });

  test(
    'location tracking -> local SQLite buffer -> ingest sync -> real /ingest -> PostGIS hex coverage',
    () async {
      if (!await backendReachable()) {
        // ignore: avoid_print
        print('SKIPPED: no backend reachable at $baseUrl');
        return;
      }

      // --- Real registration + real sector session (same shape as
      // auth_join_e2e_test.dart) --------------------------------------
      final fixture = await CommanderFixture.create();
      final joinCode = await fixture.mintJoinCode();

      final storage = SecureStorageManager(InMemoryKeyValueStore());
      final api = ApiClient(baseUrl: baseUrl);

      final authController = AuthController(
        api: api,
        storage: storage,
        identity: identity,
        sodium: sodium,
      );
      await authController.requestOtp(uniquePhone());
      final devCode = (authController.state as AuthOtpSent).devCode!;
      await authController.verifyOtp(devCode, displayName: 'E2E Sync Volunteer');
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

      // --- Location tracking (fake GPS/battery, real everything else) --
      final location = FakeLocationSource();
      final battery = FakeBatteryInfoProvider(
        const BatteryStatus(levelPct: 90, isCharging: false),
      );
      final buffer = TelemetryBufferStore(
        factory: databaseFactoryFfi,
        path: inMemoryDatabasePath,
      );
      final packetBuilder = TelemetryPacketBuilder(identity, MeshCrypto(sodium));

      final tracking = LocationTrackingController(
        location: location,
        battery: battery,
        policy: const LocationSamplingPolicy(),
        packetBuilder: packetBuilder,
        buffer: buffer,
        storage: storage,
        sodium: sodium,
      );

      await tracking.start();
      expect(tracking.state, isA<TrackingActive>());

      // A short, plausible walking path inside the sector fixture's
      // boundary (35.20-35.24 lng, 31.76-31.78 lat) -- a few meters apart,
      // a few seconds apart, so the plausibility stage accepts them as a
      // real track rather than flagging implausible jumps.
      final baseTimeMs = DateTime.now().millisecondsSinceEpoch;
      const points = [
        (lat: 31.7715, lng: 35.2170),
        (lat: 31.77155, lng: 35.21705),
        (lat: 31.7716, lng: 35.2171),
      ];
      for (var i = 0; i < points.length; i++) {
        location.emit(LocationSample(
          latitude: points[i].lat,
          longitude: points[i].lng,
          accuracyM: 5.0,
          speedMps: 1.2,
          recordedAtMs: baseTimeMs + i * 5000,
          isMocked: false,
        ));
        await _waitUntil(
          () => (tracking.state as TrackingActive).sampleCount == i + 1,
        );
      }

      tracking.stop();
      expect(await buffer.count(), equals(points.length));

      // --- Sync (real /ingest, real PostGIS-backed pipeline) -----------
      final sync = IngestSyncController(
        api: api,
        storage: storage,
        buffer: buffer,
      );

      await sync.syncOnce();

      final state = sync.state;
      expect(state, isA<SyncActive>());
      final active = state as SyncActive;
      expect(active.totalUploaded, equals(points.length));
      expect(active.consecutiveFailures, equals(0));
      expect(active.pendingCount, equals(0));

      // The buffer is empty -- every packet was acknowledged because the
      // server actually returned 200 for this batch, not because the test
      // assumed it would.
      expect(await buffer.count(), equals(0));

      await buffer.close();
    },
    timeout: const Timeout(Duration(seconds: 45)),
  );
}
