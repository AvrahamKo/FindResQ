import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/sos/sos_state.dart';

/// The searcher's own SOS trigger/cancel screen. Both actions require an
/// explicit confirmation dialog first -- a life-safety signal is exactly
/// the kind of action a stray tap must not fire, and exactly the kind of
/// action a searcher who genuinely needs it should be able to send in two
/// taps, not buried behind a multi-step flow.
class SosButtonView extends ConsumerWidget {
  const SosButtonView({super.key});

  Future<void> _confirmAndTrigger(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Send SOS?'),
        content: const Text(
          'This alerts your Sector Lead and Commander immediately.',
        ),
        actions: [
          TextButton(
            key: const Key('sos_confirm_cancel'),
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('sos_confirm_send'),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Send SOS'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await ref.read(sosControllerProvider.notifier).trigger();
    }
  }

  Future<void> _confirmAndCancel(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Cancel SOS?'),
        content: const Text('Only do this if you are safe -- false alarm.'),
        actions: [
          TextButton(
            key: const Key('sos_cancel_confirm_no'),
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep active'),
          ),
          FilledButton(
            key: const Key('sos_cancel_confirm_yes'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text("I'm safe, cancel"),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await ref.read(sosControllerProvider.notifier).cancel();
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(sosControllerProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('SOS')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: switch (state) {
            SosIdle() => FilledButton(
              key: const Key('sos_trigger_button'),
              style: FilledButton.styleFrom(
                backgroundColor: Colors.red,
                minimumSize: const Size(160, 160),
                shape: const CircleBorder(),
              ),
              onPressed: () => _confirmAndTrigger(context, ref),
              child: const Text('SOS', style: TextStyle(fontSize: 28)),
            ),
            SosTriggering() => const CircularProgressIndicator(),
            SosActive(:final alert) => Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.warning_amber, color: Colors.red, size: 56),
                const SizedBox(height: 12),
                const Text(
                  'SOS ACTIVE',
                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Colors.red),
                ),
                const SizedBox(height: 8),
                Text(
                  alert.status == 'acknowledged'
                      ? 'Your Sector Lead has acknowledged this.'
                      : 'Waiting for your Sector Lead to respond.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                OutlinedButton(
                  key: const Key('sos_cancel_button'),
                  onPressed: () => _confirmAndCancel(context, ref),
                  child: const Text("I'm safe -- cancel SOS"),
                ),
              ],
            ),
            SosCancelling() => const CircularProgressIndicator(),
            SosError(:final message) => Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.error_outline, color: Colors.red, size: 40),
                const SizedBox(height: 8),
                Text(message, textAlign: TextAlign.center),
                const SizedBox(height: 16),
                FilledButton(
                  key: const Key('sos_error_dismiss'),
                  onPressed: () => ref.read(sosControllerProvider.notifier).reset(),
                  child: const Text('OK'),
                ),
              ],
            ),
          },
        ),
      ),
    );
  }
}
