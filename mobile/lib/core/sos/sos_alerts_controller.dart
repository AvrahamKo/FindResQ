/// Lead/Commander view over a sector's SOS alerts: list, acknowledge,
/// resolve. Uses the ACCOUNT token (not the session token) plus the
/// backend's Lead/Commander role check, same as membership moderation --
/// these actions happen on a DIFFERENT device than the one that triggered
/// the alert.
library;

import 'package:state_notifier/state_notifier.dart';

import '../api/api_client.dart';
import '../api/api_exception.dart';
import '../storage/secure_storage_manager.dart';
import 'sos_alerts_state.dart';

class SosAlertsController extends StateNotifier<SosAlertsState> {
  final ApiClient _api;
  final SecureStorageManager _storage;

  SosAlertsController({required ApiClient api, required SecureStorageManager storage})
    : _api = api,
      _storage = storage,
      super(const SosAlertsLoading());

  Future<void> load() async {
    final account = await _storage.loadAccount();
    final session = await _storage.loadSession();
    if (account == null || session == null) {
      state = const SosAlertsFailed('Not signed in to a sector.');
      return;
    }

    try {
      final alerts = await _api.listSectorSos(
        accountToken: account.accessToken,
        sectorId: session.sectorId,
      );
      state = SosAlertsLoaded(alerts);
    } on ApiException catch (e) {
      state = SosAlertsFailed(e.message);
    }
  }

  Future<void> acknowledge(String alertId) async {
    final account = await _storage.loadAccount();
    if (account == null) {
      state = const SosAlertsFailed('Not signed in.');
      return;
    }
    try {
      await _api.acknowledgeSos(accountToken: account.accessToken, alertId: alertId);
      await load();
    } on ApiException catch (e) {
      state = SosAlertsFailed(e.message);
    }
  }

  Future<void> resolve(String alertId) async {
    final account = await _storage.loadAccount();
    if (account == null) {
      state = const SosAlertsFailed('Not signed in.');
      return;
    }
    try {
      await _api.resolveSos(accountToken: account.accessToken, alertId: alertId);
      await load();
    } on ApiException catch (e) {
      state = SosAlertsFailed(e.message);
    }
  }
}
