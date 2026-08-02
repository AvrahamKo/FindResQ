/// Orchestrates filing a single field report: grab a fresh GPS fix, pack +
/// sign + encrypt it (same envelope construction as location telemetry, see
/// [ReportPacketBuilder]), and submit it via the device's sector session
/// token. One-shot, not a background/self-scheduling controller like
/// [LocationTrackingController]/[IngestSyncController] -- filing a report is
/// a deliberate, occasional human action, not a continuous stream.
library;

import 'dart:convert';

import 'package:sodium/sodium.dart';
import 'package:state_notifier/state_notifier.dart';

import '../api/api_client.dart';
import '../api/api_exception.dart';
import '../location/location_sample.dart';
import '../location/location_source.dart';
import '../storage/secure_storage_manager.dart';
import 'report_packet_builder.dart';
import 'report_state.dart';

class ReportController extends StateNotifier<ReportState> {
  final ApiClient _api;
  final SecureStorageManager _storage;
  final LocationSource _location;
  final ReportPacketBuilder _packetBuilder;
  final Sodium _sodium;

  ReportController({
    required ApiClient api,
    required SecureStorageManager storage,
    required LocationSource location,
    required ReportPacketBuilder packetBuilder,
    required Sodium sodium,
  }) : _api = api,
       _storage = storage,
       _location = location,
       _packetBuilder = packetBuilder,
       _sodium = sodium,
       super(const ReportIdle());

  Future<void> submit({required String kind, required String note}) async {
    state = const ReportSubmitting();

    final identity = await _storage.loadDeviceIdentity();
    final session = await _storage.loadSession();
    if (identity?.deviceId == null || identity?.wireId == null) {
      state = const ReportError(
        message: 'This device is not registered yet.',
        previous: ReportIdle(),
      );
      return;
    }
    if (session == null) {
      state = const ReportError(
        message: 'No active sector session to report to.',
        previous: ReportIdle(),
      );
      return;
    }

    final LocationSample position;
    try {
      position = await _location.getCurrentPosition();
    } on Object catch (e) {
      state = ReportError(
        message: 'Could not get your current location: $e',
        previous: const ReportIdle(),
      );
      return;
    }

    final deviceSecretKey = _sodium.secureCopy(
      base64Decode(identity!.secretKeyBase64),
    );
    final sectorKey = _sodium.secureCopy(
      base64Decode(session.sectorKeyBase64),
    );
    try {
      final blob = _packetBuilder.build(
        wireId: identity.wireId!,
        deviceSecretKey: deviceSecretKey,
        sectorKey: sectorKey,
        recordedAtMs: position.recordedAtMs,
        kind: kind,
        lat: position.latitude,
        lng: position.longitude,
        note: note,
      );
      final result = await _api.submitReports(
        sessionToken: session.accessToken,
        blobs: [base64Encode(blob)],
      );
      if (result.accepted >= 1) {
        state = ReportSubmitted(kind);
      } else {
        state = const ReportError(
          message: 'The report was not accepted (it may have been a duplicate).',
          previous: ReportIdle(),
        );
      }
    } on ApiException catch (e) {
      state = ReportError(message: e.message, previous: const ReportIdle());
    } finally {
      deviceSecretKey.dispose();
      sectorKey.dispose();
    }
  }

  void reset() => state = const ReportIdle();
}
