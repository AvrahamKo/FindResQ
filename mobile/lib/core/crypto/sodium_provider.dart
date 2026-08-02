/// Lazily initializes and caches the single [Sodium] instance the app uses.
///
/// `SodiumInit.init()` builds/loads the native libsodium binary via Dart's
/// native-assets build hooks -- this only works when run through `flutter`
/// or `dart run`, not a bare `dart <file>.dart` invocation. See the `sodium`
/// package README's "Deploying with build hooks" section.
library;

import 'package:sodium/sodium.dart';

class SodiumProvider {
  static Sodium? _instance;

  static Future<Sodium> instance() async {
    return _instance ??= await SodiumInit.init();
  }
}
