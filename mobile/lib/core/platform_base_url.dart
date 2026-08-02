/// Picks the right default backend URL for the current platform.
///
/// `10.0.2.2` is the Android EMULATOR's special loopback alias for the host
/// machine's localhost -- meaningless on any other target (Windows/Linux/
/// macOS desktop, web, iOS simulator, a real device). Getting this wrong
/// doesn't produce a clean error: the HTTP client just hangs trying to
/// connect to an address that resolves to nothing, with no error surfaced
/// and nothing ever reaching the backend to log. Extracted to a pure
/// function, separate from `main.dart`'s platform-detection glue, so this
/// exact branch is directly unit-testable without needing to actually run
/// on each platform.
library;

String computeDefaultBaseUrl({
  required bool isAndroid,
  String environmentOverride = '',
}) {
  if (environmentOverride.isNotEmpty) return environmentOverride;
  if (isAndroid) return 'http://10.0.2.2:8000';
  return 'http://localhost:8000';
}
