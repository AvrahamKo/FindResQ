import 'package:lifesearch_mobile/core/storage/key_value_store.dart';

/// A [KeyValueStore] backed by a plain Dart map -- for tests only. Lets
/// [SecureStorageManager]'s own logic (what gets stored under what key,
/// atomicity of related fields) be tested without a real platform channel,
/// which doesn't exist in a bare `flutter test` host process.
class InMemoryKeyValueStore implements KeyValueStore {
  final Map<String, String> _data = {};

  @override
  Future<String?> read(String key) async => _data[key];

  @override
  Future<void> write(String key, String value) async {
    _data[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    _data.remove(key);
  }

  @override
  Future<void> deleteAll() async {
    _data.clear();
  }

  bool containsKey(String key) => _data.containsKey(key);
}
