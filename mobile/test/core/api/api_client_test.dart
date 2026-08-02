import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lifesearch_mobile/core/api/api_client.dart';
import 'package:lifesearch_mobile/core/api/api_exception.dart';

ApiClient _clientReturning(http.Response Function(http.Request) handler) {
  return ApiClient(
    baseUrl: 'http://test.invalid',
    httpClient: MockClient((request) async => handler(request)),
  );
}

http.Response _json(Object body, int status) =>
    http.Response(jsonEncode(body), status, headers: {
      'content-type': 'application/json',
    });

void main() {
  group('requestOtp', () {
    test('sends the phone number and parses the response', () async {
      http.Request? captured;
      final client = _clientReturning((request) {
        captured = request;
        return _json({
          'challenge_id': 'c1',
          'expires_at': '2030-01-01T00:00:00Z',
          'dev_code': '123456',
        }, 201);
      });

      final result = await client.requestOtp('+15551234567');

      expect(captured!.url.path, equals('/auth/otp/request'));
      expect(
        jsonDecode(captured!.body),
        equals({'phone_e164': '+15551234567'}),
      );
      expect(result.challengeId, equals('c1'));
      expect(result.devCode, equals('123456'));
    });
  });

  group('verifyOtp', () {
    test('parses the account token and user', () async {
      final client = _clientReturning(
        (request) => _json({
          'access_token': 'tok',
          'token_type': 'Bearer',
          'expires_at': '2030-01-01T00:00:00Z',
          'user': {
            'id': 'u1',
            'phone_e164': '+15551234567',
            'display_name': 'Test',
            'verification_status': 'unverified',
          },
        }, 200),
      );

      final result = await client.verifyOtp(
        challengeId: 'c1',
        code: '123456',
        displayName: 'Test',
      );

      expect(result.accessToken, equals('tok'));
      expect(result.user.id, equals('u1'));
    });
  });

  group('registerDevice', () {
    test('omits the label field entirely when null', () async {
      http.Request? captured;
      final client = _clientReturning((request) {
        captured = request;
        return _json({
          'id': 'device-1',
          'wire_id': 1,
          'public_key': 'pub==',
          'platform': 'android',
          'mesh_capable': true,
          'label': null,
          'registered_at': '2030-01-01T00:00:00Z',
          'revoked_at': null,
        }, 201);
      });

      await client.registerDevice(
        accountToken: 'tok',
        challengeId: 'c1',
        publicKeyBase64: 'pub==',
        signatureBase64: 'sig==',
        platform: 'android',
      );

      final body = jsonDecode(captured!.body) as Map<String, dynamic>;
      expect(
        body.containsKey('label'),
        isFalse,
        reason:
            'a null label must be OMITTED from the request body, not sent '
            'as an explicit "label": null entry',
      );
    });

    test('includes the label field when provided', () async {
      http.Request? captured;
      final client = _clientReturning((request) {
        captured = request;
        return _json({
          'id': 'device-1',
          'wire_id': 1,
          'public_key': 'pub==',
          'platform': 'android',
          'mesh_capable': true,
          'label': 'My Phone',
          'registered_at': '2030-01-01T00:00:00Z',
          'revoked_at': null,
        }, 201);
      });

      await client.registerDevice(
        accountToken: 'tok',
        challengeId: 'c1',
        publicKeyBase64: 'pub==',
        signatureBase64: 'sig==',
        platform: 'android',
        label: 'My Phone',
      );

      final body = jsonDecode(captured!.body) as Map<String, dynamic>;
      expect(body['label'], equals('My Phone'));
    });
  });

  group('error handling', () {
    test('a typed backend error decodes into ApiException', () async {
      final client = _clientReturning(
        (request) => _json({
          'error': {'code': 'unauthorized', 'message': 'invalid or expired code'},
        }, 401),
      );

      await expectLater(
        client.verifyOtp(challengeId: 'c1', code: '000000', displayName: ''),
        throwsA(
          isA<ApiException>()
              .having((e) => e.statusCode, 'statusCode', 401)
              .having((e) => e.code, 'code', 'unauthorized')
              .having((e) => e.message, 'message', 'invalid or expired code'),
        ),
      );
    });

    test('a 409 conflict is flagged as a duplicate device registration', () async {
      final client = _clientReturning(
        (request) => _json({
          'error': {
            'code': 'conflict',
            'message': 'this device key is already registered to you',
          },
        }, 409),
      );

      try {
        await client.registerDevice(
          accountToken: 'tok',
          challengeId: 'c1',
          publicKeyBase64: 'pub==',
          signatureBase64: 'sig==',
          platform: 'android',
        );
        fail('expected ApiException');
      } on ApiException catch (e) {
        expect(e.isDuplicateDeviceRegistration, isTrue);
      }
    });

    test('a non-JSON body raises ApiProtocolException, not a crash', () async {
      final client = ApiClient(
        baseUrl: 'http://test.invalid',
        httpClient: MockClient(
          (request) async =>
              http.Response('<html>502 Bad Gateway</html>', 502),
        ),
      );

      await expectLater(
        client.requestOtp('+15551234567'),
        throwsA(isA<ApiProtocolException>()),
      );
    });
  });

  group('authenticated requests', () {
    test('attaches the bearer token', () async {
      http.Request? captured;
      final client = _clientReturning((request) {
        captured = request;
        return _json({
          'challenge_id': 'c1',
          'nonce': 'bm9uY2U=',
          'expires_at': '2030-01-01T00:00:00Z',
        }, 201);
      });

      await client.createDeviceKeyChallenge('account-token-123');

      expect(
        captured!.headers['Authorization'],
        equals('Bearer account-token-123'),
      );
    });
  });

  group('ingest', () {
    test('sends blobs and the session bearer token, parses counts', () async {
      http.Request? captured;
      final client = _clientReturning((request) {
        captured = request;
        return _json({
          'accepted': 2,
          'duplicate': 1,
          'decrypt_failed': 0,
          'signature_invalid': 0,
          'wrong_device': 0,
          'malformed': 0,
          'segments_opened': 1,
          'segments_extended': 0,
          'segments_closed': 0,
          'hexes_touched': 3,
        }, 200);
      });

      final result = await client.ingest(
        sessionToken: 'session-tok',
        blobs: ['YmxvYjE=', 'YmxvYjI='],
      );

      expect(captured!.url.path, equals('/ingest'));
      expect(captured!.headers['Authorization'], equals('Bearer session-tok'));
      expect(
        jsonDecode(captured!.body),
        equals({'blobs': ['YmxvYjE=', 'YmxvYjI=']}),
      );
      expect(result.accepted, equals(2));
      expect(result.duplicate, equals(1));
      expect(result.rejected, equals(1));
      expect(result.hexesTouched, equals(3));
    });

    test('a 401 (e.g. expired session) surfaces as ApiException', () async {
      final client = _clientReturning(
        (request) => _json({
          'error': {'code': 'unauthorized', 'message': 'session expired'},
        }, 401),
      );

      await expectLater(
        client.ingest(sessionToken: 'stale-tok', blobs: ['YmxvYg==']),
        throwsA(isA<ApiException>().having((e) => e.statusCode, 'statusCode', 401)),
      );
    });
  });

  group('claimSession', () {
    test('parses the sector key and sector info', () async {
      final client = _clientReturning(
        (request) => _json({
          'access_token': 'session-tok',
          'token_type': 'Bearer',
          'expires_at': '2030-01-01T00:00:00Z',
          'key_epoch': 1,
          'sector_key': 'a2V5Ynl0ZXM=',
          'sector': {
            'id': 'sector-1',
            'event_id': 'event-1',
            'name': 'North Ridge',
            'status': 'open',
          },
        }, 200),
      );

      final result = await client.claimSession(
        accountToken: 'tok',
        membershipId: 'm1',
      );

      expect(result.sectorKeyBase64, equals('a2V5Ynl0ZXM='));
      expect(result.sector.name, equals('North Ridge'));
      expect(result.keyEpoch, equals(1));
    });
  });

  group('sos', () {
    Map<String, dynamic> alertJson({
      String status = 'active',
      double? lat = 31.7715,
      double? lng = 35.2170,
    }) => {
      'id': 'alert-1',
      'sector_id': 's1',
      'device_id': 'device-1',
      'user_id': 'u1',
      'status': status,
      'lat': lat,
      'lng': lng,
      'triggered_at': '2030-01-01T00:00:00Z',
      'acknowledged_at': null,
      'acknowledged_by': null,
      'resolved_at': null,
      'resolved_by': null,
      'cancelled_at': null,
      'updated_at': '2030-01-01T00:00:00Z',
    };

    test('triggerSos sends the session bearer token and omits null lat/lng', () async {
      http.Request? captured;
      final client = _clientReturning((request) {
        captured = request;
        return _json(alertJson(), 201);
      });

      final alert = await client.triggerSos(sessionToken: 'session-tok');

      expect(captured!.url.path, equals('/sos'));
      expect(captured!.headers['Authorization'], equals('Bearer session-tok'));
      expect(jsonDecode(captured!.body), equals({}));
      expect(alert.id, equals('alert-1'));
      expect(alert.status, equals('active'));
      expect(alert.isOpen, isTrue);
    });

    test('triggerSos includes lat/lng when provided', () async {
      http.Request? captured;
      final client = _clientReturning((request) {
        captured = request;
        return _json(alertJson(), 201);
      });

      await client.triggerSos(sessionToken: 'session-tok', lat: 31.77, lng: 35.21);

      expect(
        jsonDecode(captured!.body),
        equals({'lat': 31.77, 'lng': 35.21}),
      );
    });

    test('cancelSos posts to the alert-scoped endpoint', () async {
      http.Request? captured;
      final client = _clientReturning((request) {
        captured = request;
        return _json(alertJson(status: 'cancelled'), 200);
      });

      final alert = await client.cancelSos(sessionToken: 'session-tok', alertId: 'alert-1');

      expect(captured!.url.path, equals('/sos/alert-1/cancel'));
      expect(alert.status, equals('cancelled'));
      expect(alert.isOpen, isFalse);
    });

    test('listSectorSos parses a list with the account bearer token', () async {
      http.Request? captured;
      final client = _clientReturning((request) {
        captured = request;
        return http.Response(
          jsonEncode([alertJson(), alertJson(status: 'resolved')]),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      final alerts = await client.listSectorSos(accountToken: 'acct-tok', sectorId: 's1');

      expect(captured!.url.path, equals('/sectors/s1/sos'));
      expect(captured!.headers['Authorization'], equals('Bearer acct-tok'));
      expect(alerts, hasLength(2));
      expect(alerts[1].status, equals('resolved'));
    });

    test('acknowledgeSos and resolveSos hit the right endpoints', () async {
      final requests = <String>[];
      final client = _clientReturning((request) {
        requests.add(request.url.path);
        return _json(alertJson(status: 'acknowledged'), 200);
      });

      await client.acknowledgeSos(accountToken: 'acct-tok', alertId: 'alert-1');
      await client.resolveSos(accountToken: 'acct-tok', alertId: 'alert-1');

      expect(requests, equals(['/sos/alert-1/acknowledge', '/sos/alert-1/resolve']));
    });

    test('a 403 from acknowledgeSos (wrong role) surfaces as ApiException', () async {
      final client = _clientReturning(
        (request) => _json({
          'error': {'code': 'forbidden', 'message': 'only this sector\'s lead or the event\'s commander can do this'},
        }, 403),
      );

      await expectLater(
        client.acknowledgeSos(accountToken: 'tok', alertId: 'alert-1'),
        throwsA(isA<ApiException>().having((e) => e.statusCode, 'statusCode', 403)),
      );
    });
  });

  group('reports', () {
    Map<String, dynamic> reportJson({
      String status = 'open',
      String? note = 'Test note',
    }) => {
      'id': 'report-1',
      'sector_id': 's1',
      'device_id': 'device-1',
      'user_id': 'u1',
      'kind': 'hazard',
      'lat': 31.7715,
      'lng': 35.2170,
      'note': note,
      'recorded_at': '2030-01-01T00:00:00Z',
      'received_at': '2030-01-01T00:00:01Z',
      'delivery_path': 'direct',
      'status': status,
      'acknowledged_by': null,
      'acknowledged_at': null,
      'updated_at': '2030-01-01T00:00:01Z',
    };

    test('submitReports sends blobs and the session bearer token', () async {
      http.Request? captured;
      final client = _clientReturning((request) {
        captured = request;
        return _json({
          'accepted': 1,
          'duplicate': 0,
          'decrypt_failed': 0,
          'signature_invalid': 0,
          'wrong_device': 0,
          'malformed': 0,
        }, 200);
      });

      final result = await client.submitReports(
        sessionToken: 'session-tok',
        blobs: ['YmxvYjE='],
      );

      expect(captured!.url.path, equals('/reports'));
      expect(captured!.headers['Authorization'], equals('Bearer session-tok'));
      expect(
        jsonDecode(captured!.body),
        equals({'blobs': ['YmxvYjE=']}),
      );
      expect(result.accepted, equals(1));
    });

    test('listSectorReports parses a list with the account bearer token', () async {
      http.Request? captured;
      final client = _clientReturning((request) {
        captured = request;
        return http.Response(
          jsonEncode([reportJson(), reportJson(status: 'acknowledged')]),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      final reports = await client.listSectorReports(
        accountToken: 'acct-tok',
        sectorId: 's1',
      );

      expect(captured!.url.path, equals('/sectors/s1/reports'));
      expect(captured!.headers['Authorization'], equals('Bearer acct-tok'));
      expect(reports, hasLength(2));
      expect(reports[0].note, equals('Test note'));
      expect(reports[1].status, equals('acknowledged'));
    });

    test('acknowledgeReport posts to the report-scoped endpoint', () async {
      http.Request? captured;
      final client = _clientReturning((request) {
        captured = request;
        return _json(reportJson(status: 'acknowledged'), 200);
      });

      final report = await client.acknowledgeReport(
        accountToken: 'acct-tok',
        reportId: 'report-1',
      );

      expect(captured!.url.path, equals('/reports/report-1/acknowledge'));
      expect(report.status, equals('acknowledged'));
    });

    test('a null note parses to null, not the string "null"', () async {
      final client = _clientReturning((r) => _json(reportJson(note: null), 200));

      final report = await client.acknowledgeReport(
        accountToken: 'acct-tok',
        reportId: 'report-1',
      );

      expect(report.note, isNull);
    });

    test('a 403 from listSectorReports (not a sector member) surfaces as ApiException', () async {
      final client = _clientReturning(
        (request) => _json({
          'error': {'code': 'forbidden', 'message': 'you have no role in this sector'},
        }, 403),
      );

      await expectLater(
        client.listSectorReports(accountToken: 'tok', sectorId: 's1'),
        throwsA(isA<ApiException>().having((e) => e.statusCode, 'statusCode', 403)),
      );
    });
  });
}
