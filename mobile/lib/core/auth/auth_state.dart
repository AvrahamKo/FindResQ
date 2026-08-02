import '../api/api_models.dart';

/// Sealed so the UI can exhaustively switch over every phase of the auth
/// flow -- phone entry, OTP entry, device registration, signed in.
sealed class AuthState {
  const AuthState();
}

/// Still checking Secure Storage for an existing, unexpired account. The
/// UI should show a splash/loading state, not the phone entry screen, to
/// avoid a flash of "signed out" on every cold start.
class AuthUnknown extends AuthState {
  const AuthUnknown();
}

class AuthSignedOut extends AuthState {
  const AuthSignedOut();
}

class AuthRequestingOtp extends AuthState {
  final String phoneE164;
  const AuthRequestingOtp(this.phoneE164);
}

class AuthOtpSent extends AuthState {
  final String phoneE164;
  final String challengeId;
  final DateTime expiresAt;

  /// Local-only convenience: only ever set when the backend runs with
  /// ENV=local, so development doesn't require a real SMS provider.
  final String? devCode;

  const AuthOtpSent({
    required this.phoneE164,
    required this.challengeId,
    required this.expiresAt,
    this.devCode,
  });
}

class AuthVerifyingOtp extends AuthState {
  final String phoneE164;
  final String challengeId;
  const AuthVerifyingOtp({required this.phoneE164, required this.challengeId});
}

class AuthRegisteringDevice extends AuthState {
  const AuthRegisteringDevice();
}

class AuthSignedIn extends AuthState {
  final UserInfo user;
  final String deviceId;
  const AuthSignedIn({required this.user, required this.deviceId});
}

class AuthFailed extends AuthState {
  final String message;

  /// The state to fall back to (usually where the user can retry from) --
  /// lets the UI show an error without losing e.g. the phone number or
  /// challenge id already entered.
  final AuthState previous;

  const AuthFailed({required this.message, required this.previous});
}
