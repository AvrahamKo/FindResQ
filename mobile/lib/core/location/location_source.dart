/// GPS position source, abstracted away from `geolocator` -- same reasoning
/// as [KeyValueStore]/[BatteryInfoProvider]: the real implementation talks
/// to a platform channel that doesn't exist in a bare `flutter test` host
/// process, so [LocationTrackingController] depends on this interface and
/// tests supply a fake stream.
library;

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

import 'location_sample.dart';
import 'location_sampling_policy.dart';

enum LocationPermissionResult { granted, denied, deniedForever, serviceDisabled }

abstract class LocationSource {
  /// Ensures permission is granted, requesting it if merely undecided.
  /// Never silently retries past a `deniedForever` result -- that requires
  /// the user to go into app settings, which is the caller's job to surface.
  Future<LocationPermissionResult> ensurePermission();

  /// A stream of samples honoring [tier]'s distance filter and accuracy
  /// hint. Each call starts a fresh platform subscription; callers are
  /// responsible for cancelling the previous one before starting a new tier
  /// (see `LocationTrackingController._subscribeAtCurrentTier`).
  Stream<LocationSample> watch(SamplingTier tier);

  /// A single fresh fix, for callers that need "where am I right now" once
  /// rather than a continuous stream -- e.g. filing a field report (see
  /// `ReportController`). Not part of the continuous tracking pipeline.
  Future<LocationSample> getCurrentPosition();
}

LocationAccuracy _toGeolocatorAccuracy(AccuracyHint hint) => switch (hint) {
  AccuracyHint.best => LocationAccuracy.best,
  AccuracyHint.high => LocationAccuracy.high,
  AccuracyHint.medium => LocationAccuracy.medium,
  AccuracyHint.low => LocationAccuracy.low,
};

class GeolocatorLocationSource implements LocationSource {
  @override
  Future<LocationPermissionResult> ensurePermission() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      return LocationPermissionResult.serviceDisabled;
    }

    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }

    return switch (permission) {
      LocationPermission.denied => LocationPermissionResult.denied,
      LocationPermission.deniedForever =>
        LocationPermissionResult.deniedForever,
      LocationPermission.whileInUse ||
      LocationPermission.always => LocationPermissionResult.granted,
      LocationPermission.unableToDetermine =>
        LocationPermissionResult.denied,
    };
  }

  @override
  Stream<LocationSample> watch(SamplingTier tier) {
    final accuracy = _toGeolocatorAccuracy(tier.accuracyHint);
    final distanceFilter = tier.distanceFilterM.round();
    final LocationSettings settings =
        !kIsWeb && defaultTargetPlatform == TargetPlatform.android
        ? AndroidSettings(
            accuracy: accuracy,
            distanceFilter: distanceFilter,
            foregroundNotificationConfig:
                const ForegroundNotificationConfig(
                  notificationTitle: 'FindResQ tracking active',
                  notificationText:
                      'Your location is being recorded for the active search.',
                  notificationChannelName: 'Active search tracking',
                  enableWakeLock: true,
                  setOngoing: true,
                ),
          )
        : LocationSettings(
            accuracy: accuracy,
            distanceFilter: distanceFilter,
          );
    return Geolocator.getPositionStream(locationSettings: settings).map(
      (position) => LocationSample(
        latitude: position.latitude,
        longitude: position.longitude,
        accuracyM: position.accuracy,
        speedMps: position.speed,
        recordedAtMs: position.timestamp.millisecondsSinceEpoch,
        isMocked: position.isMocked,
      ),
    );
  }

  @override
  Future<LocationSample> getCurrentPosition() async {
    final position = await Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
    );
    return LocationSample(
      latitude: position.latitude,
      longitude: position.longitude,
      accuracyM: position.accuracy,
      speedMps: position.speed,
      recordedAtMs: position.timestamp.millisecondsSinceEpoch,
      isMocked: position.isMocked,
    );
  }
}
