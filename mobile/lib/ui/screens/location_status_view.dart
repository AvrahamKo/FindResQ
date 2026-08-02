import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/location/tracking_state.dart';
import '../../core/providers.dart';
import '../../core/sync/sync_state.dart';

/// Debug/ops view over [LocationTrackingController] and
/// [IngestSyncController] -- one Start/Stop pair drives both, since to a
/// searcher "start tracking" means "start trying to get my position to the
/// server," not two separate concerns. Reached from `SessionActiveView`;
/// not the searcher-facing dashboard (that's a later phase), just enough
/// surface to exercise and verify Phase 5c/5d's tracking -> buffer -> sync
/// pipeline.
class LocationStatusView extends ConsumerWidget {
  const LocationStatusView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final trackingState = ref.watch(locationTrackingControllerProvider);
    final trackingNotifier = ref.read(
      locationTrackingControllerProvider.notifier,
    );
    final syncState = ref.watch(ingestSyncControllerProvider);
    final syncNotifier = ref.read(ingestSyncControllerProvider.notifier);

    Future<void> startBoth() async {
      await trackingNotifier.start();
      // Only start the sync loop if tracking actually came up -- a denied
      // permission or a missing session means there is nothing new to
      // upload, and starting sync anyway would leave it running with
      // nothing to do (or, worse, uploading a stale buffer with no fresh
      // context behind it).
      if (ref.read(locationTrackingControllerProvider) is TrackingActive) {
        await syncNotifier.start();
      }
    }

    void stopBoth() {
      trackingNotifier.stop();
      syncNotifier.stop();
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Location tracking')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _StatusBody(state: trackingState),
              const SizedBox(height: 16),
              _SyncStatusBody(state: syncState),
              const SizedBox(height: 24),
              switch (trackingState) {
                TrackingActive() => FilledButton(
                  onPressed: stopBoth,
                  child: const Text('Stop tracking'),
                ),
                TrackingStarting() => const CircularProgressIndicator(),
                _ => FilledButton(
                  onPressed: startBoth,
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

class _SyncStatusBody extends StatelessWidget {
  final SyncState state;
  const _SyncStatusBody({required this.state});

  @override
  Widget build(BuildContext context) {
    return switch (state) {
      SyncIdle() => const Text('Sync is off.'),
      SyncActive(
        :final pendingCount,
        :final totalUploaded,
        :final totalRejected,
        :final consecutiveFailures,
        :final isUploading,
        :final lastError,
      ) =>
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              isUploading ? Icons.cloud_upload : Icons.cloud_done,
              color: consecutiveFailures > 0 ? Colors.orange : Colors.blue,
              size: 32,
            ),
            const SizedBox(height: 4),
            Text('$pendingCount packets pending upload'),
            Text('$totalUploaded uploaded, $totalRejected rejected'),
            if (consecutiveFailures > 0)
              Text(
                'Retrying ($consecutiveFailures failed attempt${consecutiveFailures == 1 ? '' : 's'})'
                '${lastError != null ? ': $lastError' : ''}',
                style: const TextStyle(color: Colors.orange),
                textAlign: TextAlign.center,
              ),
          ],
        ),
      SyncError(:final message) => Text(
        'Sync error: $message',
        style: const TextStyle(color: Colors.red),
        textAlign: TextAlign.center,
      ),
    };
  }
}
