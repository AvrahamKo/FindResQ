import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lifesearch_mobile/core/api/api_client.dart';
import 'package:lifesearch_mobile/core/crypto/device_identity.dart';
import 'package:lifesearch_mobile/core/crypto/mesh_crypto.dart';
import 'package:lifesearch_mobile/core/crypto/sodium_provider.dart';
import 'package:lifesearch_mobile/core/reports/report_controller.dart';
import 'package:lifesearch_mobile/core/reports/report_packet_builder.dart';
import 'package:lifesearch_mobile/core/reports/report_state.dart';
import 'package:lifesearch_mobile/core/storage/secure_storage_manager.dart';
import 'package:lifesearch_mobile/core/storage/stored_models.dart';
import 'package:sodium/sodium.dart';

import '../../helpers/fake_location_source.dart';
import '../../helpers/in_memory_key_value_store.dart';

http.Response _json(Object body, int status) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

class _Router {
  final Map<String, http.Response Function(http.Request)> _routes = {};

  void on(String method, String path, http.Response Function(http.Request) handler) {
    _routes['$method $path'] = handler;
  }

  Future<http.Response> call(http.Request request) async {
    final handler = _routes['${request.method} ${request.url.path}'];
    if (handler == null) {
      fail('unexpected request: ${request.method} ${request.url.path}');
    }
    return handler(request);
  }
}

void main() {
  late Sodium sodium;
  late DeviceIdentity identity;
  late MeshCrypto crypto;

  setUpAll(() async {
    sodium = await SodiumProvider.instance();
    identity = DeviceIdentity(sodium);
    crypto = MeshCrypto(sodium);
  });

  Future<InMemoryKeyValueStore> registeredStore() async {
    final store = InMemoryKeyValueStore();
    final manager = SecureStorageManager(store);
    final pair = identity.generateKeyPair();
    await manager.saveDeviceIdentity(
      StoredDeviceIdentity(
        publicKeyBase64: pair.publicKeyBase64,
        secretKeyBase64: base64Encode(pair.secretKey.extractBytes()),
        deviceId: 'device-1',
        wireId: 42,
      ),
    );
    pair.dispose();

    final sectorKey = sodium.secureRandom(meshKeyBytes);
    await manager.saveSession(
      StoredSession(
        accessToken: 'session-tok',
        expiresAt: DateTime.now().add(const Duration(hours: 8)),
        keyEpoch: 1,
        sectorKeyBase64: base64Encode(sectorKey.extractBytes()),
        membershipId: 'm1',
        sectorId: 's1',
        eventId: 'e1',
        role: 'volunteer',
        movementMode: 'walker',
      ),
    );
    sectorKey.dispose();
    return store;
  }

  ({ReportController controller, FakeLocationSource location}) buildHarness(
    _Router router,
    InMemoryKeyValueStore store,
  ) {
    final api = ApiClient(
      baseUrl: 'http://test.invalid',
      httpClient: MockClient(router.call),
    );
    final location = FakeLocationSource();
    final controller = ReportController(
      api: api,
      storage: SecureStorageManager(store),
      location: location,
      packetBuilder: ReportPacketBuilder(identity, crypto),
      sodium: sodium,
    );
    return (controller: controller, location: location);
  }

  group('submit', () {
    test('moves to ReportSubmitted on a successful upload', () async {
      http.Request? captured;
      final router = _Router()
        ..on('POST', '/reports', (r) {
          captured = r;
          return _json({
            'accepted': 1, 'duplicate': 0, 'decrypt_failed': 0,
            'signature_invalid': 0, 'wrong_device': 0, 'malformed': 0,
          }, 200);
        });
      final h = buildHarness(router, await registeredStore());

      await h.controller.submit(kind: 'hazard', note: 'Downed tree.');

      final state = h.controller.state;
      expect(state, isA<ReportSubmitted>());
      expect((state as ReportSubmitted).kind, equals('hazard'));

      final sentBlobs = (jsonDecode(captured!.body) as Map)['blobs'] as List;
      expect(sentBlobs, hasLength(1));
    });

    test('fails when the device has no wireId yet', () async {
      final store = InMemoryKeyValueStore();
      final manager = SecureStorageManager(store);
      await manager.saveDeviceIdentity(
        const StoredDeviceIdentity(publicKeyBase64: 'pub==', secretKeyBase64: 'sec=='),
      );
      final h = buildHarness(_Router(), store);

      await h.controller.submit(kind: 'hazard', note: '');

      expect(h.controller.state, isA<ReportError>());
    });

    test('fails when there is no active session', () async {
      final h = buildHarness(_Router(), InMemoryKeyValueStore());

      await h.controller.submit(kind: 'hazard', note: '');

      expect(h.controller.state, isA<ReportError>());
    });

    test('a location failure surfaces as ReportError without ever hitting the network', () async {
      var requestCount = 0;
      final router = _Router()
        ..on('POST', '/reports', (r) {
          requestCount++;
          return _json({}, 200);
        });
      final h = buildHarness(router, await registeredStore());
      h.location.currentPositionError = Exception('GPS unavailable');

      await h.controller.submit(kind: 'hazard', note: '');

      expect(h.controller.state, isA<ReportError>());
      expect(requestCount, equals(0));
    });

    test('a backend error produces ReportError', () async {
      final router = _Router()
        ..on(
          'POST',
          '/reports',
          (r) => _json({
            'error': {'code': 'internal', 'message': 'boom'},
          }, 500),
        );
      final h = buildHarness(router, await registeredStore());

      await h.controller.submit(kind: 'hazard', note: '');

      final state = h.controller.state;
      expect(state, isA<ReportError>());
      expect((state as ReportError).message, equals('boom'));
    });

    test('a batch with accepted == 0 (e.g. duplicate) is treated as a failure', () async {
      final router = _Router()
        ..on(
          'POST',
          '/reports',
          (r) => _json({
            'accepted': 0, 'duplicate': 1, 'decrypt_failed': 0,
            'signature_invalid': 0, 'wrong_device': 0, 'malformed': 0,
          }, 200),
        );
      final h = buildHarness(router, await registeredStore());

      await h.controller.submit(kind: 'hazard', note: '');

      expect(h.controller.state, isA<ReportError>());
    });
  });

  test('reset returns to ReportIdle', () async {
    final router = _Router()
      ..on(
        'POST',
        '/reports',
        (r) => _json({
          'error': {'code': 'internal', 'message': 'boom'},
        }, 500),
      );
    final h = buildHarness(router, await registeredStore());
    await h.controller.submit(kind: 'hazard', note: '');
    expect(h.controller.state, isA<ReportError>());

    h.controller.reset();

    expect(h.controller.state, isA<ReportIdle>());
  });
}
