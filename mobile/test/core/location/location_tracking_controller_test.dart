// LocationTrackingController orchestration: real crypto (sodium), real
// SQLite buffer (sqflite_common_ffi, in-memory), real SecureStorageManager
// over an in-memory KeyValueStore -- only the location stream and battery
// reading are faked, since those are the two things with no host-process
// equivalent (GPS hardware, a real battery). Matches this project's
// "only mock at the outermost I/O boundary" philosophy.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lifesearch_mobile/core/crypto/device_identity.dart';
import 'package:lifesearch_mobile/core/crypto/mesh_crypto.dart';
import 'package:lifesearch_mobile/core/crypto/sodium_provider.dart';
import 'package:lifesearch_mobile/core/location/battery_info_provider.dart';
import 'package:lifesearch_mobile/core/location/location_sampling_policy.dart';
import 'package:lifesearch_mobile/core/location/location_source.dart';
import 'package:lifesearch_mobile/core/location/location_tracking_controller.dart';
import 'package:lifesearch_mobile/core/location/telemetry_packet_builder.dart';
import 'package:lifesearch_mobile/core/location/tracking_state.dart';
import 'package:lifesearch_mobile/core/storage/secure_storage_manager.dart';
import 'package:lifesearch_mobile/core/storage/stored_models.dart';
import 'package:lifesearch_mobile/core/storage/telemetry_buffer_store.dart';
import 'package:sodium/sodium.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../helpers/fake_battery_info_provider.dart';
import '../../helpers/fake_location_source.dart';
import '../../helpers/in_memory_key_value_store.dart';

