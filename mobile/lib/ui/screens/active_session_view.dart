import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/location/tracking_state.dart';
import '../../core/providers.dart';
import '../../core/sos/sos_state.dart';
import '../../core/sync/sync_state.dart';
import '../widgets/hold_to_activate_sos_button.dart';
import '../widgets/quick_report_sheet.dart';
import '../widgets/sector_map_view.dart';
import '../widgets/tactical_status_bar.dart';
import 'location_status_view.dart';
import 'report_form_view.dart';
import 'reports_list_view.dart';
import 'sos_alerts_view.dart';
import 'sos_button_view.dart';

/// The volunteer's primary in-field screen.
///
/// Layout priority is by urgency, not by feature parity: the map fills the
/// screen (situational awareness is the constant need), the SOS control owns
/// the bottom-centre thumb zone (the rarest action, but the one that must
/// never be hunted for), and everything else is a small control or lives
/// behind the overflow menu. The old version -- a column of six identical
/// outlined buttons -- gave a distress signal exactly the same visual weight
/// as "Sector reports", which is the wrong priority for a life-safety tool.
class SessionActiveView extends ConsumerStatefulWidget {
  final String sectorName;

  const SessionActiveView({super.key, required this.sectorName});

  @override
  ConsumerState<SessionActiveView> createState() => _SessionActiveViewState();
}

class _SessionActiveViewState extends ConsumerState<SessionActiveView> {
  SearchCoverageLayer _coverageLayer = SearchCoverageLayer.team;

