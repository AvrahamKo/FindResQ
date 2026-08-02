/// Sealed states for the join-code -> approval -> session-claim flow.
sealed class JoinState {
  const JoinState();
}

class JoinIdle extends JoinState {
  const JoinIdle();
}

class JoinSubmitting extends JoinState {
  const JoinSubmitting();
}

/// Waiting on the Sector Lead or Commander to approve -- the UI is
/// expected to poll (see JoinController.pollOnce) while in this state.
class JoinPending extends JoinState {
  final String membershipId;
  final String sectorId;

  /// Non-blocking battery warning from Q8's join-time enforcement (a hard
  /// block at <=15% is rejected before this state is ever reached; this is
  /// the softer <=30% warning, shown but not fatal).
  final String? batteryWarning;

  const JoinPending({
    required this.membershipId,
    required this.sectorId,
    this.batteryWarning,
  });
}

class JoinRejected extends JoinState {
  final String membershipId;
  const JoinRejected(this.membershipId);
}

class JoinRevoked extends JoinState {
  final String membershipId;
  const JoinRevoked(this.membershipId);
}

class JoinApproved extends JoinState {
  final String membershipId;
  final String sectorId;
  final String role;
  final String movementMode;

  const JoinApproved({
    required this.membershipId,
    required this.sectorId,
    required this.role,
    required this.movementMode,
  });
}

class JoinClaimingSession extends JoinState {
  final String membershipId;
  const JoinClaimingSession(this.membershipId);
}

/// Terminal success state: the session token and sector key are persisted
/// in Secure Storage. `sectorName` is surfaced for the confirmation screen.
class JoinSessionActive extends JoinState {
  final String sectorId;
  final String sectorName;
  const JoinSessionActive({required this.sectorId, required this.sectorName});
}

class JoinFailed extends JoinState {
  final String message;
  final JoinState previous;
  const JoinFailed({required this.message, required this.previous});
}
