/// A minimal async key-value store, abstracted away from any particular
/// backend.
///
/// [SecureStorageManager] depends on this interface, not on
/// `flutter_secure_storage` directly -- the real package wraps Keychain/
/// Keystore via platform channels, which don't exist in a bare `flutter test`
/// host process. Depending on this interface instead means the manager's own
/// logic (what gets stored under what key, when it gets cleared) can be
/// tested with an in-memory fake, while production code wires up the real
/// secure-storage-backed implementation.
abstract class KeyValueStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);

  /// Deletes every key this store manages. Used for full teardown (Q9: an
  /// event ending must delete the session's encryption keys and return the
  /// app to an idle state).
  Future<void> deleteAll();
}
