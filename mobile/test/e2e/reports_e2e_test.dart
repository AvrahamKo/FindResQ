// End-to-end proof of the field-report pipeline against a REAL running
// backend and real Postgres: a searcher files a real encrypted report via
// [ReportController], any sector member (the same searcher) sees it via
// [ReportsListController] (GET /sectors/{id}/reports), and the Commander
// acknowledges it -- nothing in this chain is mocked except the GPS fix
// (there's no real hardware in a test host, same reasoning as
// `location_sync_e2e_test.dart`).
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
import 'package:lifesearch_mobile/core/reports/report_controller.dart';
import 'package:lifesearch_mobile/core/reports/report_packet_builder.dart';
import 'package:lifesearch_mobile/core/reports/report_state.dart';
import 'package:lifesearch_mobile/core/reports/reports_list_controller.dart';
import 'package:lifesearch_mobile/core/reports/reports_list_state.dart';
import 'package:lifesearch_mobile/core/storage/secure_storage_manager.dart';
import 'package:sodium/sodium.dart';

import '../helpers/commander_fixture.dart';
import '../helpers/fake_location_source.dart';
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

  test(
    'a real report is filed, visible to the sector, and acknowledgeable by the Commander',
    () async {
      if (!await backendReachable()) {
        // ignore: avoid_print
        print('SKIPPED: no backend reachable at $baseUrl');
        return;
      }

      final fixture = await CommanderFixture.create();
      final joinCode = await fixture.mintJoinCode();

      final storage = SecureStorageManager(InMemoryKeyValueStore());
      final authController = AuthController(
        api: api,
        storage: storage,
        identity: identity,
        sodium: sodium,
      );
      await authController.requestOtp(uniquePhone());
      final devCode = (authController.state as AuthOtpSent).devCode!;
      await authController.verifyOtp(devCode, displayName: 'E2E Reporter');
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

      // --- File the report (fake GPS, real everything else) --------------
      final location = FakeLocationSource();
      location.currentPosition = sampleAt(latitude: 31.7715, longitude: 35.2170);

      final reportController = ReportController(
        api: api,
        storage: storage,
        location: location,
        packetBuilder: ReportPacketBuilder(identity, MeshCrypto(sodium)),
        sodium: sodium,
      );

      await reportController.submit(kind: 'hazard', note: 'E2E: downed power line.');

      final submitted = reportController.state;
      expect(submitted, isA<ReportSubmitted>());
      expect((submitted as ReportSubmitted).kind, equals('hazard'));

      // --- Any sector member (the same reporter) can see it --------------
      final listController = ReportsListController(api: api, storage: storage);
      await listController.load();

      final loaded = listController.state;
      expect(loaded, isA<ReportsListLoaded>());
      final reports = (loaded as ReportsListLoaded).reports;
      expect(reports, isNotEmpty);
      final filed = reports.firstWhere((r) => r.note == 'E2E: downed power line.');
      expect(filed.kind, equals('hazard'));
      expect(filed.status, equals('open'));
      expect(filed.lat, closeTo(31.7715, 1e-4));
      expect(filed.lng, closeTo(35.2170, 1e-4));

      // --- The Commander acknowledges it ----------------------------------
      final acknowledged = await api.acknowledgeReport(
        accountToken: fixture.accountToken,
        reportId: filed.id,
      );
      expect(acknowledged.status, equals('acknowledged'));
      expect(acknowledged.acknowledgedBy, isNotNull);
    },
    timeout: const Timeout(Duration(seconds: 45)),
  );
}
