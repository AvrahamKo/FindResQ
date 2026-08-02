import 'package:flutter_test/flutter_test.dart';
import 'package:lifesearch_mobile/core/location/location_sampling_policy.dart';

void main() {
  const policy = LocationSamplingPolicy();

  group('off charge', () {
    test('battery >= 60% resolves to the high tier', () {
      final tier = policy.resolve(batteryPct: 60, isCharging: false);
      expect(tier.name, equals(SamplingTierName.high));
      expect(tier.distanceFilterM, equals(10));
    });

    test('battery at 100% still resolves to the high tier', () {
      final tier = policy.resolve(batteryPct: 100, isCharging: false);
      expect(tier.name, equals(SamplingTierName.high));
    });

    test('battery in [30, 60) resolves to balanced', () {
      expect(
        policy.resolve(batteryPct: 59, isCharging: false).name,
        equals(SamplingTierName.balanced),
      );
      expect(
        policy.resolve(batteryPct: 30, isCharging: false).name,
        equals(SamplingTierName.balanced),
      );
    });

    test('battery in [15, 30) resolves to saver', () {
      expect(
        policy.resolve(batteryPct: 29, isCharging: false).name,
        equals(SamplingTierName.saver),
      );
      expect(
        policy.resolve(batteryPct: 15, isCharging: false).name,
        equals(SamplingTierName.saver),
      );
    });

    test('battery below 15% resolves to critical', () {
      expect(
        policy.resolve(batteryPct: 14, isCharging: false).name,
        equals(SamplingTierName.critical),
      );
      expect(
        policy.resolve(batteryPct: 0, isCharging: false).name,
        equals(SamplingTierName.critical),
      );
    });

    test('distance filter widens as the tier drops, never narrows', () {
      final high = policy.resolve(batteryPct: 100, isCharging: false);
      final balanced = policy.resolve(batteryPct: 45, isCharging: false);
      final saver = policy.resolve(batteryPct: 20, isCharging: false);
      final critical = policy.resolve(batteryPct: 5, isCharging: false);

      expect(high.distanceFilterM, lessThan(balanced.distanceFilterM));
      expect(balanced.distanceFilterM, lessThan(saver.distanceFilterM));
      expect(saver.distanceFilterM, lessThan(critical.distanceFilterM));
    });
  });

  group('on charge', () {
    test('always resolves to the high tier regardless of battery level', () {
      expect(
        policy.resolve(batteryPct: 5, isCharging: true).name,
        equals(SamplingTierName.high),
      );
      expect(
        policy.resolve(batteryPct: 0, isCharging: true).name,
        equals(SamplingTierName.high),
      );
    });
  });
}
