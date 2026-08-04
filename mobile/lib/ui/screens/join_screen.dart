import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/join/join_state.dart';
import '../../core/providers.dart';
import 'active_session_view.dart';
import 'join_code_view.dart';
import 'membership_status_view.dart';

/// Renders whichever view matches the current [JoinState]. Each state maps
/// to a DIFFERENT widget type (not the same widget with different content),
/// so Flutter mounts/unmounts them on transition -- that's what gives
/// PendingApprovalView's polling timer a clean start/stop lifecycle.
class JoinScreen extends ConsumerWidget {
  const JoinScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(joinControllerProvider);

    return switch (state) {
      JoinIdle() => const JoinCodeView(isSubmitting: false),
      JoinSubmitting() => const JoinCodeView(isSubmitting: true),
      JoinFailed(previous: JoinIdle() || JoinSubmitting(), :final message) =>
        JoinCodeView(isSubmitting: false, errorMessage: message),
      JoinPending(:final sectorId, :final batteryWarning) =>
        PendingApprovalView(sectorId: sectorId, batteryWarning: batteryWarning),
      JoinFailed(previous: JoinPending(), :final message) => Scaffold(
          appBar: AppBar(title: const Text('Waiting for approval')),
          body: Center(child: Text(message)),
        ),
      JoinRejected() => const RejectedView(),
      JoinRevoked() => const RevokedView(),
      JoinApproved() || JoinClaimingSession() => const ClaimingSessionView(),
      JoinFailed(previous: JoinApproved() || JoinClaimingSession(), :final message) =>
        Scaffold(
          appBar: AppBar(title: const Text('Could not start session')),
          body: Center(child: Text(message)),
        ),
      JoinSessionActive(:final sectorName) =>
        SessionActiveView(sectorName: sectorName),
      JoinFailed(:final message) => Scaffold(body: Center(child: Text(message))),
    };
  }
}
