// Widget test for LocationStatusView, driven through the REAL
// LocationTrackingController (only its LocationSource/BatteryInfoProvider
// dependencies are faked -- see fake_location_source.dart /
// fake_battery_info_provider.dart) rather than a hand-rolled fake state, so
// this exercises the actual provider wiring in core/providers.dart, not
// just the widget's own switch statement.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lifesearch_mobile/core/api/api_client.dart';
import 'package:lifesearch_mobile/core/crypto/device_identity.dart';
import 'package:lifesearch_mobile/core/location/battery_info_provider.dart';
import 'package:lifesearch_mobile/core/location/location_source.dart';
import 'package:lifesearch_mobile/core/providers.dart';
import 'package:lifesearch_mobile/core/storage/stored_models.dart';
import 'package:lifesearch_mobile/core/storage/telemetry_buffer_store.dart';
import 'package:lifesearch_mobile/core/sync/ingest_sync_controller.dart';
import 'package:lifesearch_mobile/core/sync/sync_backoff_policy.dart';
import 'package:lifesearch_mobile/ui/screens/location_status_view.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../helpers/fake_battery_info_provider.dart';
import '../../helpers/fake_location_source.dart';
import '../../helpers/in_memory_key_value_store.dart';

http.Response _ingestJson({
  int accepted = 0,
  int duplicate = 0,
  int hexesTouched = 0,
}) => http.Response(
  jsonEncode({
    'accepted': accepted,
    'duplicate': duplicate,
    'decrypt_failed': 0,
    'signature_invalid': 0,
    'wrong_device': 0,
    'malformed': 0,
    'segments_opened': 0,
    'segments_extended': 0,
    'segments_closed': 0,
    'hexes_touched': hexesTouched,
  }),
  200,
  headers: {'content-type': 'application/json'},
);

Widget _wrap(ProviderContainer container) => UncontrolledProviderScope(
  container: container,
  child: const MaterialApp(home: LocationStatusView()),
);

