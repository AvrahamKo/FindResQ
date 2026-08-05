import 'package:state_notifier/state_notifier.dart';

import '../location/location_sample.dart';
import '../storage/search_map_store.dart';
import '../storage/secure_storage_manager.dart';

class PersonalTrailController extends StateNotifier<List<PersonalTrackPoint>> {
  final SearchMapStore _mapStore;
  final SecureStorageManager _storage;
  String? _sectorId;
  Future<void>? _loading;

  PersonalTrailController({
    required SearchMapStore mapStore,
    required SecureStorageManager storage,
  }) : _mapStore = mapStore,
       _storage = storage,
       super(const []);

  Future<void> ensureLoaded() => _loading ??= _load();

  Future<void> _load() async {
    try {
      final session = await _storage.loadSession();
      if (session == null || !mounted) return;
      final trail = await _mapStore.loadTrail(session.sectorId);
      if (!mounted) return;
      _sectorId = session.sectorId;
      state = trail;
    } on Exception {
      // The map trail is an auxiliary offline visualization. A local cache
      // failure must never break GPS tracking or encrypted telemetry.
    }
  }

  Future<void> record(LocationSample sample) async {
    try {
      await ensureLoaded();
      final sectorId = _sectorId;
      if (sectorId == null || !mounted) return;
      final point = PersonalTrackPoint(
        latitude: sample.latitude,
        longitude: sample.longitude,
        accuracyM: sample.accuracyM,
        recordedAtMs: sample.recordedAtMs,
      );
      await _mapStore.appendTrailPoint(sectorId, point);
      if (!mounted) return;
      final next = [...state, point];
      state = next.length <= SearchMapStore.defaultTrailCapacity
          ? next
          : next.sublist(next.length - SearchMapStore.defaultTrailCapacity);
    } on Exception {
      // See _load: never let a visualization cache interrupt tracking.
    }
  }
}
