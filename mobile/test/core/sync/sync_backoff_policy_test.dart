import 'package:flutter_test/flutter_test.dart';
import 'package:lifesearch_mobile/core/sync/sync_backoff_policy.dart';

void main() {
  const policy = SyncBackoffPolicy(
    initialBackoff: Duration(seconds: 5),
    maxBackoff: Duration(minutes: 5),
  );

  test('zero or negative failures means no backoff', () {
    expect(policy.delayFor(0), equals(Duration.zero));
    expect(policy.delayFor(-1), equals(Duration.zero));
  });

  test('the first failure waits exactly the initial backoff', () {
    expect(policy.delayFor(1), equals(const Duration(seconds: 5)));
  });

  test('each subsequent failure doubles the previous delay', () {
    expect(policy.delayFor(2), equals(const Duration(seconds: 10)));
    expect(policy.delayFor(3), equals(const Duration(seconds: 20)));
    expect(policy.delayFor(4), equals(const Duration(seconds: 40)));
    expect(policy.delayFor(5), equals(const Duration(seconds: 80)));
  });

  test('growth is capped at maxBackoff', () {
    // 5s * 2^9 = 2560s, well past the 300s cap.
    expect(policy.delayFor(10), equals(const Duration(minutes: 5)));
    expect(policy.delayFor(100), equals(const Duration(minutes: 5)));
  });

  test('never exceeds maxBackoff for any failure count', () {
    for (var attempt = 1; attempt <= 200; attempt++) {
      expect(
        policy.delayFor(attempt).inMilliseconds,
        lessThanOrEqualTo(policy.maxBackoff.inMilliseconds),
      );
    }
  });

  test('delay is monotonically non-decreasing as failures accumulate', () {
    Duration previous = Duration.zero;
    for (var attempt = 1; attempt <= 20; attempt++) {
      final current = policy.delayFor(attempt);
      expect(current.inMilliseconds, greaterThanOrEqualTo(previous.inMilliseconds));
      previous = current;
    }
  });

  test('a custom policy honors its own initial/max values', () {
    const custom = SyncBackoffPolicy(
      initialBackoff: Duration(milliseconds: 10),
      maxBackoff: Duration(milliseconds: 40),
    );
    expect(custom.delayFor(1), equals(const Duration(milliseconds: 10)));
    expect(custom.delayFor(2), equals(const Duration(milliseconds: 20)));
    expect(custom.delayFor(3), equals(const Duration(milliseconds: 40)));
    expect(custom.delayFor(4), equals(const Duration(milliseconds: 40)));
  });
}