/// `pumpAndSettle` refuses to return while the `TrackingStarting` state's
/// `CircularProgressIndicator` is on screen -- its implicit animation
/// schedules frames forever by design, so "settle" never happens as long as
/// it's visible, even briefly. Polling for a specific [finder] with plain
/// `pump`s sidesteps that.
///
/// Also load-bearing for a second, unrelated reason: real Timer/event-loop
/// progress inside `testWidgets` only reliably happens interleaved with
/// `tester.pump()` calls -- a bare `await Future.delayed(...)` with no
/// `pump()` calls around it can hang indefinitely (confirmed empirically
/// while building `IngestSyncController`'s tests). Any wait on real
/// Timer-driven state in this file should go through a `pump()` loop like
/// this one, never a standalone `Future.delayed`.
Future<void> pumpUntilFound(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(seconds: 10),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (finder.evaluate().isEmpty) {
    if (DateTime.now().isAfter(deadline)) {
      fail('finder never matched within $timeout: $finder');
    }
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  late ProviderContainer container;
  late FakeLocationSource location;
  late FakeBatteryInfoProvider battery;
  late TelemetryBufferStore buffer;
  late int ingestRequestCount;

  setUp(() async {
    sqfliteFfiInit();
    location = FakeLocationSource();
    battery = FakeBatteryInfoProvider(
      const BatteryStatus(levelPct: 90, isCharging: false),
    );
    ingestRequestCount = 0;
    // The isolate-backed `databaseFactoryFfi` doesn't work reliably inside
    // `testWidgets`'s FakeAsync test zone -- its background isolate's
    // SendPort replies arrive via the real event loop, outside FakeAsync's
    // control, so `pump()` can never observe them and `start()` hangs
    // forever. `databaseFactoryFfiNoIsolate` runs sqlite3 synchronously on
    // the calling isolate instead, which plays correctly with FakeAsync.
    // (The plain, non-widget controller test uses the isolate-backed
    // factory instead, since a bare `test()` isn't wrapped in FakeAsync.)
    buffer = TelemetryBufferStore(
      factory: databaseFactoryFfiNoIsolate,
      path: inMemoryDatabasePath,
    );

    container = ProviderContainer(
      overrides: [
        keyValueStoreProvider.overrideWith((ref) => InMemoryKeyValueStore()),
        locationSourceProvider.overrideWithValue(location),
        batteryInfoProvider.overrideWithValue(battery),
        telemetryBufferStoreProvider.overrideWithValue(buffer),
        apiClientProvider.overrideWith(
          (ref) => ApiClient(
            baseUrl: 'http://test.invalid',
            httpClient: MockClient((request) async {
              ingestRequestCount++;
              final blobs = (jsonDecode(request.body) as Map)['blobs'] as List;
              return _ingestJson(accepted: blobs.length);
            }),
          ),
        ),
        // Real intervals (30s base, 5s-5min backoff) would never fire
        // within a widget test's real-time budget -- tiny ones here so the
        // self-scheduling loop is actually observable, mirroring how
        // `location_status_view_test.dart`'s other overrides swap real
        // hardware for fast fakes.
        ingestSyncControllerProvider.overrideWith(
          (ref) => IngestSyncController(
            api: ref.watch(apiClientProvider),
            storage: ref.watch(secureStorageManagerProvider),
            buffer: ref.watch(telemetryBufferStoreProvider),
            baseInterval: const Duration(milliseconds: 50),
            backoff: const SyncBackoffPolicy(
              initialBackoff: Duration(milliseconds: 20),
              maxBackoff: Duration(milliseconds: 200),
            ),
          ),
        ),
      ],
    );

    final sodium = await container.read(sodiumProvider.future);
    final identity = DeviceIdentity(sodium);
    final storage = container.read(secureStorageManagerProvider);

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
        accessToken: 'tok',
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

  tearDown(() async {
    await buffer.close();
    container.dispose();
  });

  // The sync controller owns a real Timer once started. Flutter's test
  // binding asserts NO Timer is still pending once a test ends -- and that
  // check runs as part of `_runTestBody`, BEFORE either `tearDown` or
  // `addTearDown` callbacks get a chance to run (both fire only after the
  // whole test body, invariant check included, has completed). So
  // `container.dispose()` in `tearDown` above is too late, and so is
  // `addTearDown` -- every test that starts tracking (and therefore sync)
  // must call this directly, as the LAST statement in the test body itself.
  void stopControllers() {
    container.read(locationTrackingControllerProvider.notifier).stop();
    container.read(ingestSyncControllerProvider.notifier).stop();
  }

  testWidgets('shows idle state with a Start button before tracking begins', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap(container));

    expect(find.text('Tracking is off.'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Start tracking'), findsOneWidget);
  });

  testWidgets('tapping Start moves to the active state showing the tier', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap(container));

    await tester.tap(find.widgetWithText(FilledButton, 'Start tracking'));
    await pumpUntilFound(tester, find.textContaining('Tracking active'));

    expect(find.textContaining('high tier'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Stop tracking'), findsOneWidget);

    stopControllers();
  });

  testWidgets('an emitted position updates the sample and buffered counts', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap(container));
    await tester.tap(find.widgetWithText(FilledButton, 'Start tracking'));
    await pumpUntilFound(tester, find.textContaining('Tracking active'));

    location.emit(sampleAt());
    await pumpUntilFound(tester, find.text('1 samples this session'));

    expect(find.text('1 packets buffered locally'), findsOneWidget);

    stopControllers();
  });

  testWidgets('tapping Stop returns to the idle state', (tester) async {
    await tester.pumpWidget(_wrap(container));
    await tester.tap(find.widgetWithText(FilledButton, 'Start tracking'));
    await pumpUntilFound(tester, find.textContaining('Tracking active'));

    await tester.tap(find.widgetWithText(FilledButton, 'Stop tracking'));
    await pumpUntilFound(tester, find.text('Tracking is off.'));
  });

  testWidgets('a location permission denial surfaces as an error state', (
    tester,
  ) async {
    location.permissionResult = LocationPermissionResult.deniedForever;
    await tester.pumpWidget(_wrap(container));

    await tester.tap(find.widgetWithText(FilledButton, 'Start tracking'));
    await pumpUntilFound(tester, find.textContaining('permission not granted'));

    // Sync must NOT have started -- tracking never came up, so there was
    // nothing for it to do (see LocationStatusView.startBoth).
    expect(find.text('Sync is off.'), findsOneWidget);
  });

  testWidgets('sync is shown off before tracking starts', (tester) async {
    await tester.pumpWidget(_wrap(container));

    expect(find.text('Sync is off.'), findsOneWidget);
  });

  testWidgets('starting tracking also starts sync', (tester) async {
    await tester.pumpWidget(_wrap(container));

    await tester.tap(find.widgetWithText(FilledButton, 'Start tracking'));
    await pumpUntilFound(tester, find.textContaining('packets pending upload'));

    expect(find.text('Sync is off.'), findsNothing);

    stopControllers();
  });

  testWidgets(
    'an emitted position is buffered, then uploaded and cleared by the sync loop',
    (tester) async {
      await tester.pumpWidget(_wrap(container));
      await tester.tap(find.widgetWithText(FilledButton, 'Start tracking'));
      await pumpUntilFound(tester, find.textContaining('Tracking active'));

      location.emit(sampleAt());
      await pumpUntilFound(tester, find.text('1 packets buffered locally'));

      // The sync loop's own tiny `baseInterval` will pick this up on its
      // next tick without any further action from the test.
      await pumpUntilFound(tester, find.text('1 uploaded, 0 rejected'));

      expect(find.text('0 packets pending upload'), findsOneWidget);
      expect(await buffer.count(), equals(0));

      stopControllers();
    },
  );

  testWidgets('tapping Stop also stops sync', (tester) async {
    await tester.pumpWidget(_wrap(container));
    await tester.tap(find.widgetWithText(FilledButton, 'Start tracking'));
    await pumpUntilFound(tester, find.textContaining('packets pending upload'));

    await tester.tap(find.widgetWithText(FilledButton, 'Stop tracking'));
    await pumpUntilFound(tester, find.text('Sync is off.'));

    final countAfterStop = ingestRequestCount;
    // A bare `Future.delayed` outside of a `tester.pump()` loop hangs
    // indefinitely in this test environment (real Timer/event-loop
    // progress here only happens interleaved with `pump()` calls -- see
    // `pumpUntilFound`'s docstring). Several small pumps stand in for "give
    // a wrongly-still-scheduled tick a real chance to fire."
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 30));
    }
    expect(ingestRequestCount, equals(countAfterStop));
  });
}
