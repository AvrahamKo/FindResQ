import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'core/platform_base_url.dart';
import 'core/providers.dart';

/// A real device (Android or iOS) needs the host machine's actual LAN IP,
/// which cannot be auto-detected here -- that case must go through
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
