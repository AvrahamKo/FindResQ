import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/auth/auth_state.dart';
import 'core/providers.dart';
import 'ui/screens/join_screen.dart';
import 'ui/screens/login_screen.dart';

class LifeSearchApp extends ConsumerWidget {
  const LifeSearchApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Native libsodium must finish loading (native-assets build hooks)
    // before any crypto-dependent provider (auth, device identity) can be
    // read -- see core/providers.dart's sodiumProvider.
    final sodium = ref.watch(sodiumProvider);

    return MaterialApp(
      title: 'LifeSearch',
      theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
      home: sodium.when(
        data: (_) => const _AppRoot(),
        loading: () => const _SplashScreen(),
        error: (error, stackTrace) => _StartupErrorScreen(error: error),
      ),
    );
  }
}

class _AppRoot extends ConsumerStatefulWidget {
  const _AppRoot();

  @override
  ConsumerState<_AppRoot> createState() => _AppRootState();
}

class _AppRootState extends ConsumerState<_AppRoot> {
  @override
  void initState() {
    super.initState();
    Future.microtask(() => ref.read(authControllerProvider.notifier).restore());
  }

  @override
  Widget build(BuildContext context) {
    final authState = ref.watch(authControllerProvider);

    return switch (authState) {
      AuthSignedIn() => const JoinScreen(),
      AuthUnknown() => const _SplashScreen(),
      _ => const LoginScreen(),
    };
  }
}

class _SplashScreen extends StatelessWidget {
  const _SplashScreen();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(body: Center(child: CircularProgressIndicator()));
  }
}

class _StartupErrorScreen extends StatelessWidget {
  final Object error;
  const _StartupErrorScreen({required this.error});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text('Failed to start: $error', textAlign: TextAlign.center),
        ),
      ),
    );
  }
}
