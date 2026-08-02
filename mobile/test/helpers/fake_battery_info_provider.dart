import 'package:lifesearch_mobile/core/location/battery_info_provider.dart';

/// A [BatteryInfoProvider] whose reading tests can change between calls, to
/// drive [LocationTrackingController]'s tier-resubscription logic.
class FakeBatteryInfoProvider implements BatteryInfoProvider {
  BatteryStatus status;

  FakeBatteryInfoProvider(this.status);

  @override
  Future<BatteryStatus> currentStatus() async => status;
}
