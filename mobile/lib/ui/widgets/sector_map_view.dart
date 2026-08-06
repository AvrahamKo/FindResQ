import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../../core/api/api_models.dart';
import '../../core/storage/search_map_store.dart';

enum SearchCoverageLayer { team, mine }

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
  final List<CoverageCell> teamCoverage;

  /// Every team member's scan path, this searcher's included. Drawn on the
  /// TEAM layer only, on top of the POD hexes: the hexes say how well ground
  /// has been swept, these say who actually walked where -- which is what
  /// makes the hexes actionable rather than just a heat map.
  final List<TeamTrack> teamTracks;

  final List<PersonalTrackPoint> personalTrail;
  final SearchCoverageLayer coverageLayer;

  const SectorMapView({
    super.key,
    required this.boundary,
    this.latitude,
    this.longitude,
    this.accuracyM,
    this.showBasemap = true,
    this.teamCoverage = const [],
    this.teamTracks = const [],
    this.personalTrail = const [],
    this.coverageLayer = SearchCoverageLayer.team,
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

  Color _podColor(double pod) {
    final value = pod.clamp(0.0, 1.0);
    return Color.lerp(const Color(0xFFE74C3C), const Color(0xFF2ECC71), value)!;
  }

  /// A stable colour per teammate, so the same person keeps the same line
  /// across polls and app restarts. Derived from the user id rather than
  /// from list position: positions shift as segments are added, and a track
  /// that changes colour mid-search reads as a different searcher.
  ///
  /// Deliberately excludes red (reserved for SOS and low-POD ground) and
  /// green (this device's own position marker).
  static const _trackPalette = <Color>[
    Color(0xFF3FA9F5), // blue
    Color(0xFFF1C40F), // amber
    Color(0xFF9B59B6), // violet
    Color(0xFF1ABC9C), // teal
    Color(0xFFE67E22), // orange
    Color(0xFFEC87C0), // pink
  ];

  Color _trackColor(String userId) =>
      _trackPalette[userId.hashCode.abs() % _trackPalette.length];

  /// Team paths: a wide translucent casing under a solid core, so lines stay
  /// legible where several searchers have crossed the same ground -- the
  /// exact place a single-stroke line turns into an unreadable tangle.
  List<Polyline> _teamTrackPolylines() {
    final polylines = <Polyline>[];
    for (final track in widget.teamTracks) {
      if (track.points.length < 2) continue;
      final points = track.points
          .map((p) => LatLng(p.latitude, p.longitude))
          .toList(growable: false);
      final color = _trackColor(track.userId);
      polylines.add(
        Polyline(
          points: points,
          strokeWidth: 7,
          color: color.withValues(alpha: 0.28),
        ),
      );
      polylines.add(
        Polyline(
          points: points,
          // A still-moving searcher gets the heavier, fully opaque line.
          // "Who is out there right now" is a different question from
          // "where has anyone been", and both are on this layer at once.
          strokeWidth: track.isLive ? 3.5 : 2,
          color: color.withValues(alpha: track.isLive ? 1.0 : 0.7),
        ),
      );
    }
    return polylines;
  }

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
        initialCenter:
            position ??
            (ring.isNotEmpty ? ring.first : const LatLng(31.5, 34.8)),
        initialZoom: 14,
        interactionOptions: const InteractionOptions(
          // Rotation off: a searcher comparing this to a paper map or a
          // compass bearing needs north to stay north, and a stray two-finger
          // twist while panning with gloves is easy to do and hard to undo.
          flags:
              InteractiveFlag.pinchZoom |
              InteractiveFlag.drag |
              InteractiveFlag.doubleTapZoom,
        ),
      ),
      children: [
        if (widget.showBasemap)
          TileLayer(
            urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
            userAgentPackageName: 'com.lifesearch.mobile',
          ),
        if (widget.coverageLayer == SearchCoverageLayer.team &&
            widget.teamCoverage.isNotEmpty)
          PolygonLayer(
            polygons: widget.teamCoverage
                .where((cell) => cell.boundary.length >= 3)
                .map(
                  (cell) => Polygon(
                    points: cell.boundary
                        .map((point) => LatLng(point.latitude, point.longitude))
                        .toList(growable: false),
                    borderColor: _podColor(cell.cumulativePod),
                    borderStrokeWidth: 1,
                    color: _podColor(
                      cell.cumulativePod,
                    ).withValues(alpha: 0.48),
                  ),
                )
                .toList(growable: false),
          ),
        // Team scan paths sit ABOVE the POD hexes and BELOW the sector
        // outline, so a teammate's line is never hidden by the shading it
        // produced, and the boundary stays the topmost reference.
        if (widget.coverageLayer == SearchCoverageLayer.team &&
            widget.teamTracks.isNotEmpty)
          PolylineLayer(polylines: _teamTrackPolylines()),
        if (widget.coverageLayer == SearchCoverageLayer.mine &&
            widget.personalTrail.length >= 2)
          PolylineLayer(
            polylines: [
              Polyline(
                points: widget.personalTrail
                    .map((p) => LatLng(p.latitude, p.longitude))
                    .toList(growable: false),
                strokeWidth: 10,
                color: const Color(0x553FA9F5),
              ),
              Polyline(
                points: widget.personalTrail
                    .map((p) => LatLng(p.latitude, p.longitude))
                    .toList(growable: false),
                strokeWidth: 3,
                color: const Color(0xFF3FA9F5),
              ),
            ],
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
