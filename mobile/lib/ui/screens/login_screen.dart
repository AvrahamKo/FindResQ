import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/auth_state.dart';
import '../../core/providers.dart';
import 'otp_entry_view.dart';
import 'phone_entry_view.dart';

/// Renders whichever sub-view matches the current [AuthState] -- phone
/// entry, OTP entry, or a brief "registering device" spinner between
/// verifying the code and being fully signed in.
class LoginScreen extends ConsumerWidget {
  const LoginScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(authControllerProvider);

    return switch (state) {
      AuthOtpSent(
        :final phoneE164,
        :final devCode,
      ) =>
        OtpEntryView(phoneE164: phoneE164, devCode: devCode, isVerifying: false),
      AuthVerifyingOtp(:final phoneE164) =>
        OtpEntryView(phoneE164: phoneE164, isVerifying: true),
      AuthRegisteringDevice() => const _RegisteringDeviceView(),
      AuthFailed(previous: AuthOtpSent(:final phoneE164, :final devCode), :final message) =>
        OtpEntryView(
          phoneE164: phoneE164,
          devCode: devCode,
          isVerifying: false,
          errorMessage: message,
        ),
      AuthFailed(:final message) => PhoneEntryView(
          isSubmitting: false,
          errorMessage: message,
        ),
      AuthRequestingOtp() => const PhoneEntryView(isSubmitting: true),
      _ => const PhoneEntryView(isSubmitting: false),
    };
  }
}

class _RegisteringDeviceView extends StatelessWidget {
  const _RegisteringDeviceView();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('Setting up this device...'),
          ],
        ),
      ),
    );
  }
}
