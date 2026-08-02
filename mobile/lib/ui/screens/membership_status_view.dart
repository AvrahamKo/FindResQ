import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';

const _pollInterval = Duration(seconds: 4);

/// Polls membership status while mounted. Relies on the PARENT switching to
/// a different widget entirely once the state leaves `JoinPending` (see
/// JoinScreen) so this widget's `dispose` -- and therefore the timer
/// cancellation -- runs exactly once, at the moment polling is no longer
/// needed.
class PendingApprovalView extends ConsumerStatefulWidget {
  final String sectorId;
  final String? batteryWarning;

  const PendingApprovalView({
    super.key,
    required this.sectorId,
    this.batteryWarning,
  });

  @override
  ConsumerState<PendingApprovalView> createState() =>
      _PendingApprovalViewState();
}

class _PendingApprovalViewState extends ConsumerState<PendingApprovalView> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(
      _pollInterval,
      (_) => ref.read(joinControllerProvider.notifier).pollOnce(),
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Waiting for approval')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(),
              const SizedBox(height: 16),
              const Text(
                'Waiting for your Sector Lead to approve you.',
                textAlign: TextAlign.center,
              ),
              if (widget.batteryWarning != null) ...[
                const SizedBox(height: 12),
                Text(
                  widget.batteryWarning!,
                  style: const TextStyle(color: Colors.orange),
                  textAlign: TextAlign.center,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class RejectedView extends ConsumerWidget {
  const RejectedView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(title: const Text('Request declined')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Your join request was not approved.'),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () => ref.read(joinControllerProvider.notifier).reset(),
                child: const Text('Try another code'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class RevokedView extends ConsumerWidget {
  const RevokedView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(title: const Text('Access ended')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Your access to this sector has ended, or the event is over.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () => ref.read(joinControllerProvider.notifier).reset(),
                child: const Text('Join another sector'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Reached the instant status flips to 'approved' -- claims the session
/// (and therefore the sector key) automatically, once.
class ClaimingSessionView extends ConsumerStatefulWidget {
  const ClaimingSessionView({super.key});

  @override
  ConsumerState<ClaimingSessionView> createState() =>
      _ClaimingSessionViewState();
}

class _ClaimingSessionViewState extends ConsumerState<ClaimingSessionView> {
  @override
  void initState() {
    super.initState();
    Future.microtask(
      () => ref.read(joinControllerProvider.notifier).claimSession(),
    );
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('Approved. Setting up your sector session...'),
          ],
        ),
      ),
    );
  }
}

class SessionActiveView extends StatelessWidget {
  final String sectorName;
  const SessionActiveView({super.key, required this.sectorName});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Active')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.check_circle, color: Colors.green, size: 48),
              const SizedBox(height: 16),
              Text(
                'You are active in $sectorName.',
                style: const TextStyle(fontSize: 18),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
