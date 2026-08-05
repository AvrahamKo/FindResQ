// Regression test for the bug where the app defaulted to the Android
// emulator's `10.0.2.2` loopback alias on every platform, including native
// desktop builds -- where that address resolves to nothing, so the HTTP
// client just hangs with no error and nothing ever reaches the backend.
//
// The same failure mode bit again on a PHYSICAL Android device, where
// `10.0.2.2` is equally meaningless: login sat on a spinner until the 15s
// client timeout. Android now defaults to `127.0.0.1` over an ADB reverse
// tunnel (`adb reverse tcp:8000 tcp:8000`), which works on both an emulator
// and a real handset.

import 'package:flutter_test/flutter_test.dart';
import 'package:lifesearch_mobile/core/platform_base_url.dart';

void main() {
  test('non-Android platforms (desktop, web, iOS) default to localhost', () {
    expect(
      computeDefaultBaseUrl(isAndroid: false),
      equals('http://localhost:8000'),
    );
  });

  test('Android defaults to loopback, for use with an ADB reverse tunnel', () {
    expect(
      computeDefaultBaseUrl(isAndroid: true),
      equals('http://127.0.0.1:8000'),
    );
  });

  test('Android never uses the emulator-only 10.0.2.2 alias', () {
    // Explicit negative assertion: that address silently resolves to nothing
    // on a physical device, so re-introducing it would reproduce a hang that
    // has now cost debugging time twice.
    expect(computeDefaultBaseUrl(isAndroid: true), isNot(contains('10.0.2.2')));
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
