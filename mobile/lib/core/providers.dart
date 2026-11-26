/// Central Riverpod provider wiring.
///
/// Every provider that touches the outside world (network, storage, native
/// crypto) is overridable -- tests replace [apiClientProvider] with a
/// `MockClient`-backed instance and [keyValueStoreProvider] with an
/// in-memory fake, without touching controller logic at all.
library;

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sodium/sodium.dart';
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'api/api_client.dart';
import 'api/api_models.dart';
import 'auth/auth_controller.dart';
import 'auth/auth_state.dart';
import 'crypto/device_identity.dart';
import 'crypto/mesh_crypto.dart';
import 'crypto/sodium_provider.dart';
import 'coverage/coverage_controller.dart';
import 'coverage/coverage_state.dart';
import 'coverage/personal_trail_controller.dart';
import 'coverage/team_tracks_controller.dart';
import 'coverage/team_tracks_state.dart';
import 'join/join_controller.dart';
import 'join/join_state.dart';
import 'location/battery_info_provider.dart';
import 'location/location_source.dart';
import 'location/location_sampling_policy.dart';
import 'location/location_tracking_controller.dart';
import 'location/telemetry_packet_builder.dart';
import 'location/tracking_state.dart';
import 'reports/report_controller.dart';
import 'reports/report_packet_builder.dart';
import 'reports/report_state.dart';
import 'reports/reports_list_controller.dart';
import 'reports/reports_list_state.dart';
import 'storage/key_value_store.dart';
import 'storage/secure_key_value_store.dart';
import 'storage/secure_storage_manager.dart';
import 'storage/search_map_store.dart';
import 'storage/telemetry_buffer_store.dart';
import 'sos/sos_alerts_controller.dart';
import 'sos/sos_alerts_state.dart';
import 'sos/sos_controller.dart';
import 'sos/sos_state.dart';
import 'sync/ingest_sync_controller.dart';
import 'sync/sync_state.dart';

/// Overridden in `main.dart` with the real backend URL, and in tests with
/// whatever the test harness is actually listening on.
final baseUrlProvider = Provider<String>(
  (ref) => throw UnimplementedError('baseUrlProvider must be overridden'),
);

final sodiumProvider = FutureProvider<Sodium>(
  (ref) => SodiumProvider.instance(),
);

final keyValueStoreProvider = Provider<KeyValueStore>(
  (ref) => SecureKeyValueStore(),
);

final secureStorageManagerProvider = Provider<SecureStorageManager>(
  (ref) => SecureStorageManager(ref.watch(keyValueStoreProvider)),
);

final apiClientProvider = Provider<ApiClient>(
  (ref) => ApiClient(baseUrl: ref.watch(baseUrlProvider)),
);

final deviceIdentityProvider = Provider<DeviceIdentity>((ref) {
  final sodium = ref.watch(sodiumProvider).requireValue;
  return DeviceIdentity(sodium);
});

final authControllerProvider = StateNotifierProvider<AuthController, AuthState>(
  (ref) {
    final sodium = ref.watch(sodiumProvider).requireValue;
    return AuthController(
      api: ref.watch(apiClientProvider),
      storage: ref.watch(secureStorageManagerProvider),
      identity: ref.watch(deviceIdentityProvider),
      sodium: sodium,
    );
  },
);

final joinControllerProvider = StateNotifierProvider<JoinController, JoinState>(
  (ref) {
    return JoinController(
      api: ref.watch(apiClientProvider),
      storage: ref.watch(secureStorageManagerProvider),
    );
  },
);

// --- Location / telemetry buffer (Phase 5c) --------------------------------

/// `sqflite`'s plugin factory needs a real Android/iOS platform channel;
/// everywhere else (desktop, and every `flutter test` host process) uses
/// `sqflite_common_ffi`'s in-process factory instead -- both implement the
/// same `DatabaseFactory` interface from `sqflite_common`, so
/// [TelemetryBufferStore] never needs to know which one it was handed.
DatabaseFactory _resolveDatabaseFactory() {
  if (Platform.isAndroid || Platform.isIOS) {
    return sqflite.databaseFactory;
  }
  sqfliteFfiInit();
  return databaseFactoryFfi;
}

final databaseFactoryProvider = Provider<DatabaseFactory>(
  (ref) => _resolveDatabaseFactory(),
);

final telemetryBufferStoreProvider = Provider<TelemetryBufferStore>((ref) {
  final store = TelemetryBufferStore(
    factory: ref.watch(databaseFactoryProvider),
    path: 'lifesearch_telemetry_buffer.db',
  );
  ref.onDispose(() => store.close());
  return store;
});

final searchMapStoreProvider = Provider<SearchMapStore>((ref) {
  final store = SearchMapStore(
    factory: ref.watch(databaseFactoryProvider),
    path: 'lifesearch_search_map.db',
  );
  ref.onDispose(() => store.close());
  return store;
});

final personalTrailControllerProvider =
    StateNotifierProvider<PersonalTrailController, List<PersonalTrackPoint>>((
      ref,
    ) {
      final controller = PersonalTrailController(
        mapStore: ref.watch(searchMapStoreProvider),
        storage: ref.watch(secureStorageManagerProvider),
      );
      return controller;
    });

