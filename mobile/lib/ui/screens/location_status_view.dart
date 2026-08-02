import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/location/tracking_state.dart';
import '../../core/providers.dart';

/// Debug/ops view over [LocationTrackingController] -- start/stop tracking
/// and see the current sampling tier and how many encrypted packets are
/// sitting in the local buffer. Reached from [SessionActiveView]; not the
/// searcher-facing dashboard (that's a later phase), just enough surface to
/// exercise and verify Phase 5c's tracking + buffering pipeline.
class LocationStatusView extends ConsumerWidget {
  const LocationStatusView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(locationTrackingControllerProvider);
    final notifier = ref.read(locationTrackingControllerProvider.notifier);

    return Scaffold(
      appBar: AppBar(title: const Text('Location tracking')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _StatusBody(state: state),
              const SizedBox(height: 24),
              switch (state) {
                TrackingActive() => FilledButton(
                  onPressed: notifier.stop,
                  child: const Text('Stop tracking'),
                ),
                TrackingStarting() => const CircularProgressIndicator(),
                _ => FilledButton(
                  onPressed: notifier.start,
                  child: const Text('Start tracking'),
                ),
              },
            ],
          ),
        ),
      ),
    );
  }
}

class _StatusBody extends StatelessWidget {
  final TrackingState state;
  const _StatusBody({required this.state});

  @override
  Widget build(BuildContext context) {
    return switch (state) {
      TrackingIdle() => const Text('Tracking is off.'),
      TrackingStarting() => const Text('Starting tracking...'),
      TrackingActive(:final tier, :final sampleCount, :final bufferedCount) =>
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.gps_fixed, color: Colors.green, size: 40),
            const SizedBox(height: 8),
            Text('Tracking active (${tier.name} tier)'),
            Text('$sampleCount samples this session'),
            Text('$bufferedCount packets buffered locally'),
          ],
        ),
      TrackingError(:final message) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error_outline, color: Colors.red, size: 40),
          const SizedBox(height: 8),
          Text(message, textAlign: TextAlign.center),
        ],
      ),
    };
  }
}