  @override
  void initState() {
    super.initState();
    Future.microtask(
      () => ref.read(personalTrailControllerProvider.notifier).ensureLoaded(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tracking = ref.watch(locationTrackingControllerProvider);
    final sync = ref.watch(ingestSyncControllerProvider);
    final coverage = ref.watch(coverageControllerProvider);
    final personalTrail = ref.watch(personalTrailControllerProvider);
    final sos = ref.watch(sosControllerProvider);
    final sector = ref.watch(activeSectorProvider);
    final batteryAsync = ref.watch(batteryStatusProvider);

    final active = tracking is TrackingActive ? tracking : null;
    final sample = active?.lastSample;
    final batteryPct = active?.batteryPct ?? batteryAsync.value?.levelPct;
    final boundary = sector.value?.boundary ?? const [];

    return Scaffold(
      backgroundColor: const Color(0xFF0D1117),
      body: Column(
        children: [
          TacticalStatusBar(
            sectorName: widget.sectorName,
            gps: _gpsChip(tracking),
            battery: _batteryChip(batteryPct),
            uplink: _uplinkChip(sync),
          ),
          _LastSyncLabel(
            lastSyncAt: _latestSyncAt(sync, coverage.lastServerSyncAt),
          ),
          Expanded(
            child: Stack(
              children: [
                Positioned.fill(
                  child: SectorMapView(
                    boundary: boundary,
                    latitude: sample?.latitude,
                    longitude: sample?.longitude,
                    accuracyM: sample?.accuracyM,
                    showBasemap: ref.watch(mapTilesEnabledProvider),
                    teamCoverage: coverage.teamCells,
                    personalTrail: personalTrail,
                    coverageLayer: _coverageLayer,
                  ),
                ),
                Positioned(
                  left: 12,
                  top: 12,
                  child: _CoverageToggle(
                    value: _coverageLayer,
                    onChanged: (value) => setState(() {
                      _coverageLayer = value;
                    }),
                  ),
                ),
                if (boundary.isEmpty)
                  const Positioned(
                    left: 12,
                    right: 12,
                    top: 58,
                    child: _MapNotice(
                      'Sector outline unavailable offline — your position is still tracked.',
                    ),
                  ),
                Positioned(
                  right: 12,
                  top: 12,
                  child: _MapActions(trackingActive: active != null),
                ),
              ],
            ),
          ),
          _ActionBar(sos: sos),
        ],
      ),
    );
  }

  DateTime? _latestSyncAt(SyncState sync, DateTime? coverageSyncAt) {
    final ingestSyncAt = sync is SyncActive ? sync.lastSyncAt : null;
    if (ingestSyncAt == null) return coverageSyncAt;
    if (coverageSyncAt == null) return ingestSyncAt;
    return ingestSyncAt.isAfter(coverageSyncAt) ? ingestSyncAt : coverageSyncAt;
  }

  StatusChipData _gpsChip(TrackingState tracking) => switch (tracking) {
    TrackingActive(:final lastSample) when lastSample != null => StatusChipData(
      icon: Icons.gps_fixed,
      label: '±${lastSample.accuracyM.round()}m',
      // Anything coarser than ~50m can't distinguish adjacent search hexes
      // (H3 res 12 is ~9m edge), so it is worth flagging, not just showing.
      level: lastSample.accuracyM <= 50 ? StatusLevel.good : StatusLevel.warn,
    ),
    TrackingActive() => const StatusChipData(
      icon: Icons.gps_not_fixed,
      label: 'NO FIX',
      level: StatusLevel.warn,
    ),
    TrackingError() => const StatusChipData(
      icon: Icons.gps_off,
      label: 'GPS ERROR',
      level: StatusLevel.bad,
    ),
    TrackingStarting() => const StatusChipData(
      icon: Icons.gps_not_fixed,
      label: 'ACQUIRING',
      level: StatusLevel.unknown,
    ),
    TrackingIdle() => const StatusChipData(
      icon: Icons.gps_off,
      label: 'GPS OFF',
      level: StatusLevel.bad,
    ),
  };

  StatusChipData _batteryChip(int? pct) {
    if (pct == null) {
      return const StatusChipData(
        icon: Icons.battery_unknown,
        label: '--',
        level: StatusLevel.unknown,
      );
    }
    // Thresholds mirror LocationSamplingPolicy's tiers and the backend's
    // join-time battery gates, so the bar warns at the same points the
    // system actually changes behaviour.
    final level = pct >= 30
        ? StatusLevel.good
        : pct >= 15
        ? StatusLevel.warn
        : StatusLevel.bad;
    return StatusChipData(
      icon: pct >= 30 ? Icons.battery_full : Icons.battery_alert,
      label: '$pct%',
      level: level,
    );
  }

  StatusChipData _uplinkChip(SyncState sync) => switch (sync) {
    SyncActive(:final consecutiveFailures, :final pendingCount)
        when consecutiveFailures > 0 =>
      StatusChipData(
        icon: Icons.cloud_off,
        // The buffered count is the honest thing to show while offline: it
        // is what will be delivered once signal returns.
        label: 'OFFLINE $pendingCount',
        level: StatusLevel.bad,
      ),
    SyncActive(:final pendingCount) => StatusChipData(
      icon: Icons.cloud_done,
      label: pendingCount > 0 ? 'SYNC $pendingCount' : 'ONLINE',
      level: StatusLevel.good,
    ),
    SyncError() => const StatusChipData(
      icon: Icons.cloud_off,
      label: 'NO UPLINK',
      level: StatusLevel.bad,
    ),
    SyncIdle() => const StatusChipData(
      icon: Icons.cloud_queue,
      label: 'IDLE',
      level: StatusLevel.unknown,
    ),
  };
}

class _LastSyncLabel extends StatelessWidget {
  final DateTime? lastSyncAt;

  const _LastSyncLabel({required this.lastSyncAt});

  @override
  Widget build(BuildContext context) {
    final local = lastSyncAt?.toLocal();
    final value = local == null
        ? 'Last sync: never'
        : 'Last sync: ${_two(local.hour)}:${_two(local.minute)}:${_two(local.second)}';
    return Container(
      key: const Key('last_server_sync'),
      width: double.infinity,
      color: const Color(0xFF161B22),
      padding: const EdgeInsets.fromLTRB(12, 2, 12, 4),
      child: Text(
        value,
        textAlign: TextAlign.end,
        style: const TextStyle(color: Color(0xFF8B949E), fontSize: 10),
      ),
    );
  }

  static String _two(int value) => value.toString().padLeft(2, '0');
}

class _CoverageToggle extends StatelessWidget {
  final SearchCoverageLayer value;
  final ValueChanged<SearchCoverageLayer> onChanged;

  const _CoverageToggle({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('coverage_layer_toggle'),
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: const Color(0xE6161B22),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: SearchCoverageLayer.values
            .map(
              (layer) => InkWell(
                key: Key('coverage_${layer.name}'),
                onTap: () => onChanged(layer),
                borderRadius: BorderRadius.circular(6),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: value == layer
                        ? const Color(0xFF3FA9F5)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    layer == SearchCoverageLayer.team ? 'Team' : 'Mine',
                    style: const TextStyle(color: Colors.white, fontSize: 11),
                  ),
                ),
              ),
            )
            .toList(growable: false),
      ),
    );
  }
}

class _MapNotice extends StatelessWidget {
  final String text;
  const _MapNotice(this.text);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xE6161B22),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        text,
        style: const TextStyle(color: Color(0xFFF1C40F), fontSize: 11),
      ),
    );
  }
}

