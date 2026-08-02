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
}
