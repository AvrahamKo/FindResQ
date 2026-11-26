import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lifesearch_mobile/core/api/api_client.dart';
import 'package:lifesearch_mobile/core/providers.dart';
import 'package:lifesearch_mobile/core/storage/stored_models.dart';
import 'package:lifesearch_mobile/core/location/battery_info_provider.dart';
import 'package:lifesearch_mobile/core/storage/search_map_store.dart';
import 'package:lifesearch_mobile/core/storage/telemetry_buffer_store.dart';
import 'package:lifesearch_mobile/ui/screens/active_session_view.dart';
import 'package:lifesearch_mobile/ui/screens/report_form_view.dart';
import 'package:lifesearch_mobile/ui/widgets/hold_to_activate_sos_button.dart';
import 'package:lifesearch_mobile/ui/widgets/sector_map_view.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../helpers/fake_battery_info_provider.dart';
import '../../helpers/fake_location_source.dart';
import '../../helpers/in_memory_key_value_store.dart';

http.Response _json(Object body, int status) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

Map<String, dynamic> _alertJson() => {
  'id': 'alert-1',
  'sector_id': 's1',
  'device_id': 'device-1',
  'user_id': 'u1',
  'status': 'active',
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

/// A sector-permissions body. Defaults to a plain field searcher, which is
/// the case the alert-moderation gating actually has to get right.
Map<String, dynamic> _permissionsJson({
  String role = 'volunteer',
  bool canModerate = false,
}) => {
  'sector_id': 's1',
  'role': role,
  'is_commander': role == 'commander',
  'is_sector_manager': role == 'lead',
  'can_acknowledge_alerts': canModerate,
  'can_delete_alerts': canModerate,
  'can_moderate_members': canModerate,
};

Map<String, dynamic> _trackJson({
  String segmentId = 'seg-1',
  String userId = 'teammate-1',
  String? endedAt,
  List<List<double>>? points,
}) => {
  'segment_id': segmentId,
  'user_id': userId,
  'device_id': 'device-$userId',
  'movement_mode': 'walker',
  'started_at': '2030-01-01T00:00:00Z',
  'ended_at': endedAt,
  'point_count': 3,
  // [lat, lng] -- already swapped server-side.
  'points': points ??
      [
        [31.710, 35.205],
        [31.712, 35.207],
        [31.714, 35.209],
      ],
};

void main() {
  late ProviderContainer container;
  late List<String> requestedPaths;
  // Reassignable per test, so a test can put the signed-in user in a
  // different role or give the sector some teammates without rebuilding the
  // whole mock client.
  late List<Map<String, dynamic>> teamTracks;
  late Map<String, dynamic> permissionsJson;

  // The tile layer is disabled throughout: TileLayer issues real HTTP per
  // tile and leaves image-load timers pending, which trips the test
  // binding's no-pending-timers assertion. The polygon/marker layers -- the
  // parts this screen actually asserts on -- render without it, and that is
  // also exactly what the app shows offline.
  Widget wrap() => UncontrolledProviderScope(
    container: container,
    child: const MaterialApp(
      home: SessionActiveView(sectorName: 'Ridge North'),
    ),
  );

  setUp(() async {
    requestedPaths = [];
    teamTracks = [];
    permissionsJson = _permissionsJson();
    container = ProviderContainer(
      overrides: [
        mapTilesEnabledProvider.overrideWithValue(false),
        // No background polling in widget tests: a live Timer.periodic
        // outlives the pump and trips the binding's pending-timer
        // assertion. The one-shot initial fetch still runs, so the team
        // layer is exercised exactly as in the field.
        coveragePollIntervalProvider.overrideWithValue(null),
        teamTracksPollIntervalProvider.overrideWithValue(null),
        keyValueStoreProvider.overrideWith((ref) => InMemoryKeyValueStore()),
        locationSourceProvider.overrideWithValue(FakeLocationSource()),
        batteryInfoProvider.overrideWithValue(
          FakeBatteryInfoProvider(
            const BatteryStatus(levelPct: 82, isCharging: false),
          ),
        ),
        // Same no-isolate factory as location_status_view_test: the
        // isolate-backed one's replies never reach `pump()` inside a widget
        // test (see HANDOVER gotcha #8).
        telemetryBufferStoreProvider.overrideWithValue(
          TelemetryBufferStore(
            factory: databaseFactoryFfiNoIsolate,
            path: inMemoryDatabasePath,
          ),
        ),
        searchMapStoreProvider.overrideWithValue(
          SearchMapStore(
            factory: databaseFactoryFfiNoIsolate,
            path: inMemoryDatabasePath,
          ),
        ),
        apiClientProvider.overrideWith(
          (ref) => ApiClient(
            baseUrl: 'http://test.invalid',
            httpClient: MockClient((request) async {
              requestedPaths.add(request.url.path);
              if (request.url.path == '/sos') return _json(_alertJson(), 201);
              // Both of these must be matched BEFORE the catch-all
              // `/sectors/` boundary handler below, which would otherwise
              // answer them with a SectorOut body.
              if (request.url.path == '/sectors/s1/tracks') {
                return _json({
                  'sector_id': 's1',
                  'tracks': teamTracks,
                  'server_time': '2030-01-01T00:00:00Z',
                }, 200);
              }
              if (request.url.path == '/sectors/s1/permissions') {
                return _json(permissionsJson, 200);
              }
              if (request.url.path == '/sectors/s1/hexes') {
                return _json({
                  'sector_id': 's1',
                  'resolution': 12,
                  'server_time': '2030-01-01T00:00:01Z',
                  'hexes': [
                    {
                      'hex_id': '8c2db2b25155dff',
                      'cumulative_pod': '0.64',
                      'valid_contributions': 2,
                      'distinct_searchers': 2,
                      'last_contribution_at': '2030-01-01T00:00:00Z',
                      'boundary': [
                        [31.721, 35.211],
                        [31.722, 35.212],
                        [31.721, 35.213],
                      ],
                    },
                  ],
                }, 200);
              }
              if (request.url.path.startsWith('/sectors/')) {
                return _json({
                  'id': 's1',
                  'event_id': 'e1',
                  'name': 'Ridge North',
                  'status': 'open',
                  'boundary': {
                    'type': 'Polygon',
                    // GeoJSON order is [lng, lat] -- deliberately asymmetric
                    // values so a lat/lng swap would be visible.
                    'coordinates': [
                      [
                        [35.20, 31.70],
                        [35.24, 31.70],
                        [35.24, 31.74],
                        [35.20, 31.74],
                        [35.20, 31.70],
                      ],
                    ],
                  },
                }, 200);
              }
              return _json({
                'error': {'code': 'x', 'message': 'unexpected'},
              }, 500);
            }),
          ),
        ),
      ],
    );

    // The screen watches locationTrackingControllerProvider, which resolves
    // sodium via `requireValue` -- that throws while the FutureProvider is
    // still AsyncLoading, so it has to be resolved before the first pump.
    // Real libsodium, not a fake: it loads fine in a host test process.
    await container.read(sodiumProvider.future);

    final storage = container.read(secureStorageManagerProvider);
    await storage.saveAccount(
      StoredAccount(
        accessToken: 'account-tok',
        expiresAt: DateTime.now().add(const Duration(days: 1)),
        userId: 'u1',
        phoneE164: '+15551234567',
        displayName: 'Vol',
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
        role: 'volunteer',
        movementMode: 'walker',
      ),
    );
  });

  tearDown(() => container.dispose());

  testWidgets('shows the sector name and the status chips', (tester) async {
    await tester.pumpWidget(wrap());
    await tester.pump();

    expect(find.byKey(const Key('status_sector_name')), findsOneWidget);
    expect(find.text('Ridge North'), findsOneWidget);
    expect(find.byKey(const Key('status_gps')), findsOneWidget);
    expect(find.byKey(const Key('status_battery')), findsOneWidget);
    expect(find.byKey(const Key('status_uplink')), findsOneWidget);
    // Tracking hasn't been started, so the bar must say so rather than
    // implying a fix it doesn't have.
    expect(find.text('GPS OFF'), findsOneWidget);
  });

  testWidgets('a short press does NOT trigger SOS', (tester) async {
    await tester.pumpWidget(wrap());
    await tester.pump();

    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const Key('hold_sos_button'))),
    );
    await tester.pump(); // resolve the arena so the hold genuinely starts
    // Well short of the required hold -- this must NOT pass because the
    // press never registered, so the pump above matters.
    await tester.pump(const Duration(milliseconds: 300));
    await gesture.up();
    await tester.pumpAndSettle();

    expect(requestedPaths.contains('/sos'), isFalse);
  });

  testWidgets('holding for the full duration triggers SOS', (tester) async {
    await tester.pumpWidget(wrap());
    await tester.pump();

    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const Key('hold_sos_button'))),
    );
    // A zero-duration pump first: onTapDown only fires once the gesture
    // arena resolves, and folding that into the same pump that advances the
    // clock would start the hold AFTER the elapsed time was consumed.
    await tester.pump();
    await tester.pump(sosHoldDuration + const Duration(milliseconds: 50));
    await gesture.up();
    await tester.pumpAndSettle();

    expect(requestedPaths.contains('/sos'), isTrue);
  });

  testWidgets('an open alert disables the hold button and offers Manage', (
    tester,
  ) async {
    await tester.pumpWidget(wrap());
    await tester.pump();

    // Drive a real trigger so the state comes from the controller, not a stub.
    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const Key('hold_sos_button'))),
    );
    // A zero-duration pump first: onTapDown only fires once the gesture
    // arena resolves, and folding that into the same pump that advances the
    // clock would start the hold AFTER the elapsed time was consumed.
    await tester.pump();
    await tester.pump(sosHoldDuration + const Duration(milliseconds: 50));
    await gesture.up();
    await tester.pumpAndSettle();

    expect(find.text('SOS ACTIVE'), findsOneWidget);
    expect(find.byKey(const Key('sos_manage_button')), findsOneWidget);

    final requestsBefore = requestedPaths.length;
    final second = await tester.startGesture(
      tester.getCenter(find.byKey(const Key('hold_sos_button'))),
    );
    await tester.pump(sosHoldDuration + const Duration(milliseconds: 50));
    await second.up();
    await tester.pumpAndSettle();

    // Holding again while an alert is open must not fire a second trigger.
    expect(requestedPaths.length, equals(requestsBefore));
  });

  testWidgets(
    'the quick report grid opens the form with the kind preselected',
    (tester) async {
      await tester.pumpWidget(wrap());
      await tester.pump();

      await tester.tap(find.byKey(const Key('quick_report_button')));
      await tester.pumpAndSettle();

      // All five wire-format kinds are offered.
      for (final kind in const [
        'subject_found',
        'medical',
        'item_found',
        'hazard',
        'no_passage',
      ]) {
        expect(find.byKey(Key('quick_report_$kind')), findsOneWidget);
      }

      await tester.tap(find.byKey(const Key('quick_report_hazard')));
      await tester.pumpAndSettle();

      expect(find.byType(ReportFormView), findsOneWidget);
      final form = tester.widget<ReportFormView>(find.byType(ReportFormView));
      expect(form.initialKind, equals('hazard'));
      // The dropdown reflects it, rather than silently defaulting.
      expect(find.text('Hazard'), findsOneWidget);
    },
  );

  testWidgets('fetches the sector boundary with the ACCOUNT token', (
    tester,
  ) async {
    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    expect(requestedPaths.contains('/sectors/s1'), isTrue);
    final sector = await container.read(activeSectorProvider.future);
    expect(sector, isNotNull);
    expect(sector!.boundary.length, equals(5));
    // Proves the GeoJSON [lng, lat] pair was not swapped: latitudes are the
    // ~31.7 values, longitudes the ~35.2 ones.
    expect(sector.boundary.first.latitude, closeTo(31.70, 1e-9));
    expect(sector.boundary.first.longitude, closeTo(35.20, 1e-9));
  });

  testWidgets('shows cached team coverage and switches to personal trail', (
    tester,
  ) async {
    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    expect(requestedPaths.contains('/sectors/s1/hexes'), isTrue);
    expect(find.byKey(const Key('coverage_layer_toggle')), findsOneWidget);
    expect(find.byKey(const Key('coverage_legend')), findsOneWidget);
    expect(find.text('נמוך  1–39%'), findsOneWidget);
    expect(find.text('חלקי  40–74%'), findsOneWidget);
    expect(find.text('טוב  75–100%'), findsOneWidget);
    expect(find.text('טרם נסרק  0%'), findsOneWidget);
    expect(find.text('Team'), findsOneWidget);
    expect(find.text('Mine'), findsOneWidget);

    var map = tester.widget<SectorMapView>(find.byType(SectorMapView));
    expect(map.teamCoverage, hasLength(1));
    expect(map.coverageLayer, SearchCoverageLayer.team);
    expect(container.read(coveragePollingEnabledProvider), isTrue);

    map.onCoverageCellTap!(map.teamCoverage.single);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('coverage_details_sheet')), findsOneWidget);
    expect(find.byKey(const Key('coverage_percent')), findsOneWidget);
    expect(find.text('64%'), findsOneWidget);
    expect(find.text('כיסוי חלקי'), findsOneWidget);
    expect(find.text('2 מחפשים'), findsOneWidget);
    expect(find.textContaining('01/01/2030'), findsOneWidget);

    Navigator.of(tester.element(find.byType(SectorMapView))).pop();
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('coverage_mine')));
    await tester.pump();
    map = tester.widget<SectorMapView>(find.byType(SectorMapView));
    expect(map.coverageLayer, SearchCoverageLayer.mine);
    expect(find.byKey(const Key('coverage_legend')), findsNothing);
    expect(container.read(coveragePollingEnabledProvider), isFalse);
  });

  testWidgets('shows the most recent server synchronization time', (
    tester,
  ) async {
    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('last_server_sync')), findsOneWidget);
    expect(find.textContaining('Last sync:'), findsOneWidget);
    expect(find.text('Last sync: never'), findsNothing);
  });

  testWidgets('coverage legend fits a narrow Android screen', (tester) async {
    tester.view.physicalSize = const Size(412, 915);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('coverage_legend')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  group('team scan paths', () {
    testWidgets('the Team layer shows EVERY teammate, not just this device', (
      tester,
    ) async {
      // The bug: switching to "Team" used to render only the local personal
      // trail, so a searcher saw their own line twice and never a
      // teammate's.
      teamTracks = [
        _trackJson(segmentId: 'seg-a', userId: 'alice'),
        _trackJson(segmentId: 'seg-b', userId: 'bob', endedAt: '2030-01-01T01:00:00Z'),
        _trackJson(segmentId: 'seg-c', userId: 'u1'),
      ];

      await tester.pumpWidget(wrap());
      await tester.pumpAndSettle();

      expect(requestedPaths.contains('/sectors/s1/tracks'), isTrue);
      final map = tester.widget<SectorMapView>(find.byType(SectorMapView));
      expect(map.coverageLayer, SearchCoverageLayer.team);
      expect(
        map.teamTracks.map((t) => t.userId).toSet(),
        {'alice', 'bob', 'u1'},
      );
      // A still-moving searcher is distinguishable from a finished traverse.
      expect(map.teamTracks.firstWhere((t) => t.userId == 'alice').isLive, isTrue);
      expect(map.teamTracks.firstWhere((t) => t.userId == 'bob').isLive, isFalse);
    });

    testWidgets('team paths carry (lat, lng), not transposed coordinates', (
      tester,
    ) async {
      teamTracks = [
        _trackJson(
          points: [
            [31.715, 35.208],
            [31.717, 35.209],
          ],
        ),
      ];

      await tester.pumpWidget(wrap());
      await tester.pumpAndSettle();

      final map = tester.widget<SectorMapView>(find.byType(SectorMapView));
      final first = map.teamTracks.single.points.first;
      expect(first.latitude, 31.715);
      expect(first.longitude, 35.208);
    });

    testWidgets('the Mine layer drops the team paths entirely', (tester) async {
      teamTracks = [_trackJson(userId: 'alice')];

      await tester.pumpWidget(wrap());
      await tester.pumpAndSettle();
      expect(
        tester.widget<SectorMapView>(find.byType(SectorMapView)).teamTracks,
        isNotEmpty,
      );

      await tester.tap(find.byKey(const Key('coverage_mine')));
      await tester.pump();

      // Not merely hidden by the map widget: the screen stops watching the
      // provider at all, so its polling stops with it.
      final map = tester.widget<SectorMapView>(find.byType(SectorMapView));
      expect(map.coverageLayer, SearchCoverageLayer.mine);
      expect(map.teamTracks, isEmpty);
    });
  });

  group('alert moderation entry point', () {
    testWidgets('a field volunteer is not offered the SOS alerts screen', (
      tester,
    ) async {
      // Listing a sector's alerts is Lead/Commander-only server-side, so
      // for a searcher the menu entry could only ever lead to an error.
      permissionsJson = _permissionsJson(role: 'volunteer', canModerate: false);

      await tester.pumpWidget(wrap());
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('session_overflow_menu')));
      await tester.pumpAndSettle();

      expect(find.text('Sector reports'), findsOneWidget);
      expect(find.byKey(const Key('menu_sos_alerts')), findsNothing);
    });

    testWidgets('a sector manager is', (tester) async {
      permissionsJson = _permissionsJson(role: 'lead', canModerate: true);

      await tester.pumpWidget(wrap());
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('session_overflow_menu')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('menu_sos_alerts')), findsOneWidget);
    });
  });
}
