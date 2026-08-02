import 'dart:async';

import 'package:lifesearch_mobile/core/location/location_sample.dart';
import 'package:lifesearch_mobile/core/location/location_sampling_policy.dart';
import 'package:lifesearch_mobile/core/location/location_source.dart';

/// A [LocationSource] driven entirely by test code -- no platform channel,
/// no timers. Each call to [watch] records the requested [SamplingTier] so
/// tests can assert the controller picked the right one, and returns the
/// same broadcast stream regardless of tier so re-subscribing after a tier
/// change (cancel + watch again) just keeps delivering whatever the test
/// pushes via [emit].
class FakeLocationSource implements LocationSource {
  final StreamController<LocationSample> _controller =
      StreamController<LocationSample>.broadcast();

  LocationPermissionResult permissionResult = LocationPermissionResult.granted;
  final List<SamplingTier> tiersRequested = [];

  @override
  Future<LocationPermissionResult> ensurePermission() async =>
      permissionResult;

  @override
  Stream<LocationSample> watch(SamplingTier tier) {
    tiersRequested.add(tier);
    return _controller.stream;
  }

  void emit(LocationSample sample) => _controller.add(sample);

  void emitError(Object error) => _controller.addError(error);

  Future<void> close() => _controller.close();
}

LocationSample sampleAt({
  double latitude = 31.771959,
  double longitude = 35.217018,
  double accuracyM = 5.0,
  double speedMps = 1.2,
  int recordedAtMs = 1700000000000,
  bool isMocked = false,
}) => LocationSample(
  latitude: latitude,
  longitude: longitude,
  accuracyM: accuracyM,
  speedMps: speedMps,
  recordedAtMs: recordedAtMs,
  isMocked: isMocked,
);
