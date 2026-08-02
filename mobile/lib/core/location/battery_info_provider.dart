/// Battery level/charging-state lookup, abstracted away from the `battery_plus`
/// plugin -- same reasoning as [LocationSource] and [KeyValueStore]: the real
/// implementation talks to a platform channel that doesn't exist in a bare
/// `flutter test` host process, so [LocationSamplingPolicy]-driven code
/// depends on this interface and tests supply a fake.
library;

import 'package:battery_plus/battery_plus.dart';

class BatteryStatus {
  final int levelPct;
  final bool isCharging;

  const BatteryStatus({required this.levelPct, required this.isCharging});
}

abstract class BatteryInfoProvider {
  Future<BatteryStatus> currentStatus();
}

class BatteryPlusInfoProvider implements BatteryInfoProvider {
  final Battery _battery;

  BatteryPlusInfoProvider({Battery? battery}) : _battery = battery ?? Battery();

  @override
  Future<BatteryStatus> currentStatus() async {
    final level = await _battery.batteryLevel;
    final state = await _battery.batteryState;
    final isCharging =
        state == BatteryState.charging || state == BatteryState.full;
    return BatteryStatus(levelPct: level, isCharging: isCharging);
  }
}
