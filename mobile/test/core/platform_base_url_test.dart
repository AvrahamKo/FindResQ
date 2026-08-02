// Regression test for the bug where the app defaulted to the Android
// emulator's `10.0.2.2` loopback alias on every platform, including native
// desktop builds -- where that address resolves to nothing, so the HTTP
// client just hangs with no error and nothing ever reaches the backend.

import 'package:flutter_test/flutter_test.dart';
import 'package:lifesearch_mobile/core/platform_base_url.dart';

void main() {
  test('non-Android platforms (desktop, web, iOS) default to localhost', () {
    expect(
      computeDefaultBaseUrl(isAndroid: false),
      equals('http://localhost:8000'),
    );
  });

  test('Android defaults to the emulator loopback alias', () {
    expect(
      computeDefaultBaseUrl(isAndroid: true),
      equals('http://10.0.2.2:8000'),
    );
  });

  test('an explicit environment override always wins, on any platform', () {
    expect(
      computeDefaultBaseUrl(
        isAndroid: true,
        environmentOverride: 'http://192.168.1.50:8000',
      ),
      equals('http://192.168.1.50:8000'),
    );
    expect(
      computeDefaultBaseUrl(
        isAndroid: false,
        environmentOverride: 'http://192.168.1.50:8000',
      ),
      equals('http://192.168.1.50:8000'),
    );
  });
}
