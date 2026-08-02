/// A single raw GPS reading, decoupled from any particular location plugin.
///
/// [LocationSource] implementations translate a platform `Position` (or a
/// test fixture) into this type -- everything downstream (packet
/// construction, buffering) depends only on this, never on `geolocator`
/// directly.
library;

class LocationSample {
  final double latitude;
  final double longitude;
  final double accuracyM;
  final double speedMps;

  /// Device clock, unix epoch milliseconds -- goes straight into the wire
  /// payload's `recordedAtMs` field.
  final int recordedAtMs;

  /// True when the platform reports this position as coming from a mock
  /// location provider (developer options / a GPS spoofing app). Carried
  /// through to the wire format's `flags` bit rather than discarded, so the
  /// backend's plausibility stage can see and weigh it.
  final bool isMocked;

  const LocationSample({
    required this.latitude,
    required this.longitude,
    required this.accuracyM,
    required this.speedMps,
    required this.recordedAtMs,
    required this.isMocked,
  });
}
