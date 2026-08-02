import 'package:flutter_test/flutter_test.dart';
import 'package:lifesearch_mobile/core/storage/secure_storage_manager.dart';
import 'package:lifesearch_mobile/core/storage/stored_models.dart';

import '../../helpers/in_memory_key_value_store.dart';

void main() {
  late InMemoryKeyValueStore store;
  late SecureStorageManager manager;

  setUp(() {
    store = InMemoryKeyValueStore();
    manager = SecureStorageManager(store);
  });

  group('device identity', () {
    test('round trips through storage', () async {
      const identity = StoredDeviceIdentity(
        publicKeyBase64: 'pub==',
        secretKeyBase64: 'sec==',
      );
      await manager.saveDeviceIdentity(identity);

      final loaded = await manager.loadDeviceIdentity();
      expect(loaded?.publicKeyBase64, equals('pub=='));
      expect(loaded?.secretKeyBase64, equals('sec=='));
      expect(loaded?.deviceId, isNull);
    });

    test('is null before anything is saved', () async {
      expect(await manager.loadDeviceIdentity(), isNull);
    });

    test('withDeviceId preserves the keypair and adds the id', () async {
      const identity = StoredDeviceIdentity(
        publicKeyBase64: 'pub==',
        secretKeyBase64: 'sec==',
      );
      await manager.saveDeviceIdentity(identity.withDeviceId('device-123'));

      final loaded = await manager.loadDeviceIdentity();
      expect(loaded?.publicKeyBase64, equals('pub=='));
      expect(loaded?.deviceId, equals('device-123'));
    });
  });

  group('account', () {
    test('round trips through storage, including expiry', () async {
      final expiresAt = DateTime.utc(2030, 1, 1);
      await manager.saveAccount(
        StoredAccount(
          accessToken: 'tok',
          expiresAt: expiresAt,
          userId: 'u1',
          phoneE164: '+15551234567',
          displayName: 'Test User',
        ),
      );

      final loaded = await manager.loadAccount();
      expect(loaded?.accessToken, equals('tok'));
      expect(loaded?.expiresAt, equals(expiresAt));
      expect(loaded?.isExpired, isFalse);
    });

    test('isExpired is true once expiresAt has passed', () async {
      await manager.saveAccount(
        StoredAccount(
          accessToken: 'tok',
          expiresAt: DateTime.utc(2000, 1, 1),
          userId: 'u1',
          phoneE164: '+15551234567',
          displayName: 'Test User',
        ),
      );
      expect((await manager.loadAccount())!.isExpired, isTrue);
    });

    test('clearAccount removes it without touching other keys', () async {
      await manager.saveAccount(
        StoredAccount(
          accessToken: 'tok',
          expiresAt: DateTime.utc(2030, 1, 1),
          userId: 'u1',
          phoneE164: '+15551234567',
          displayName: 'Test User',
        ),
      );
      await manager.saveDeviceIdentity(
        const StoredDeviceIdentity(publicKeyBase64: 'p', secretKeyBase64: 's'),
      );

      await manager.clearAccount();

      expect(await manager.loadAccount(), isNull);
      expect(await manager.loadDeviceIdentity(), isNotNull);
    });
  });

  group('session', () {
    test('round trips every field atomically', () async {
      final expiresAt = DateTime.utc(2030, 6, 1);
      await manager.saveSession(
        StoredSession(
          accessToken: 'session-tok',
          expiresAt: expiresAt,
          keyEpoch: 2,
          sectorKeyBase64: 'key==',
          membershipId: 'm1',
          sectorId: 's1',
          eventId: 'e1',
          role: 'volunteer',
          movementMode: 'walker',
        ),
      );

      final loaded = await manager.loadSession();
      expect(loaded?.accessToken, equals('session-tok'));
      expect(loaded?.keyEpoch, equals(2));
      expect(loaded?.sectorKeyBase64, equals('key=='));
      expect(loaded?.membershipId, equals('m1'));
      expect(loaded?.role, equals('volunteer'));
      expect(loaded?.movementMode, equals('walker'));
    });

    test('clearSession deletes the sector key -- Q9 data minimization', () async {
      await manager.saveSession(
        StoredSession(
          accessToken: 'tok',
          expiresAt: DateTime.utc(2030, 1, 1),
          keyEpoch: 1,
          sectorKeyBase64: 'key==',
          membershipId: 'm1',
          sectorId: 's1',
          eventId: 'e1',
          role: 'volunteer',
          movementMode: 'walker',
        ),
      );

      await manager.clearSession();

      expect(await manager.loadSession(), isNull);
    });
  });

  test('clearAll wipes account, session, and device identity', () async {
    await manager.saveAccount(
      StoredAccount(
        accessToken: 'tok',
        expiresAt: DateTime.utc(2030, 1, 1),
        userId: 'u1',
        phoneE164: '+15551234567',
        displayName: 'Test User',
      ),
    );
    await manager.saveDeviceIdentity(
      const StoredDeviceIdentity(publicKeyBase64: 'p', secretKeyBase64: 's'),
    );
    await manager.saveSession(
      StoredSession(
        accessToken: 'tok',
        expiresAt: DateTime.utc(2030, 1, 1),
        keyEpoch: 1,
        sectorKeyBase64: 'key==',
        membershipId: 'm1',
        sectorId: 's1',
        eventId: 'e1',
        role: 'volunteer',
        movementMode: 'walker',
      ),
    );

    await manager.clearAll();

    expect(await manager.loadAccount(), isNull);
    expect(await manager.loadDeviceIdentity(), isNull);
    expect(await manager.loadSession(), isNull);
  });
}