final batteryInfoProvider = Provider<BatteryInfoProvider>(
  (ref) => BatteryPlusInfoProvider(),
);

final locationSourceProvider = Provider<LocationSource>(
  (ref) => GeolocatorLocationSource(),
);

final telemetryPacketBuilderProvider = Provider<TelemetryPacketBuilder>((ref) {
  final sodium = ref.watch(sodiumProvider).requireValue;
  return TelemetryPacketBuilder(
    ref.watch(deviceIdentityProvider),
    MeshCrypto(sodium),
  );
});

final locationTrackingControllerProvider =
    StateNotifierProvider<LocationTrackingController, TrackingState>((ref) {
      final sodium = ref.watch(sodiumProvider).requireValue;
      return LocationTrackingController(
        location: ref.watch(locationSourceProvider),
        battery: ref.watch(batteryInfoProvider),
        policy: const LocationSamplingPolicy(),
        packetBuilder: ref.watch(telemetryPacketBuilderProvider),
        buffer: ref.watch(telemetryBufferStoreProvider),
        storage: ref.watch(secureStorageManagerProvider),
        sodium: sodium,
        personalTrail: ref.watch(personalTrailControllerProvider.notifier),
      );
    });

// --- Ingest sync (Phase 5d) --------------------------------------------

final ingestSyncControllerProvider =
    StateNotifierProvider<IngestSyncController, SyncState>((ref) {
      return IngestSyncController(
        api: ref.watch(apiClientProvider),
        storage: ref.watch(secureStorageManagerProvider),
        buffer: ref.watch(telemetryBufferStoreProvider),
      );
    });

/// How often the active field map refreshes the team's H3 coverage cells.
///
/// An ingest by this handset already triggers an immediate refresh, but that
/// signal cannot reveal ground scanned by a different handset. A modest poll
/// keeps the honeycomb aligned with the Commander dashboard without holding
/// a WebSocket or keeping the radio continuously awake. Null disables it.
final coveragePollIntervalProvider = Provider<Duration?>(
  (ref) => const Duration(seconds: 90),
);

/// Controlled by the active map: false on the personal layer and whenever
/// Android backgrounds the activity. This cancels the timer rather than
/// merely letting it wake up and decide not to make a request.
final coveragePollingEnabledProvider = StateProvider.autoDispose<bool>(
  (ref) => true,
);

final coverageControllerProvider =
    StateNotifierProvider.autoDispose<CoverageController, CoverageMapState>((
      ref,
    ) {
      final controller = CoverageController(
        api: ref.watch(apiClientProvider),
        storage: ref.watch(secureStorageManagerProvider),
        mapStore: ref.watch(searchMapStoreProvider),
      );
      unawaited(controller.start());

      final interval = ref.watch(coveragePollIntervalProvider);
      Timer? timer;
      ref.listen<bool>(coveragePollingEnabledProvider, (previous, enabled) {
        timer?.cancel();
        timer = null;
        if (!enabled || interval == null) return;

        // Switching back to Team/foreground should catch up immediately;
        // the initial true value is already covered by controller.start().
        if (previous == false) unawaited(controller.refresh());
        timer = Timer.periodic(
          interval,
          (_) => unawaited(controller.refresh()),
        );
      }, fireImmediately: true);
      ref.onDispose(() => timer?.cancel());

      ref.listen<DateTime?>(
        ingestSyncControllerProvider.select(
          (sync) => sync is SyncActive ? sync.lastSyncAt : null,
        ),
        (previous, next) {
          if (next != null &&
              next != previous &&
              ref.read(coveragePollingEnabledProvider)) {
            unawaited(controller.refresh());
          }
        },
      );
      return controller;
    });

/// How often the team layer re-fetches teammates' paths.
///
/// Overridable, and set to null in widget tests: a `Timer.periodic` that
/// outlives a pump trips the test binding's pending-timer assertion (the
/// same hazard as [mapTilesEnabledProvider]'s tile loads, HANDOVER gotcha
/// #10). Null means "fetch once, never poll", which is also a legitimate
/// production configuration for a device being nursed through low battery.
///
/// 20s is a deliberate compromise: teammates move at walking pace, so a
/// faster poll would spend radio and battery re-drawing lines that have
/// barely changed, and the requests are deltas rather than full snapshots.
final teamTracksPollIntervalProvider = Provider<Duration?>(
  (ref) => const Duration(seconds: 20),
);

