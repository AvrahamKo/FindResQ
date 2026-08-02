/// Orchestrates the searcher's OWN SOS: trigger and cancel, using the
/// device's sector session token (same auth as ingest). Does not persist
/// across app restarts -- there is no "get my current alert" endpoint, and
/// none is needed: [trigger] is idempotent server-side (see
/// `backend/app/repositories/sos.py`), so pressing the button again after a
/// restart safely lands back on the SAME open alert rather than creating a
/// duplicate, even though this controller itself starts back at [SosIdle].
library;

import 'package:state_notifier/state_notifier.dart';

import '../api/api_client.dart';
import '../api/api_exception.dart';
import '../storage/secure_storage_manager.dart';
import 'sos_state.dart';

class SosController extends StateNotifier<SosState> {
  final ApiClient _api;
  final SecureStorageManager _storage;

  SosController({required ApiClient api, required SecureStorageManager storage})
    : _api = api,
      _storage = storage,
      super(const SosIdle());

  Future<void> trigger({double? lat, double? lng}) async {
    final current = state;
    if (current is SosActive || current is SosTriggering) return;

    state = const SosTriggering();

    final session = await _storage.loadSession();
    if (session == null) {
      state = const SosError(
        message: 'No active sector session -- join a sector first.',
        previous: SosIdle(),
      );
      return;
    }

    try {
      final alert = await _api.triggerSos(
        sessionToken: session.accessToken,
        lat: lat,
        lng: lng,
      );
      state = SosActive(alert);
    } on ApiException catch (e) {
      state = SosError(message: e.message, previous: const SosIdle());
    }
  }

  Future<void> cancel() async {
    final current = state;
    if (current is! SosActive) return;

    state = SosCancelling(current.alert);

    final session = await _storage.loadSession();
    if (session == null) {
      state = SosError(
        message: 'No active sector session -- cannot reach the server to cancel.',
        previous: current,
      );
      return;
    }

    try {
      final alert = await _api.cancelSos(
        sessionToken: session.accessToken,
        alertId: current.alert.id,
      );
      state = alert.isOpen ? SosActive(alert) : const SosIdle();
    } on ApiException catch (e) {
      state = SosError(message: e.message, previous: current);
    }
  }

  void reset() => state = const SosIdle();
}
