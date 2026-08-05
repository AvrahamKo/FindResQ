import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'core/platform_base_url.dart';
import 'core/providers.dart';

/// Android (emulator or physical, over USB) reaches the host through an ADB
/// reverse tunnel -- run `adb reverse tcp:8000 tcp:8000` once per device
/// connection; it does not survive unplugging.
///
/// For a device on Wi-Fi with no cable, or an iOS device, pass the host's
/// LAN IP explicitly -- it cannot be auto-detected here:
/// `--dart-define=API_BASE_URL=http://<host-lan-ip>:8000`.
String _defaultBaseUrl() {
  return computeDefaultBaseUrl(
    isAndroid: !kIsWeb && Platform.isAndroid,
    environmentOverride: const String.fromEnvironment('API_BASE_URL'),
  );
}

void main() {
  runApp(
    ProviderScope(
      overrides: [baseUrlProvider.overrideWithValue(_defaultBaseUrl())],
      child: const LifeSearchApp(),
    ),
  );
}
