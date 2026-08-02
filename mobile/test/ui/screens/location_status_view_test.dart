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
import 'package:lifesearch_mobile/core/crypto/device_identity.dart';
import 'package:lifesearch_mobile/core/location/battery_info_provider.dart';
import 'package:lifesearch_mobile/core/location/location_source.dart';
import 'package:lifesearch_mobile/core/providers.dart';
import 'package:lifesearch_mobile/core/storage/stored_models.dart';
import 'package:lifesearch_mobile/core/storage/telemetry_buffer_store.dart';
import 'package:lifesearch_mobile/ui/screens/location_status_view.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../helpers/fake_battery_info_provider.dart';
import '../../helpers/fake_location_source.dart';
import '../../helpers/in_memory_key_value_store.dart';

Widget _wrap(ProviderContainer container) => UncontrolledProviderScope(
  container: container,
  child: const MaterialApp(home: LocationStatusView()),
);

/// `pumpAndSettle` refuses to return while the `TrackingStarting` state's
/// `CircularProgressIndicator` is on screen -- its implicit animation
/// schedules frames forever by design, so "settle" never happens as long as
/// it's visible, even briefly. Polling for a specific [finder] with plain
/// `pump`s sidesteps that.
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

  setUp(() async {
    sqfliteFfiInit();
    location = FakeLocationSource();
    battery = FakeBatteryInfoProvider(
      const BatteryStatus(levelPct: 90, isCharging: false),
    );
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
  });
}
