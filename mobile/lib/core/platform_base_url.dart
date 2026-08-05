/// Picks the right default backend URL for the current platform.
///
/// Android talks to the host over `127.0.0.1` plus an ADB reverse tunnel:
///
/// ```
/// adb reverse tcp:8000 tcp:8000
/// ```
///
/// This deliberately does NOT use `10.0.2.2`, which is the Android
/// EMULATOR's loopback alias for the host and resolves to nothing on a real
/// handset -- the failure mode is a request that just hangs until the
/// client's 15s timeout, with nothing ever reaching the backend to log.
/// `adb reverse` works on BOTH an emulator and a physical device, so one
/// default now covers every Android target; the cost is that the tunnel has
/// to be established once per device connection (it does not survive
/// unplugging the cable).
///
/// A LAN IP (`http://192.168.x.x:8000`) is the alternative when USB isn't
/// available -- pass it via `--dart-define=API_BASE_URL=...` rather than
/// changing this default, since it depends on the host's current DHCP lease
/// and on the firewall allowing inbound connections.
///
/// Extracted as a pure function, separate from `main.dart`'s
/// platform-detection glue, so this exact branch is directly unit-testable
/// without needing to actually run on each platform.
library;

/// Host-side port the backend listens on, and the port the ADB reverse
/// tunnel must forward.
const int backendPort = 8000;

String computeDefaultBaseUrl({
  required bool isAndroid,
  String environmentOverride = '',
}) {
  if (environmentOverride.isNotEmpty) return environmentOverride;
  if (isAndroid) return 'http://127.0.0.1:$backendPort';
  return 'http://localhost:$backendPort';
}
