/// Mirrors the backend's error envelope: `{"error": {"code", "message"}}`,
/// rendered by the single `AppError` exception handler in `app/main.py`.
/// Every typed backend error (`Unauthorized`, `Conflict`, `NotFound`, ...)
/// arrives here as one of these, distinguished by [code] and [statusCode].
class ApiException implements Exception {
  final int statusCode;
  final String code;
  final String message;

  const ApiException({
    required this.statusCode,
    required this.code,
    required this.message,
  });

  /// True for the specific, expected "already registered to you" conflict
  /// a device registration retry can hit -- see AuthController's handling.
  bool get isDuplicateDeviceRegistration =>
      statusCode == 409 && code == 'conflict';

  @override
  String toString() => 'ApiException($statusCode $code): $message';
}

/// Thrown when the response body isn't the expected JSON shape at all --
/// a network-level failure, a proxy error page, or a backend that isn't
/// running the version of the API this client expects.
class ApiProtocolException implements Exception {
  final String message;
  const ApiProtocolException(this.message);

  @override
  String toString() => 'ApiProtocolException: $message';
}