/// Start/stop tracking plus the overflow for the screens that used to be
/// full-width buttons. Kept off the bottom bar so nothing competes with SOS
/// for the thumb zone.
class _MapActions extends ConsumerWidget {
  final bool trackingActive;
  const _MapActions({required this.trackingActive});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      children: [
        FloatingActionButton.small(
          key: const Key('tracking_toggle_button'),
          heroTag: 'tracking',
          backgroundColor: trackingActive
              ? const Color(0xFF2ECC71)
              : const Color(0xFF30363D),
          foregroundColor: Colors.white,
          tooltip: trackingActive ? 'Stop tracking' : 'Start tracking',
          onPressed: () async {
            final tracking = ref.read(
              locationTrackingControllerProvider.notifier,
            );
            final sync = ref.read(ingestSyncControllerProvider.notifier);
            if (trackingActive) {
              tracking.stop();
              sync.stop();
              return;
            }
            await tracking.start();
            // Only start uploading if tracking actually came up -- otherwise
            // the sync loop spins with nothing to send (see HANDOVER's note
            // on this exact bug in LocationStatusView).
            if (ref.read(locationTrackingControllerProvider)
                is TrackingActive) {
              await sync.start();
            }
          },
          child: Icon(trackingActive ? Icons.pause : Icons.play_arrow),
        ),
        const SizedBox(height: 8),
        _OverflowMenu(),
      ],
    );
  }
}

class _OverflowMenu extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFF30363D),
        shape: BoxShape.circle,
      ),
      child: PopupMenuButton<String>(
        key: const Key('session_overflow_menu'),
        icon: const Icon(Icons.more_horiz, color: Colors.white),
        onSelected: (value) {
          final routes = <String, Widget Function()>{
            'reports': () => const ReportsListView(),
            'sos_alerts': () => const SosAlertsView(),
            'diagnostics': () => const LocationStatusView(),
          };
          final builder = routes[value];
          if (builder == null) return;
          Navigator.of(
            context,
          ).push(MaterialPageRoute(builder: (_) => builder()));
        },
        itemBuilder: (context) => const [
          PopupMenuItem(value: 'reports', child: Text('Sector reports')),
          // Server-side RBAC is the real gate: a volunteer tapping this gets
          // a 403 from the backend rather than the client duplicating the
          // Lead/Commander check from a session field.
          PopupMenuItem(
            value: 'sos_alerts',
            child: Text('SOS alerts (Lead/Commander)'),
          ),
          PopupMenuItem(
            value: 'diagnostics',
            child: Text('Tracking diagnostics'),
          ),
        ],
      ),
    );
  }
}

/// Bottom action strip: quick-report on the left, the SOS control centred.
class _ActionBar extends ConsumerWidget {
  final SosState sos;
  const _ActionBar({required this.sos});

  Future<void> _openQuickReport(BuildContext context) async {
    final kind = await showQuickReportSheet(context);
    if (kind == null || !context.mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => ReportFormView(initialKind: kind)),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isOpenAlert = sos is SosActive;
    final isBusy = sos is SosTriggering || sos is SosCancelling;

    return Container(
      color: const Color(0xFF161B22),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 20),
      child: SafeArea(
        top: false,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Align(
                alignment: Alignment.centerLeft,
                child: _SquareAction(
                  buttonKey: const Key('quick_report_button'),
                  icon: Icons.add_alert,
                  label: 'Report',
                  onPressed: () => _openQuickReport(context),
                ),
              ),
            ),
            HoldToActivateSosButton(
              key: const Key('hold_sos_button'),
              enabled: !isOpenAlert && !isBusy,
              label: isOpenAlert ? 'SOS ACTIVE' : 'HOLD FOR SOS',
              onActivate: () =>
                  ref.read(sosControllerProvider.notifier).trigger(),
            ),
            Expanded(
              child: Align(
                alignment: Alignment.centerRight,
                child: isOpenAlert
                    ? _SquareAction(
                        buttonKey: const Key('sos_manage_button'),
                        icon: Icons.settings_backup_restore,
                        label: 'Manage',
                        onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => const SosButtonView(),
                          ),
                        ),
                      )
                    : const SizedBox.shrink(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SquareAction extends StatelessWidget {
  final Key buttonKey;
  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  const _SquareAction({
    required this.buttonKey,
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      key: buttonKey,
      onTap: onPressed,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        width: 64,
        height: 64,
        decoration: BoxDecoration(
          color: const Color(0xFF21262D),
          border: Border.all(color: const Color(0xFF30363D)),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: Colors.white, size: 22),
            const SizedBox(height: 4),
            Text(
              label,
              style: const TextStyle(color: Colors.white, fontSize: 10),
            ),
          ],
        ),
      ),
    );
  }
}
