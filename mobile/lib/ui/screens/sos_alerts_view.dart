import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/sos/sos_alerts_state.dart';

const _pollInterval = Duration(seconds: 5);

/// Lead/Commander view of a sector's SOS alerts. UI-driven polling, same
/// convention as `PendingApprovalView`'s `Timer.periodic` -- this is only
/// relevant while a Lead/Commander has the screen open, unlike
/// `LocationTrackingController`/`IngestSyncController`'s self-scheduling
/// background loops.
class SosAlertsView extends ConsumerStatefulWidget {
  const SosAlertsView({super.key});

  @override
  ConsumerState<SosAlertsView> createState() => _SosAlertsViewState();
}

class _SosAlertsViewState extends ConsumerState<SosAlertsView> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    Future.microtask(() => ref.read(sosAlertsControllerProvider.notifier).load());
    _timer = Timer.periodic(
      _pollInterval,
      (_) => ref.read(sosAlertsControllerProvider.notifier).load(),
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(sosAlertsControllerProvider);
    final notifier = ref.read(sosAlertsControllerProvider.notifier);

    return Scaffold(
      appBar: AppBar(title: const Text('Sector SOS alerts')),
      body: switch (state) {
        SosAlertsLoading() => const Center(child: CircularProgressIndicator()),
        SosAlertsFailed(:final message) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(message, textAlign: TextAlign.center),
          ),
        ),
        SosAlertsLoaded(:final alerts) when alerts.isEmpty => const Center(
          child: Text('No SOS alerts for this sector.'),
        ),
        SosAlertsLoaded(:final alerts) => ListView.builder(
          itemCount: alerts.length,
          itemBuilder: (context, index) {
            final alert = alerts[index];
            return ListTile(
              key: Key('sos_alert_${alert.id}'),
              leading: Icon(
                Icons.warning_amber,
                color: alert.isOpen ? Colors.red : Colors.grey,
              ),
              title: Text('SOS ${alert.status}'),
              subtitle: Text(
                alert.lat != null && alert.lng != null
                    ? '${alert.lat!.toStringAsFixed(5)}, ${alert.lng!.toStringAsFixed(5)}'
                    : 'no location',
              ),
              trailing: switch (alert.status) {
                'active' => FilledButton(
                  key: Key('sos_acknowledge_${alert.id}'),
                  onPressed: () => notifier.acknowledge(alert.id),
                  child: const Text('Acknowledge'),
                ),
                'acknowledged' => OutlinedButton(
                  key: Key('sos_resolve_${alert.id}'),
                  onPressed: () => notifier.resolve(alert.id),
                  child: const Text('Resolve'),
                ),
                _ => null,
              },
            );
          },
        ),
      },
    );
  }
}
