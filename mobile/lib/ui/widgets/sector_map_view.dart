import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../../core/api/api_models.dart';

/// Tactical map: the sector boundary plus the searcher's own position.
///
/// [showBasemap] is false in widget tests and is ALSO the honest offline
/// case -- `TileLayer` needs network per tile, and a searcher in a dead zone
/// (the condition this whole app is designed around) sees exactly this: the
/// polygon and their own dot on an empty background. The vector layers are
/// therefore the primary content, not a garnish on top of tiles.
class SectorMapView extends StatefulWidget {
  final List<GeoPoint> boundary;
  final double? latitude;
  final double? longitude;
  final double? accuracyM;
  final bool showBasemap;

  const SectorMapView({
    super.key,
    required this.boundary,
    this.latitude,
    this.longitude,
    this.accuracyM,
    this.showBasemap = true,
  });

  @override
  State<SectorMapView> createState() => _SectorMapViewState();
}

class _SectorMapViewState extends State<SectorMapView> {
  final MapController _controller = MapController();
  bool _hasFitted = false;

  List<LatLng> get _ring => widget.boundary
      .map((p) => LatLng(p.latitude, p.longitude))
      .toList(growable: false);

  LatLng? get _position => widget.latitude != null && widget.longitude != null
      ? LatLng(widget.latitude!, widget.longitude!)
      : null;

  /// Fits the sector ONCE, on the first frame that has a boundary. Re-fitting
  /// on every position update would fight the searcher every time they panned
  /// or zoomed the map to look at something.
  void _fitBoundaryOnce() {
    if (_hasFitted || _ring.length < 3) return;
    _hasFitted = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _controller.fitCamera(
        CameraFit.bounds(
          bounds: LatLngBounds.fromPoints(_ring),
          padding: const EdgeInsets.all(28),
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    _fitBoundaryOnce();
    final position = _position;
    final ring = _ring;

    return FlutterMap(
      mapController: _controller,
      options: MapOptions(
        initialCenter: position ?? (ring.isNotEmpty ? ring.first : const LatLng(31.5, 34.8)),
        initialZoom: 14,
        interactionOptions: const InteractionOptions(
          // Rotation off: a searcher comparing this to a paper map or a
          // compass bearing needs north to stay north, and a stray two-finger
          // twist while panning with gloves is easy to do and hard to undo.
          flags: InteractiveFlag.pinchZoom | InteractiveFlag.drag | InteractiveFlag.doubleTapZoom,
        ),
      ),
      children: [
        if (widget.showBasemap)
          TileLayer(
            urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
            userAgentPackageName: 'com.lifesearch.mobile',
          ),
        if (ring.length >= 3)
          PolygonLayer(
            polygons: [
              Polygon(
                points: ring,
                borderColor: const Color(0xFF3FA9F5),
                borderStrokeWidth: 2.5,
                color: const Color(0x223FA9F5),
              ),
            ],
          ),
        if (position != null && widget.accuracyM != null)
          CircleLayer(
            circles: [
              CircleMarker(
                point: position,
                radius: widget.accuracyM!,
                useRadiusInMeter: true,
                color: const Color(0x222ECC71),
                borderColor: const Color(0x662ECC71),
                borderStrokeWidth: 1,
              ),
            ],
          ),
        if (position != null)
          MarkerLayer(
            markers: [
              Marker(
                point: position,
                width: 26,
                height: 26,
                child: const DecoratedBox(
                  key: Key('map_self_marker'),
                  decoration: BoxDecoration(
                    color: Color(0xFF2ECC71),
                    shape: BoxShape.circle,
                    border: Border.fromBorderSide(
                      BorderSide(color: Colors.white, width: 3),
                    ),
                  ),
                ),
              ),
            ],
          ),
      ],
    );
  }
}