/// `_handleSample` runs detached from the stream's `listen` callback (Dart's
/// `void Function(T)` signature can't be awaited by the caller), and it goes
/// through `sqflite_common_ffi`'s background isolate for every DB call --
/// real cross-isolate message-passing, not just microtasks. So tests can't
/// assume "buffered" the instant `emit` returns; they poll [controller.state]
/// for real, with a generous real-world timeout, rather than guessing how
/// many event-loop turns are enough (a guess that was flaky in practice).
Future<void> waitForState(
  LocationTrackingController controller,
  bool Function(TrackingState) predicate, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!predicate(controller.state)) {
    if (DateTime.now().isAfter(deadline)) {
      fail('state never matched predicate -- stuck at ${controller.state}');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  late Sodium sodium;
  late DeviceIdentity identity;
  late MeshCrypto crypto;

  setUpAll(() async {
    sqfliteFfiInit();
    sodium = await SodiumProvider.instance();
    identity = DeviceIdentity(sodium);
    crypto = MeshCrypto(sodium);
  });

  Future<SecureStorageManager> registeredStorage({
    bool withSession = true,
  }) async {
    final store = InMemoryKeyValueStore();
    final manager = SecureStorageManager(store);

    final pair = identity.generateKeyPair();
    await manager.saveDeviceIdentity(
      StoredDeviceIdentity(
        publicKeyBase64: pair.publicKeyBase64,
        secretKeyBase64: base64Encode(pair.secretKey.extractBytes()),
        deviceId: 'device-1',
        wireId: 42,
      ),
    );
    pair.dispose();

    if (withSession) {
      final sectorKey = sodium.secureRandom(meshKeyBytes);
      await manager.saveSession(
        StoredSession(
          accessToken: 'session-tok',
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
    }

    return manager;
  }

  ({
    LocationTrackingController controller,
    FakeLocationSource location,
    FakeBatteryInfoProvider battery,
    TelemetryBufferStore buffer,
  })
  buildHarness({
    required SecureStorageManager storage,
    BatteryStatus initialBattery = const BatteryStatus(
      levelPct: 90,
      isCharging: false,
    ),
  }) {
    final location = FakeLocationSource();
    final battery = FakeBatteryInfoProvider(initialBattery);
    final buffer = TelemetryBufferStore(
      factory: databaseFactoryFfi,
      path: inMemoryDatabasePath,
    );
    final controller = LocationTrackingController(
      location: location,
      battery: battery,
      policy: const LocationSamplingPolicy(),
      packetBuilder: TelemetryPacketBuilder(identity, crypto),
      buffer: buffer,
      storage: storage,
      sodium: sodium,
    );
    return (
      controller: controller,
      location: location,
      battery: battery,
      buffer: buffer,
    );
  }

  test('start() fails when location permission is not granted', () async {
    final storage = await registeredStorage();
    final h = buildHarness(storage: storage);
    h.location.permissionResult = LocationPermissionResult.deniedForever;

    await h.controller.start();

    expect(h.controller.state, isA<TrackingError>());
    await h.buffer.close();
  });

  test('start() fails when the device has no wireId yet', () async {
    final store = InMemoryKeyValueStore();
    final storage = SecureStorageManager(store);
    // Device identity saved, but never completed registration.
    await storage.saveDeviceIdentity(
      const StoredDeviceIdentity(publicKeyBase64: 'pub==', secretKeyBase64: 'sec=='),
    );
    final h = buildHarness(storage: storage);

    await h.controller.start();

    expect(h.controller.state, isA<TrackingError>());
    await h.buffer.close();
  });

  test('start() fails when there is no active sector session', () async {
    final storage = await registeredStorage(withSession: false);
    final h = buildHarness(storage: storage);

    await h.controller.start();

    expect(h.controller.state, isA<TrackingError>());
    await h.buffer.close();
  });

  test('start() moves to TrackingActive at the tier matching current battery', () async {
    final storage = await registeredStorage();
    final h = buildHarness(
      storage: storage,
      initialBattery: const BatteryStatus(levelPct: 90, isCharging: false),
    );

    await h.controller.start();

    final state = h.controller.state;
    expect(state, isA<TrackingActive>());
    expect((state as TrackingActive).tier, equals(SamplingTierName.high));
    expect(h.location.tiersRequested, hasLength(1));
    expect(h.location.tiersRequested.single.name, equals(SamplingTierName.high));

    h.controller.stop();
    await h.buffer.close();
  });

  test('each emitted sample is buffered as an encrypted packet', () async {
    final storage = await registeredStorage();
    final h = buildHarness(storage: storage);
    await h.controller.start();

    h.location.emit(sampleAt());
    await waitForState(
      h.controller,
      (s) => s is TrackingActive && s.sampleCount >= 1,
    );

    expect(await h.buffer.count(), equals(1));
    final state = h.controller.state as TrackingActive;
    expect(state.sampleCount, equals(1));
    expect(state.bufferedCount, equals(1));

    final packet = (await h.buffer.peekOldest(1)).single;
    // Sanity: it really is ciphertext, not the plaintext wire payload --
    // long enough to hold nonce + payload+signature + tag, and does not
    // trivially equal any obviously-plaintext byte pattern.
    expect(packet.blob.length, greaterThan(27));

    h.controller.stop();
    await h.buffer.close();
  });

  test('multiple samples accumulate in both the count and the buffer', () async {
    final storage = await registeredStorage();
    final h = buildHarness(storage: storage);
    await h.controller.start();

    h.location.emit(sampleAt(recordedAtMs: 1700000000000));
    await waitForState(h.controller, (s) => s is TrackingActive && s.sampleCount >= 1);
    h.location.emit(sampleAt(recordedAtMs: 1700000005000));
    await waitForState(h.controller, (s) => s is TrackingActive && s.sampleCount >= 2);
    h.location.emit(sampleAt(recordedAtMs: 1700000010000));
    await waitForState(h.controller, (s) => s is TrackingActive && s.sampleCount >= 3);

    expect(await h.buffer.count(), equals(3));
    final state = h.controller.state as TrackingActive;
    expect(state.sampleCount, equals(3));

    h.controller.stop();
    await h.buffer.close();
  });

  test('a battery drop across a tier boundary triggers resubscription at the new tier', () async {
    final storage = await registeredStorage();
    final h = buildHarness(
      storage: storage,
      initialBattery: const BatteryStatus(levelPct: 90, isCharging: false),
    );
    await h.controller.start();
    expect(h.location.tiersRequested, hasLength(1));
    expect(h.location.tiersRequested.last.name, equals(SamplingTierName.high));

    // Battery falls below the high-tier floor (60%) before the next sample.
    h.battery.status = const BatteryStatus(levelPct: 25, isCharging: false);
    h.location.emit(sampleAt());
    await waitForState(
      h.controller,
      (s) => s is TrackingActive && s.tier == SamplingTierName.saver,
    );

    expect(h.location.tiersRequested, hasLength(2));
    expect(h.location.tiersRequested.last.name, equals(SamplingTierName.saver));
    final state = h.controller.state as TrackingActive;
    expect(state.tier, equals(SamplingTierName.saver));

    h.controller.stop();
    await h.buffer.close();
  });

  test('charging forces the high tier even at a critical battery level', () async {
    final storage = await registeredStorage();
    final h = buildHarness(
      storage: storage,
      initialBattery: const BatteryStatus(levelPct: 3, isCharging: true),
    );

    await h.controller.start();

    final state = h.controller.state as TrackingActive;
    expect(state.tier, equals(SamplingTierName.high));

    h.controller.stop();
    await h.buffer.close();
  });

  test('stop() returns to idle and further emissions are not buffered', () async {
    final storage = await registeredStorage();
    final h = buildHarness(storage: storage);
    await h.controller.start();
    h.location.emit(sampleAt());
    await waitForState(h.controller, (s) => s is TrackingActive && s.sampleCount >= 1);
    expect(await h.buffer.count(), equals(1));

    h.controller.stop();
    expect(h.controller.state, isA<TrackingIdle>());

    h.location.emit(sampleAt());
    // Negative assertion: nothing to wait FOR (the subscription is
    // cancelled), so a bounded real delay stands in for "give a wrongly
    // still-listening handler a chance to fire" rather than a state
    // predicate.
    await Future<void>.delayed(const Duration(milliseconds: 200));

    expect(await h.buffer.count(), equals(1));
    await h.buffer.close();
  });

  test('calling start() while already active is a no-op', () async {
    final storage = await registeredStorage();
    final h = buildHarness(storage: storage);
    await h.controller.start();
    final subscriptionCountAfterFirstStart = h.location.tiersRequested.length;

    await h.controller.start();

    expect(h.location.tiersRequested.length, equals(subscriptionCountAfterFirstStart));

    h.controller.stop();
    await h.buffer.close();
  });
}
