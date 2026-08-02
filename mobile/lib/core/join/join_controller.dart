/// Orchestrates the join-code -> Lead/Commander approval -> session-claim
/// flow.
///
/// Approval happens on a DIFFERENT device (the Sector Lead's phone) -- there
/// is no synchronous response path back to the volunteer waiting here. So
/// this controller never tries to "wait" for approval in one call; it
/// exposes [pollOnce], which the UI drives on a timer, and each call is a
/// single, independent check of current status.
library;

import 'package:state_notifier/state_notifier.dart';

import '../api/api_client.dart';
import '../api/api_exception.dart';
import '../storage/secure_storage_manager.dart';
import '../storage/stored_models.dart';
import 'join_state.dart';

class JoinController extends StateNotifier<JoinState> {
  final ApiClient _api;
  final SecureStorageManager _storage;

  // See AuthController's constructor for why this is explicit assignment
  // rather than initializing formals.
  JoinController({required ApiClient api, required SecureStorageManager storage})
    : _api = api,
      _storage = storage,
      super(const JoinIdle());

  Future<void> submitJoinCode({
    required String code,
    required String movementMode,
    required int batteryPct,
    required bool powerbankAttested,
  }) async {
    state = const JoinSubmitting();

    final account = await _storage.loadAccount();
    final identity = await _storage.loadDeviceIdentity();
    if (account == null || identity?.deviceId == null) {
      state = const JoinFailed(
        message: 'Not signed in on a registered device.',
        previous: JoinIdle(),
      );
      return;
    }

    try {
      final result = await _api.joinSector(
        accountToken: account.accessToken,
        code: code,
        deviceId: identity!.deviceId!,
        movementMode: movementMode,
        batteryPct: batteryPct,
        powerbankAttested: powerbankAttested,
      );
      state = JoinPending(
        membershipId: result.membershipId,
        sectorId: result.sectorId,
        batteryWarning: result.batteryWarning,
      );
    } on ApiException catch (e) {
      state = JoinFailed(message: e.message, previous: const JoinIdle());
    }
  }

  /// A single status check. Safe to call repeatedly on a timer; each call
  /// is independent and does not accumulate state across calls beyond what
  /// is already reflected in [state].
  Future<void> pollOnce() async {
    final current = state;
    if (current is! JoinPending) return;

    final account = await _storage.loadAccount();
    if (account == null) {
      state = JoinFailed(message: 'Signed out while waiting.', previous: current);
      return;
    }

    try {
      final membership = await _api.getMembership(
        accountToken: account.accessToken,
        membershipId: current.membershipId,
      );
      switch (membership.status) {
        case 'approved':
          state = JoinApproved(
            membershipId: current.membershipId,
            sectorId: current.sectorId,
            role: membership.role,
            movementMode: membership.movementMode,
          );
        case 'rejected':
          state = JoinRejected(current.membershipId);
        case 'revoked':
        case 'ended':
          state = JoinRevoked(current.membershipId);
        default:
          // Still pending -- refresh in case the battery warning or sector
          // changed, but otherwise stay in the same state.
          state = JoinPending(
            membershipId: current.membershipId,
            sectorId: current.sectorId,
            batteryWarning: current.batteryWarning,
          );
      }
    } on ApiException catch (e) {
      // A transient poll failure shouldn't knock the user back to square
      // one -- stay in JoinPending and let the next tick retry.
      if (e.statusCode >= 500) return;
      state = JoinFailed(message: e.message, previous: current);
    }
  }

  Future<void> claimSession() async {
    final current = state;
    if (current is! JoinApproved) return;

    state = JoinClaimingSession(current.membershipId);

    final account = await _storage.loadAccount();
    if (account == null) {
      state = JoinFailed(
        message: 'Signed out before the session could be claimed.',
        previous: current,
      );
      return;
    }

    try {
      final result = await _api.claimSession(
        accountToken: account.accessToken,
        membershipId: current.membershipId,
      );
      await _storage.saveSession(
        StoredSession(
          accessToken: result.accessToken,
          expiresAt: result.expiresAt,
          keyEpoch: result.keyEpoch,
          sectorKeyBase64: result.sectorKeyBase64,
          membershipId: current.membershipId,
          sectorId: result.sector.id,
          eventId: result.sector.eventId,
          role: current.role,
          movementMode: current.movementMode,
        ),
      );
      state = JoinSessionActive(
        sectorId: result.sector.id,
        sectorName: result.sector.name,
      );
    } on ApiException catch (e) {
      state = JoinFailed(message: e.message, previous: current);
    }
  }

  void reset() => state = const JoinIdle();
}
