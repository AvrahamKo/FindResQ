/// Orchestrates background location tracking: resolves the current
/// battery-aware sampling tier, subscribes to [LocationSource] at that tier,
/// and turns every emitted [LocationSample] into an encrypted telemetry
/// packet buffered locally via [TelemetryBufferStore].
///
/// Deliberately does NOT call `/ingest` -- wiring the buffer to the network
/// is Phase 5d's job (see HANDOVER.md). This controller's only
/// responsibility is: sample -> build packet -> buffer, reliably, for as
/// long as the device is offline or the upload path hasn't been built yet.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:sodium/sodium.dart';
import 'package:state_notifier/state_notifier.dart';

import '../storage/secure_storage_manager.dart';
import '../storage/stored_models.dart';
import '../storage/telemetry_buffer_store.dart';
import 'battery_info_provider.dart';
import 'location_sample.dart';
import 'location_sampling_policy.dart';
import 'location_source.dart';
import 'telemetry_packet_builder.dart';
import 'tracking_state.dart';

class LocationTrackingController extends StateNotifier<TrackingState> {
  final LocationSource _location;
  final BatteryInfoProvider _battery;
  final LocationSamplingPolicy _policy;
  final TelemetryPacketBuilder _packetBuilder;
  final TelemetryBufferStore _buffer;
  final SecureStorageManager _storage;
  final Sodium _sodium;

  StreamSubscription<LocationSample>? _subscription;
  SamplingTierName? _currentTier;
  int _sampleCount = 0;

  /// Retained purely so a re-subscribe (tier change) doesn't blank the HUD's
  /// last known position -- the packet pipeline itself never reads this.
  LocationSample? _lastSample;

  LocationTrackingController({
    required LocationSource location,
    required BatteryInfoProvider battery,
    required LocationSamplingPolicy policy,
    required TelemetryPacketBuilder packetBuilder,
    required TelemetryBufferStore buffer,
    required SecureStorageManager storage,
    required Sodium sodium,
  }) : _location = location,
       _battery = battery,
       _policy = policy,
       _packetBuilder = packetBuilder,
       _buffer = buffer,
       _storage = storage,
       _sodium = sodium,
       super(const TrackingIdle());

  Future<void> start() async {
    if (state is TrackingActive || state is TrackingStarting) return;
    state = const TrackingStarting();

    final permission = await _location.ensurePermission();
    if (permission != LocationPermissionResult.granted) {
      state = TrackingError(
        message: 'Location permission not granted (${permission.name}).',
        previous: const TrackingIdle(),
      );
      return;
    }

    final identity = await _storage.loadDeviceIdentity();
    final session = await _storage.loadSession();
    if (identity?.deviceId == null || identity?.wireId == null) {
      state = TrackingError(
        message: 'This device is not registered yet.',
        previous: const TrackingIdle(),
      );
      return;
    }
    if (session == null) {
      state = TrackingError(
        message: 'No active sector session to attach telemetry to.',
        previous: const TrackingIdle(),
      );
      return;
    }

    _sampleCount = 0;
    await _subscribeAtCurrentTier(identity: identity!, session: session);
  }

  /// Synchronous, deliberately: the UI needs "stopped" to be reflected in
  /// [state] immediately, and nothing downstream needs to wait for the old
  /// subscription's teardown to actually finish -- once [_subscription] is
  /// no longer referenced here, no future event from it can reach
  /// [_handleSample] regardless of how long the underlying `cancel()` takes
  /// to settle. Not awaiting it also means a slow/stalled `cancel()` can
  /// never block `stop()` from completing.
  void stop() {
    _subscription?.cancel();
    _subscription = null;
    _currentTier = null;
    state = const TrackingIdle();
  }

  Future<void> _subscribeAtCurrentTier({
    required StoredDeviceIdentity identity,
    required StoredSession session,
  }) async {
    final battery = await _battery.currentStatus();
    final tier = _policy.resolve(
      batteryPct: battery.levelPct,
      isCharging: battery.isCharging,
    );
    _currentTier = tier.name;

    await _subscription?.cancel();
    _subscription = _location.watch(tier).listen(
      (sample) => _handleSample(
        sample,
        identity: identity,
        session: session,
        batteryPct: battery.levelPct,
      ),
      onError: (Object error) {
        state = TrackingError(message: '$error', previous: state);
      },
    );

    state = TrackingActive(
      tier: tier.name,
      sampleCount: _sampleCount,
      bufferedCount: await _buffer.count(),
      lastSample: _lastSample,
      batteryPct: battery.levelPct,
    );
  }

  Future<void> _handleSample(
    LocationSample sample, {
    required StoredDeviceIdentity identity,
    required StoredSession session,
    required int batteryPct,
  }) async {
    await _bufferSample(
      sample,
      identity: identity,
      session: session,
      batteryPct: batteryPct,
    );
    _sampleCount++;
    _lastSample = sample;

    // Re-check the tier after every sample rather than on a separate timer:
    // this keeps the controller driven entirely by the position stream
    // (and, in tests, by a fake stream) with no wall-clock dependency.
    final freshBattery = await _battery.currentStatus();
    final freshTier = _policy.resolve(
      batteryPct: freshBattery.levelPct,
      isCharging: freshBattery.isCharging,
    );
    if (freshTier.name != _currentTier) {
      await _subscribeAtCurrentTier(identity: identity, session: session);
      return;
    }

    state = TrackingActive(
      tier: freshTier.name,
      sampleCount: _sampleCount,
      bufferedCount: await _buffer.count(),
      lastSample: sample,
      batteryPct: freshBattery.levelPct,
    );
  }

  Future<void> _bufferSample(
    LocationSample sample, {
    required StoredDeviceIdentity identity,
    required StoredSession session,
    required int batteryPct,
  }) async {
    final deviceSecretKey = _sodium.secureCopy(
      base64Decode(identity.secretKeyBase64),
    );
    final sectorKey = _sodium.secureCopy(
      base64Decode(session.sectorKeyBase64),
    );
    try {
      final Uint8List blob = _packetBuilder.build(
        wireId: identity.wireId!,
        deviceSecretKey: deviceSecretKey,
        sectorKey: sectorKey,
        sample: sample,
        batteryPct: batteryPct,
      );
      await _buffer.enqueue(blob);
    } finally {
      deviceSecretKey.dispose();
      sectorKey.dispose();
    }
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }
}
