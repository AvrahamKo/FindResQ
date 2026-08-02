/// Thin HTTP client for the LifeSearch backend.
///
/// Deliberately stateless with respect to auth: every method that needs a
/// bearer token takes it as an explicit parameter, rather than the client
/// holding "the current token" as mutable internal state. Callers (the
/// auth/join controllers) own token lifecycle; this class only ever
/// translates one HTTP call into a typed result or a typed exception.
///
/// Every request carries [_requestTimeout]. Without it, a misconfigured
/// [baseUrl] pointing at an address that silently never responds (e.g. the
/// Android-emulator-only `10.0.2.2` alias used on a desktop build) hangs the
/// calling UI forever with no error and nothing ever reaching the server to
/// log -- exactly indistinguishable from "the app is broken." A bounded
/// timeout turns that into a clear, catchable [ApiProtocolException].
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'api_exception.dart';
import 'api_models.dart';

const _requestTimeout = Duration(seconds: 15);

class ApiClient {
  final String baseUrl;
  final http.Client _http;

  ApiClient({required this.baseUrl, http.Client? httpClient})
    : _http = httpClient ?? http.Client();

  Uri _uri(String path) => Uri.parse('$baseUrl$path');

  Map<String, String> _headers({String? bearerToken}) => {
    'Content-Type': 'application/json',
    if (bearerToken != null) 'Authorization': 'Bearer $bearerToken',
  };

  Future<http.Response> _get(String path, {String? bearerToken}) => _http
      .get(_uri(path), headers: _headers(bearerToken: bearerToken))
      .timeout(_requestTimeout, onTimeout: () => _timeoutError(path));

  Future<http.Response> _post(
    String path, {
    String? bearerToken,
    Object? body,
  }) => _http
      .post(
        _uri(path),
        headers: _headers(bearerToken: bearerToken),
        body: body == null ? null : jsonEncode(body),
      )
      .timeout(_requestTimeout, onTimeout: () => _timeoutError(path));

  Never _timeoutError(String path) => throw ApiProtocolException(
    'No response from $baseUrl$path within ${_requestTimeout.inSeconds}s. '
    'Check that the backend is reachable at this address from this device '
    '(see main.dart\'s API_BASE_URL handling for platform-specific defaults).',
  );

  /// Sends the request, decodes a 2xx JSON body, or throws [ApiException]
  /// (backend's `{"error": {code, message}}` envelope) / [ApiProtocolException]
  /// (anything else -- a proxy error page, an empty body, etc).
  Map<String, dynamic> _decodeObject(http.Response response) {
    final decoded = _decodeBody(response);
    if (decoded is! Map<String, dynamic>) {
      throw ApiProtocolException(
        'expected a JSON object, got ${decoded.runtimeType}',
      );
    }
    return decoded;
  }

  List<dynamic> _decodeList(http.Response response) {
    final decoded = _decodeBody(response);
    if (decoded is! List<dynamic>) {
      throw ApiProtocolException(
        'expected a JSON array, got ${decoded.runtimeType}',
      );
    }
    return decoded;
  }

  dynamic _decodeBody(http.Response response) {
    dynamic body;
    try {
      body = response.body.isEmpty ? null : jsonDecode(response.body);
    } on FormatException catch (e) {
      throw ApiProtocolException('response body was not valid JSON: $e');
    }

    if (response.statusCode >= 200 && response.statusCode < 300) {
      return body;
    }

    if (body is Map<String, dynamic> && body['error'] is Map) {
      final error = body['error'] as Map;
      throw ApiException(
        statusCode: response.statusCode,
        code: (error['code'] as String?) ?? 'unknown',
        message: (error['message'] as String?) ?? 'no message provided',
      );
    }

    throw ApiProtocolException(
      'HTTP ${response.statusCode} with an unexpected body shape: ${response.body}',
    );
  }

  // --- Auth (Phase 1) ---------------------------------------------------

