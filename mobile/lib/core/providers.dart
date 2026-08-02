/// Central Riverpod provider wiring.
///
/// Every provider that touches the outside world (network, storage, native
/// crypto) is overridable -- tests replace [apiClientProvider] with a
/// `MockClient`-backed instance and [keyValueStoreProvider] with an
/// in-memory fake, without touching controller logic at all.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sodium/sodium.dart';

import 'api/api_client.dart';
import 'auth/auth_controller.dart';
import 'auth/auth_state.dart';
import 'crypto/device_identity.dart';
import 'crypto/sodium_provider.dart';
import 'join/join_controller.dart';
import 'join/join_state.dart';
import 'storage/key_value_store.dart';
import 'storage/secure_key_value_store.dart';
import 'storage/secure_storage_manager.dart';

/// Overridden in `main.dart` with the real backend URL, and in tests with
/// whatever the test harness is actually listening on.
final baseUrlProvider = Provider<String>(
  (ref) => throw UnimplementedError('baseUrlProvider must be overridden'),
);

final sodiumProvider = FutureProvider<Sodium>((ref) => SodiumProvider.instance());

final keyValueStoreProvider = Provider<KeyValueStore>(
  (ref) => SecureKeyValueStore(),
);

final secureStorageManagerProvider = Provider<SecureStorageManager>(
  (ref) => SecureStorageManager(ref.watch(keyValueStoreProvider)),
);

final apiClientProvider = Provider<ApiClient>(
  (ref) => ApiClient(baseUrl: ref.watch(baseUrlProvider)),
);

final deviceIdentityProvider = Provider<DeviceIdentity>((ref) {
  final sodium = ref.watch(sodiumProvider).requireValue;
  return DeviceIdentity(sodium);
});

final authControllerProvider =
    StateNotifierProvider<AuthController, AuthState>((ref) {
      final sodium = ref.watch(sodiumProvider).requireValue;
      return AuthController(
        api: ref.watch(apiClientProvider),
        storage: ref.watch(secureStorageManagerProvider),
        identity: ref.watch(deviceIdentityProvider),
        sodium: sodium,
      );
    });

final joinControllerProvider =
    StateNotifierProvider<JoinController, JoinState>((ref) {
      return JoinController(
        api: ref.watch(apiClientProvider),
        storage: ref.watch(secureStorageManagerProvider),
      );
    });
