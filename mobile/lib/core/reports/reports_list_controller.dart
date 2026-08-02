/// The sector's report list: visible to any sector member (unlike SOS's
/// Lead/Commander-only actions -- see `ApiClient.listSectorReports`'s
/// docstring), with acknowledge restricted to a Lead/Commander as a
/// lightweight triage signal.
library;

import 'package:state_notifier/state_notifier.dart';

import '../api/api_client.dart';
import '../api/api_exception.dart';
import '../storage/secure_storage_manager.dart';
import 'reports_list_state.dart';

class ReportsListController extends StateNotifier<ReportsListState> {
  final ApiClient _api;
  final SecureStorageManager _storage;

  ReportsListController({required ApiClient api, required SecureStorageManager storage})
    : _api = api,
      _storage = storage,
      super(const ReportsListLoading());

  Future<void> load() async {
    final account = await _storage.loadAccount();
    final session = await _storage.loadSession();
    if (account == null || session == null) {
      state = const ReportsListFailed('Not signed in to a sector.');
      return;
    }

    try {
      final reports = await _api.listSectorReports(
        accountToken: account.accessToken,
        sectorId: session.sectorId,
      );
      state = ReportsListLoaded(reports);
    } on ApiException catch (e) {
      state = ReportsListFailed(e.message);
    }
  }

  Future<void> acknowledge(String reportId) async {
    final account = await _storage.loadAccount();
    if (account == null) {
      state = const ReportsListFailed('Not signed in.');
      return;
    }
    try {
      await _api.acknowledgeReport(accountToken: account.accessToken, reportId: reportId);
      await load();
    } on ApiException catch (e) {
      state = ReportsListFailed(e.message);
    }
  }
}
