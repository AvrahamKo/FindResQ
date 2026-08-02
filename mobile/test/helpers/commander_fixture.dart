/// Shared E2E fixture: creates a commander account, event, sector, and join
/// code against a REAL running backend, and can approve a membership --
/// everything an E2E test needs to get a real volunteer device from
/// "nothing" to "an active sector session with a real sector key," without
/// going through the controllers under test (those are the code being
/// tested, not the test harness). Used by `auth_join_e2e_test.dart` and
/// `location_sync_e2e_test.dart` so the fixture setup isn't duplicated.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

const baseUrl = 'http://localhost:8000';

const sectorBoundaryGeoJson = {
  'type': 'Polygon',
  'coordinates': [
    [
      [35.20, 31.76],
      [35.20, 31.78],
      [35.24, 31.78],
      [35.24, 31.76],
      [35.20, 31.76],
    ],
  ],
};

Future<bool> backendReachable() async {
  try {
    final response = await http
        .get(Uri.parse('$baseUrl/readyz'))
        .timeout(const Duration(seconds: 3));
    return response.statusCode == 200;
  } on Object {
    return false;
  }
}

String uniquePhone() {
  final suffix = DateTime.now().microsecondsSinceEpoch % 10000000;
  return '+1555${suffix.toString().padLeft(7, '0')}';
}

class CommanderFixture {
  final String accountToken;
  final String eventId;
  final String sectorId;

  const CommanderFixture({
    required this.accountToken,
    required this.eventId,
    required this.sectorId,
  });

  static Future<CommanderFixture> create() async {
    final client = http.Client();

    Future<Map<String, dynamic>> call(
      String method,
      String path, {
      Map<String, dynamic>? body,
      String? token,
    }) async {
      final uri = Uri.parse('$baseUrl$path');
      final headers = {
        'Content-Type': 'application/json',
        if (token != null) 'Authorization': 'Bearer $token',
      };
      final response = method == 'GET'
          ? await client.get(uri, headers: headers)
          : await client.post(
              uri,
              headers: headers,
              body: body == null ? null : jsonEncode(body),
            );
      if (response.statusCode >= 300) {
        fail('fixture setup failed: $method $path -> ${response.statusCode} ${response.body}');
      }
      return response.body.isEmpty
          ? {}
          : jsonDecode(response.body) as Map<String, dynamic>;
    }

    final otp = await call('POST', '/auth/otp/request', body: {
      'phone_e164': uniquePhone(),
    });
    final verify = await call(
      'POST',
      '/auth/otp/verify',
      body: {
        'challenge_id': otp['challenge_id'],
        'code': otp['dev_code'],
        'display_name': 'E2E Commander',
      },
    );
    final accountToken = verify['access_token'] as String;

    final event = await call(
      'POST',
      '/events',
      token: accountToken,
      body: {'name': 'E2E Test Callout'},
    );
    final eventId = event['id'] as String;

    await call('POST', '/events/$eventId/start', token: accountToken);

    final sector = await call(
      'POST',
      '/events/$eventId/sectors',
      token: accountToken,
      body: {'name': 'E2E Test Sector', 'boundary': sectorBoundaryGeoJson},
    );
    final sectorId = sector['id'] as String;

    return CommanderFixture(
      accountToken: accountToken,
      eventId: eventId,
      sectorId: sectorId,
    );
  }

  Future<String> mintJoinCode() async {
    final client = http.Client();
    final response = await client.post(
      Uri.parse('$baseUrl/sectors/$sectorId/join-codes'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $accountToken',
      },
      body: jsonEncode({}),
    );
    if (response.statusCode >= 300) {
      fail('failed to mint join code: ${response.statusCode} ${response.body}');
    }
    return (jsonDecode(response.body) as Map<String, dynamic>)['code'] as String;
  }

  Future<void> approve(String membershipId) async {
    final client = http.Client();
    final response = await client.post(
      Uri.parse('$baseUrl/memberships/$membershipId/approve'),
      headers: {'Authorization': 'Bearer $accountToken'},
    );
    if (response.statusCode >= 300) {
      fail('failed to approve membership: ${response.statusCode} ${response.body}');
    }
  }
}
