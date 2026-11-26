import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:lifesearch_mobile/core/api/api_models.dart';
import 'package:lifesearch_mobile/ui/widgets/sector_map_view.dart';

void main() {
  final cell = CoverageCell(
    hexId: '8c2db2b25155dff',
    cumulativePod: 0.64,
    distinctSearchers: 2,
    lastContributionAt: DateTime.utc(2030),
    boundary: const [
      GeoPoint(latitude: 31.70, longitude: 35.20),
      GeoPoint(latitude: 31.70, longitude: 35.22),
      GeoPoint(latitude: 31.72, longitude: 35.22),
      GeoPoint(latitude: 31.72, longitude: 35.20),
    ],
  );

  test('finds the coverage hex under a geographical map tap', () {
    expect(coverageCellAt([cell], const LatLng(31.71, 35.21)), same(cell));
    expect(coverageCellAt([cell], const LatLng(31.75, 35.25)), isNull);
  });

  test('uses the four legend bands at their exact boundaries', () {
    expect(coveragePodColor(0), coverageUnsearchedColor);
    expect(coveragePodColor(0.01), coverageLowColor);
    expect(coveragePodColor(0.39), coverageLowColor);
    expect(coveragePodColor(0.40), coveragePartialColor);
    expect(coveragePodColor(0.74), coveragePartialColor);
    expect(coveragePodColor(0.75), coverageGoodColor);
    expect(coveragePodColor(1), coverageGoodColor);
  });
}