  Future<OtpRequestResult> requestOtp(String phoneE164) async {
    final response = await _post(
      '/auth/otp/request',
      body: {'phone_e164': phoneE164},
    );
    return OtpRequestResult.fromJson(_decodeObject(response));
  }

  Future<AuthTokenResult> verifyOtp({
    required String challengeId,
    required String code,
    required String displayName,
  }) async {
    final response = await _post(
      '/auth/otp/verify',
      body: {
        'challenge_id': challengeId,
        'code': code,
        'display_name': displayName,
      },
    );
    return AuthTokenResult.fromJson(_decodeObject(response));
  }

  Future<UserInfo> getMe(String accountToken) async {
    final response = await _get('/auth/me', bearerToken: accountToken);
    return UserInfo.fromJson(_decodeObject(response));
  }

  // --- Devices (Phase 1) -------------------------------------------------

  Future<KeyChallengeResult> createDeviceKeyChallenge(
    String accountToken,
  ) async {
    final response = await _post(
      '/devices/key-challenge',
      bearerToken: accountToken,
    );
    return KeyChallengeResult.fromJson(_decodeObject(response));
  }

  Future<DeviceInfo> registerDevice({
    required String accountToken,
    required String challengeId,
    required String publicKeyBase64,
    required String signatureBase64,
    required String platform,
    String? label,
  }) async {
    final response = await _post(
      '/devices',
      bearerToken: accountToken,
      body: {
        'challenge_id': challengeId,
        'public_key': publicKeyBase64,
        'signature': signatureBase64,
        'platform': platform,
        // NOT `?'label': label` -- that null-checks the KEY ('label', a
        // literal, never null), not the value, and would always include
        // the entry. Confirmed by direct testing after the analyzer
        // suggested it and it silently changed this endpoint's behavior.
        if (label != null) 'label': label,
      },
    );
    return DeviceInfo.fromJson(_decodeObject(response));
  }

  Future<List<DeviceInfo>> listDevices(String accountToken) async {
    final response = await _get('/devices', bearerToken: accountToken);
    return _decodeList(
      response,
    ).map((e) => DeviceInfo.fromJson(e as Map<String, dynamic>)).toList();
  }

  // --- Join / membership (Phase 2) ---------------------------------------

  Future<JoinResult> joinSector({
    required String accountToken,
    required String code,
    required String deviceId,
    required String movementMode,
    required int batteryPct,
    required bool powerbankAttested,
  }) async {
    final response = await _post(
      '/join',
      bearerToken: accountToken,
      body: {
        'code': code,
        'device_id': deviceId,
        'movement_mode': movementMode,
        'battery_pct': batteryPct,
        'powerbank_attested': powerbankAttested,
      },
    );
    return JoinResult.fromJson(_decodeObject(response));
  }

  Future<MembershipInfo> getMembership({
    required String accountToken,
    required String membershipId,
  }) async {
    final response = await _get(
      '/memberships/$membershipId',
      bearerToken: accountToken,
    );
    return MembershipInfo.fromJson(_decodeObject(response));
  }

  Future<SessionIssueResult> claimSession({
    required String accountToken,
    required String membershipId,
  }) async {
    final response = await _post(
      '/memberships/$membershipId/session',
      bearerToken: accountToken,
    );
    return SessionIssueResult.fromJson(_decodeObject(response));
  }

  // --- Ingest (Phase 3 endpoint, Phase 5d client) -------------------------

  /// Uploads a batch of already-encrypted telemetry blobs (base64) using the
  /// device's SECTOR SESSION token, not the account token -- this is the
  /// direct-upload path, authenticated as "this device, in this sector"
  /// (see `backend/app/api/routes/ingest.py`'s module docstring).
  Future<IngestResult> ingest({
    required String sessionToken,
    required List<String> blobs,
  }) async {
    final response = await _post(
      '/ingest',
      bearerToken: sessionToken,
      body: {'blobs': blobs},
    );
    return IngestResult.fromJson(_decodeObject(response));
  }

  void close() => _http.close();
}