/// The team's scan paths, polled while the map is on screen.
///
/// Refreshes on the same signal as [coverageControllerProvider] -- a
/// completed ingest sync -- plus its own slow timer. The sync signal alone
/// is not enough here: this device uploading ITS points says nothing about
/// whether a teammate has moved, and the team layer would freeze whenever
/// this searcher stood still. `autoDispose` stops the timer when the map is
/// gone, which matters on a battery this app spends the rest of its effort
/// conserving.
final teamTracksControllerProvider =
    StateNotifierProvider.autoDispose<TeamTracksController, TeamTracksState>((
      ref,
    ) {
      final controller = TeamTracksController(
        api: ref.watch(apiClientProvider),
        storage: ref.watch(secureStorageManagerProvider),
      );
      unawaited(controller.reload());

      final interval = ref.watch(teamTracksPollIntervalProvider);
      if (interval != null) {
        final timer = Timer.periodic(
          interval,
          (_) => unawaited(controller.refresh()),
        );
        ref.onDispose(timer.cancel);
      }

      ref.listen<DateTime?>(
        ingestSyncControllerProvider.select(
          (sync) => sync is SyncActive ? sync.lastSyncAt : null,
        ),
        (previous, next) {
          if (next != null && next != previous) {
            unawaited(controller.refresh());
          }
        },
      );
      return controller;
    });

/// What this user may do in their current sector, per the BACKEND.
///
/// Drives whether alert-moderation controls are offered at all. Falls back
/// to [SectorPermissions.none] -- no elevated rights -- on any failure,
/// because the failure mode of guessing high (offering an Acknowledge
/// button that the server will refuse) is a searcher who believes an
/// emergency has been picked up when it has not.
final sectorPermissionsProvider = FutureProvider<SectorPermissions>((
  ref,
) async {
  final storage = ref.watch(secureStorageManagerProvider);
  final session = await storage.loadSession();
  final account = await storage.loadAccount();
  if (session == null || account == null) return SectorPermissions.none;
  try {
    return await ref
        .watch(apiClientProvider)
        .getSectorPermissions(
          accountToken: account.accessToken,
          sectorId: session.sectorId,
        );
  } on Exception {
    return SectorPermissions.none;
  }
});

// --- SOS (Phase 6) -------------------------------------------------------

final sosControllerProvider = StateNotifierProvider<SosController, SosState>((
  ref,
) {
  return SosController(
    api: ref.watch(apiClientProvider),
    storage: ref.watch(secureStorageManagerProvider),
  );
});

final sosAlertsControllerProvider =
    StateNotifierProvider<SosAlertsController, SosAlertsState>((ref) {
      return SosAlertsController(
        api: ref.watch(apiClientProvider),
        storage: ref.watch(secureStorageManagerProvider),
      );
    });

// --- Reports (Phase 6b) --------------------------------------------------

final reportPacketBuilderProvider = Provider<ReportPacketBuilder>((ref) {
  final sodium = ref.watch(sodiumProvider).requireValue;
  return ReportPacketBuilder(
    ref.watch(deviceIdentityProvider),
    MeshCrypto(sodium),
  );
});

final reportControllerProvider =
    StateNotifierProvider<ReportController, ReportState>((ref) {
      final sodium = ref.watch(sodiumProvider).requireValue;
      return ReportController(
        api: ref.watch(apiClientProvider),
        storage: ref.watch(secureStorageManagerProvider),
        location: ref.watch(locationSourceProvider),
        packetBuilder: ref.watch(reportPacketBuilderProvider),
        sodium: sodium,
      );
    });

final reportsListControllerProvider =
    StateNotifierProvider<ReportsListController, ReportsListState>((ref) {
      return ReportsListController(
        api: ref.watch(apiClientProvider),
        storage: ref.watch(secureStorageManagerProvider),
      );
    });

// --- Active-session HUD (Phase 6d) ---------------------------------------

/// The sector the device currently holds a session for, including its
/// boundary polygon, for the tactical map.
///
/// Returns null rather than throwing when it can't be loaded: a searcher in
/// a dead zone still needs the rest of the screen (SOS, reports, their own
/// position) to work, so the map degrades to "your position only" instead of
/// the whole screen erroring out. Uses the ACCOUNT token -- any sector
/// member may read their own sector (`_require_sector_visibility`).
final activeSectorProvider = FutureProvider<SectorInfo?>((ref) async {
  final storage = ref.watch(secureStorageManagerProvider);
  final session = await storage.loadSession();
  final account = await storage.loadAccount();
  if (session == null || account == null) return null;
  try {
    return await ref
        .watch(apiClientProvider)
        .getSector(
          accountToken: account.accessToken,
          sectorId: session.sectorId,
        );
  } on Exception {
    return null;
  }
});

/// One-shot battery read, for the status bar BEFORE tracking starts. Once
/// tracking is active the HUD prefers `TrackingActive.batteryPct`, which
/// updates with every sample and is the same reading that picked the
/// sampling tier -- this provider exists only so the bar isn't blank while
/// tracking is idle.
final batteryStatusProvider = FutureProvider<BatteryStatus?>((ref) async {
  try {
    return await ref.watch(batteryInfoProvider).currentStatus();
  } on Exception {
    return null;
  }
});

/// Whether the tactical map draws an online basemap under the sector.
///
/// Overridden to false in widget tests: `TileLayer` issues real HTTP for
/// every tile and keeps image-load timers alive, which trips the test
/// binding's pending-timer assertion (see HANDOVER gotcha #10). The sector
/// polygon and position marker render without it, which is also exactly
/// what a searcher sees in a dead zone -- so tests exercise the same code
/// path as offline field use.
final mapTilesEnabledProvider = Provider<bool>((ref) => true);
