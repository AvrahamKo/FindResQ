import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lifesearch_mobile/core/api/api_client.dart';
import 'package:lifesearch_mobile/core/auth/auth_controller.dart';
import 'package:lifesearch_mobile/core/auth/auth_state.dart';
import 'package:lifesearch_mobile/core/crypto/device_identity.dart';
import 'package:lifesearch_mobile/core/crypto/sodium_provider.dart';
import 'package:lifesearch_mobile/core/storage/secure_storage_manager.dart';
import 'package:lifesearch_mobile/core/storage/stored_models.dart';
import 'package:sodium/sodium.dart';

import '../../helpers/in_memory_key_value_store.dart';

http.Response _json(Object body, int status) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

/// Routes requests by "METHOD path" to a canned response, so a single test
/// can simulate the several-endpoint sequence a full sign-in triggers
/// (OTP verify -> key challenge -> device register) without a real server.
class _Router {
  final Map<String, http.Response Function(http.Request)> _routes = {};
  final List<http.Request> requests = [];

  void on(String method, String path, http.Response Function(http.Request) handler) {
    _routes['$method $path'] = handler;
  }

  Future<http.Response> call(http.Request request) async {
    requests.add(request);
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

  setUpAll(() async {
    sodium = await SodiumProvider.instance();
    identity = DeviceIdentity(sodium);
  });

  AuthController buildController(_Router router, InMemoryKeyValueStore store) {
    final api = ApiClient(
      baseUrl: 'http://test.invalid',
      httpClient: MockClient(router.call),
    );
    return AuthController(
      api: api,
      storage: SecureStorageManager(store),
      identity: identity,
      sodium: sodium,
    );
  }

  group('requestOtp', () {
    test('moves to AuthOtpSent on success', () async {
      final router = _Router()
        ..on(
          'POST',
          '/auth/otp/request',
          (r) => _json({
            'challenge_id': 'c1',
            'expires_at': '2030-01-01T00:00:00Z',
            'dev_code': '123456',
          }, 201),
        );
      final controller = buildController(router, InMemoryKeyValueStore());

      await controller.requestOtp('+15551234567');

      final state = controller.state;
      expect(state, isA<AuthOtpSent>());
      expect((state as AuthOtpSent).challengeId, equals('c1'));
      expect(state.devCode, equals('123456'));
    });

    test('moves to AuthFailed on a backend error', () async {
      final router = _Router()
        ..on(
          'POST',
          '/auth/otp/request',
          (r) => _json({
            'error': {'code': 'rate_limited', 'message': 'wait 30s'},
          }, 429),
        );
      final controller = buildController(router, InMemoryKeyValueStore());

      await controller.requestOtp('+15551234567');

      expect(controller.state, isA<AuthFailed>());
      expect((controller.state as AuthFailed).message, equals('wait 30s'));
    });
  });

  group('verifyOtp -> device registration', () {
    test('full flow: verify, generate keypair, register, sign in', () async {
      final store = InMemoryKeyValueStore();
      final router = _Router()
        ..on(
          'POST',
          '/auth/otp/request',
          (r) => _json({
            'challenge_id': 'c1',
            'expires_at': '2030-01-01T00:00:00Z',
          }, 201),
        )
        ..on(
          'POST',
          '/auth/otp/verify',
          (r) => _json({
            'access_token': 'account-tok',
            'token_type': 'Bearer',
            'expires_at': '2030-01-01T00:00:00Z',
            'user': {
              'id': 'u1',
              'phone_e164': '+15551234567',
              'display_name': 'Test',
              'verification_status': 'unverified',
            },
          }, 200),
        )
        ..on(
          'POST',
          '/devices/key-challenge',
          (r) => _json({
            'challenge_id': 'kc1',
            'nonce': base64Encode(List.filled(32, 7)),
            'expires_at': '2030-01-01T00:00:00Z',
          }, 201),
        )
        ..on(
          'POST',
          '/devices',
          (r) => _json({
            'id': 'device-1',
            'wire_id': 42,
            'public_key': (jsonDecode(r.body) as Map)['public_key'],
            'platform': 'android',
            'mesh_capable': true,
            'label': null,
            'registered_at': '2030-01-01T00:00:00Z',
            'revoked_at': null,
          }, 201),
        );

      final controller = buildController(router, store);
      await controller.requestOtp('+15551234567');
      await controller.verifyOtp('123456');

      final state = controller.state;
      expect(state, isA<AuthSignedIn>());
      expect((state as AuthSignedIn).deviceId, equals('device-1'));
      expect(state.user.id, equals('u1'));

      final storedAccount = await SecureStorageManager(store).loadAccount();
      expect(storedAccount?.accessToken, equals('account-tok'));

      final storedIdentity = await SecureStorageManager(store).loadDeviceIdentity();
      expect(storedIdentity?.deviceId, equals('device-1'));
      expect(storedIdentity?.publicKeyBase64, isNotEmpty);
    });

    test(
      'a dropped-connection retry does not generate a second keypair',
      () async {
        final store = InMemoryKeyValueStore();
        final manager = SecureStorageManager(store);
        // Simulate: keypair was already generated and persisted on a
        // previous attempt, but registration never completed (deviceId null).
        final pair = identity.generateKeyPair();
        final preExisting = StoredDeviceIdentity(
          publicKeyBase64: pair.publicKeyBase64,
          secretKeyBase64: base64Encode(pair.secretKey.extractBytes()),
        );
        pair.dispose();
        await manager.saveDeviceIdentity(preExisting);

        String? registeredPublicKey;
        final router = _Router()
          ..on(
            'POST',
            '/auth/otp/request',
            (r) => _json({
              'challenge_id': 'c1',
              'expires_at': '2030-01-01T00:00:00Z',
            }, 201),
          )
          ..on(
            'POST',
            '/auth/otp/verify',
            (r) => _json({
              'access_token': 'account-tok',
              'token_type': 'Bearer',
              'expires_at': '2030-01-01T00:00:00Z',
              'user': {
                'id': 'u1',
                'phone_e164': '+15551234567',
                'display_name': 'Test',
                'verification_status': 'unverified',
              },
            }, 200),
          )
          ..on(
            'POST',
            '/devices/key-challenge',
            (r) => _json({
              'challenge_id': 'kc1',
              'nonce': base64Encode(List.filled(32, 7)),
              'expires_at': '2030-01-01T00:00:00Z',
            }, 201),
          )
          ..on('POST', '/devices', (r) {
            registeredPublicKey = (jsonDecode(r.body) as Map)['public_key'] as String;
            return _json({
              'id': 'device-1',
              'wire_id': 42,
              'public_key': registeredPublicKey,
              'platform': 'android',
              'mesh_capable': true,
              'label': null,
              'registered_at': '2030-01-01T00:00:00Z',
              'revoked_at': null,
            }, 201);
          });

        final controller = buildController(router, store);
        await controller.requestOtp('+15551234567');
        await controller.verifyOtp('123456');

        // The registration retried the challenge/register round trip, but
        // reused the PRE-EXISTING keypair rather than generating a new one.
        expect(registeredPublicKey, equals(preExisting.publicKeyBase64));
      },
    );

    test('a 409 "already registered" conflict recovers via device list', () async {
      final store = InMemoryKeyValueStore();
      String? generatedPublicKey;
      final router = _Router()
        ..on(
          'POST',
          '/auth/otp/request',
          (r) => _json({
            'challenge_id': 'c1',
            'expires_at': '2030-01-01T00:00:00Z',
          }, 201),
        )
        ..on(
          'POST',
          '/auth/otp/verify',
          (r) => _json({
            'access_token': 'account-tok',
            'token_type': 'Bearer',
            'expires_at': '2030-01-01T00:00:00Z',
            'user': {
              'id': 'u1',
              'phone_e164': '+15551234567',
              'display_name': 'Test',
              'verification_status': 'unverified',
            },
          }, 200),
        )
        ..on(
          'POST',
          '/devices/key-challenge',
          (r) => _json({
            'challenge_id': 'kc1',
            'nonce': base64Encode(List.filled(32, 7)),
            'expires_at': '2030-01-01T00:00:00Z',
          }, 201),
        )
        ..on('POST', '/devices', (r) {
          generatedPublicKey = (jsonDecode(r.body) as Map)['public_key'] as String;
          return _json({
            'error': {
              'code': 'conflict',
              'message': 'this device key is already registered to you',
            },
          }, 409);
        })
        ..on(
          'GET',
          '/devices',
          (r) => http.Response(
            jsonEncode([
              {
                'id': 'existing-device-42',
                'wire_id': 7,
                'public_key': generatedPublicKey,
                'platform': 'android',
                'mesh_capable': true,
                'label': null,
                'registered_at': '2030-01-01T00:00:00Z',
                'revoked_at': null,
              },
            ]),
            200,
            headers: {'content-type': 'application/json'},
          ),
        );

      final controller = buildController(router, store);
      await controller.requestOtp('+15551234567');
      await controller.verifyOtp('123456');

      final state = controller.state;
      expect(state, isA<AuthSignedIn>());
      expect((state as AuthSignedIn).deviceId, equals('existing-device-42'));
    });
  });

  group('restore', () {
    test('signs in immediately from a valid stored account + device', () async {
      final store = InMemoryKeyValueStore();
      final manager = SecureStorageManager(store);
      await manager.saveAccount(
        StoredAccount(
          accessToken: 'tok',
          expiresAt: DateTime.now().add(const Duration(days: 1)),
          userId: 'u1',
          phoneE164: '+15551234567',
          displayName: 'Test',
        ),
      );
      await manager.saveDeviceIdentity(
        const StoredDeviceIdentity(
          publicKeyBase64: 'pub==',
          secretKeyBase64: 'sec==',
          deviceId: 'device-1',
        ),
      );

      final controller = buildController(_Router(), store);
      await controller.restore();

      final state = controller.state;
      expect(state, isA<AuthSignedIn>());
      expect((state as AuthSignedIn).deviceId, equals('device-1'));
    });

    test('signs out when nothing is stored', () async {
      final controller = buildController(_Router(), InMemoryKeyValueStore());
      await controller.restore();
      expect(controller.state, isA<AuthSignedOut>());
    });

    test('signs out when the stored account has expired', () async {
      final store = InMemoryKeyValueStore();
      await SecureStorageManager(store).saveAccount(
        StoredAccount(
          accessToken: 'tok',
          expiresAt: DateTime.now().subtract(const Duration(days: 1)),
          userId: 'u1',
          phoneE164: '+15551234567',
          displayName: 'Test',
        ),
      );

      final controller = buildController(_Router(), store);
      await controller.restore();

      expect(controller.state, isA<AuthSignedOut>());
    });
  });

  group('signOut', () {
    test('clears storage and returns to AuthSignedOut', () async {
      final store = InMemoryKeyValueStore();
      final manager = SecureStorageManager(store);
      await manager.saveAccount(
        StoredAccount(
          accessToken: 'tok',
          expiresAt: DateTime.now().add(const Duration(days: 1)),
          userId: 'u1',
          phoneE164: '+15551234567',
          displayName: 'Test',
        ),
      );

      final controller = buildController(_Router(), store);
      await controller.signOut();

      expect(controller.state, isA<AuthSignedOut>());
      expect(await manager.loadAccount(), isNull);
    });
  });
}
