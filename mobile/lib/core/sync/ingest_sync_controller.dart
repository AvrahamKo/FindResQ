/// Drains [TelemetryBufferStore] to the real `/ingest` endpoint: peek a
/// batch, POST it, acknowledge (delete) it on any 200 response, back off
/// and retry the SAME batch on any request-level failure.
///
/// Self-scheduling, like `LocationTrackingController`: `start()` kicks off
/// a loop that keeps rescheduling itself via `Timer` (short interval when
/// idle/healthy, exponential backoff after a failure) until `stop()`. This
/// keeps sync running in the background independent of which screen is
/// mounted -- it is not a UI-lifecycle-bound poll like
/// `PendingApprovalView`'s timer.
///
/// [syncOnce] is public specifically so tests can drive one attempt
/// directly and deterministically, without waiting on real timers.
library;

import 'dart:async';
import 'dart:convert';

import 'package:state_notifier/state_notifier.dart';

import '../api/api_client.dart';
import '../api/api_exception.dart';
import '../storage/secure_storage_manager.dart';
import '../storage/telemetry_buffer_store.dart';
import 'sync_backoff_policy.dart';
import 'sync_state.dart';

class IngestSyncController extends StateNotifier<SyncState> {
  final ApiClient _api;
  final SecureStorageManager _storage;
  final TelemetryBufferStore _buffer;
  final SyncBackoffPolicy _backoff;
  final int _batchSize;
  final Duration _baseInterval;

  bool _running = false;
  int _consecutiveFailures = 0;
  int _totalUploaded = 0;
  int _totalRejected = 0;
  DateTime? _lastSyncAt;
  Timer? _timer;

  IngestSyncController({
    required ApiClient api,
    required SecureStorageManager storage,
    required TelemetryBufferStore buffer,
    SyncBackoffPolicy backoff = const SyncBackoffPolicy(),
    int batchSize = 200,
    Duration baseInterval = const Duration(seconds: 30),
  }) : _api = api,
       _storage = storage,
       _buffer = buffer,
       _backoff = backoff,
       _batchSize = batchSize,
       _baseInterval = baseInterval,
       super(const SyncIdle());

  /// Starts the self-perpetuating sync loop. Safe to call repeatedly --
  /// a no-op while already running.
  Future<void> start() async {
    if (_running) return;
    _running = true;
    await _tick();
  }

  /// Synchronous, deliberately, same reasoning as
  /// `LocationTrackingController.stop()`: the UI needs "stopped" reflected
  /// immediately, and nothing needs to wait for a pending in-flight upload
  /// to finish -- `_running` being false is checked before every
  /// reschedule, so no further ticks fire regardless of what an
  /// already-in-flight `syncOnce()` is doing.
  void stop() {
    _running = false;
    _timer?.cancel();
    _timer = null;
    state = const SyncIdle();
  }

  Future<void> _tick() async {
    await syncOnce();
    if (!_running) return;

    final delay = _consecutiveFailures > 0
        ? _backoff.delayFor(_consecutiveFailures)
        : _baseInterval;
    _timer = Timer(delay, _tick);
  }

  /// One sync attempt: peek the oldest [_batchSize] buffered packets, POST
  /// them, and either acknowledge the whole batch (any 200 response -- see
  /// `IngestResult`'s docstring for why the whole batch, not just
  /// `accepted`) or leave it untouched and record a failure for backoff to
  /// act on.
  Future<void> syncOnce() async {
    final session = await _storage.loadSession();
    if (session == null) {
      state = SyncError(
        message: 'No active sector session to sync to.',
        previous: state,
      );
      return;
    }

    final pendingCount = await _buffer.count();
    if (pendingCount == 0) {
      _consecutiveFailures = 0;
      state = _activeState(pendingCount: 0, isUploading: false);
      return;
    }

    state = _activeState(pendingCount: pendingCount, isUploading: true);

    final batch = await _buffer.peekOldest(_batchSize);
    try {
      final result = await _api.ingest(
        sessionToken: session.accessToken,
        blobs: batch.map((p) => base64Encode(p.blob)).toList(),
      );
      await _buffer.acknowledge(batch.map((p) => p.id).toList());

      _totalUploaded += result.accepted;
      _totalRejected += result.rejected;
      _consecutiveFailures = 0;
      _lastSyncAt = DateTime.now();

      state = _activeState(
        pendingCount: await _buffer.count(),
        isUploading: false,
        clearError: true,
      );
    } on ApiException catch (e) {
      _recordFailure(pendingCount, e.message);
    } on ApiProtocolException catch (e) {
      _recordFailure(pendingCount, e.message);
    }
  }

  void _recordFailure(int pendingCount, String message) {
    _consecutiveFailures++;
    state = _activeState(
      pendingCount: pendingCount,
      isUploading: false,
      errorMessage: message,
    );
  }

  SyncActive _activeState({
    required int pendingCount,
    required bool isUploading,
    String? errorMessage,
    bool clearError = false,
  }) {
    final current = state;
    return SyncActive(
      pendingCount: pendingCount,
      totalUploaded: _totalUploaded,
      totalRejected: _totalRejected,
      consecutiveFailures: _consecutiveFailures,
      isUploading: isUploading,
      lastSyncAt: _lastSyncAt,
      lastError: errorMessage ??
          (clearError
              ? null
              : (current is SyncActive ? current.lastError : null)),
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}
