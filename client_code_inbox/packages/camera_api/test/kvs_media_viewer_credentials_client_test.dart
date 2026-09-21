import 'dart:convert';

import 'package:camera_api/src/wan/kvs_media/kvs_media_viewer_credentials_client.dart';
import 'package:camera_api/src/wan/wan_auth.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  setUp(() => WanAuth.kvsPlaybackLambdaUrl = 'https://lambda.example.com/');
  tearDown(() => WanAuth.kvsPlaybackLambdaUrl = null);

  test(
    'sends bearer token + mode=media and parses the vended credentials',
    () async {
      late http.Request seen;
      final client = KvsMediaViewerCredentialsClient(
        idTokenProvider: () => 'id-token',
        client: MockClient((req) async {
          seen = req;
          return http.Response(
            jsonEncode({
              'accessKeyId': 'AKIA',
              'secretAccessKey': 'sec',
              'sessionToken': 'tok',
              'expiration': '2026-09-21T12:00:00Z',
              'region': 'ap-south-1',
              'dataEndpoint':
                  'https://s-x.kinesisvideo.ap-south-1.amazonaws.com',
            }),
            200,
          );
        }),
      );
      final c = await client.getCredentials('VZL-CAM-000001-high');
      expect(seen.headers['Authorization'], 'Bearer id-token');
      expect(seen.url.queryParameters, {
        'streamName': 'VZL-CAM-000001-high',
        'mode': 'media',
      });
      expect(c.accessKeyId, 'AKIA');
      expect(c.expiration.isUtc, isTrue);
      expect(c.toWanAwsCredentials().sessionToken, 'tok');
    },
  );

  test('throws StateError when unauthenticated', () {
    final client = KvsMediaViewerCredentialsClient(
      idTokenProvider: () => null,
      client: MockClient((_) async => http.Response('{}', 200)),
    );
    expect(client.getCredentials('s'), throwsStateError);
  });

  test('non-200 surfaces the Lambda error message', () {
    final client = KvsMediaViewerCredentialsClient(
      idTokenProvider: () => 't',
      client: MockClient(
        (_) async =>
            http.Response(jsonEncode({'error': 'no such stream'}), 404),
      ),
    );
    expect(
      client.getCredentials('s'),
      throwsA(predicate((e) => e.toString().contains('no such stream'))),
    );
  });

  group('isExpiringSoon', () {
    KvsMediaViewerCredentials at(Duration fromNow) => KvsMediaViewerCredentials(
      accessKeyId: 'a',
      secretAccessKey: 's',
      sessionToken: 't',
      expiration: DateTime.now().toUtc().add(fromNow),
      region: 'r',
      dataEndpoint: 'e',
    );
    test('false well before expiry, true inside the margin and after', () {
      expect(at(const Duration(minutes: 10)).isExpiringSoon(), isFalse);
      expect(at(const Duration(seconds: 30)).isExpiringSoon(), isTrue);
      expect(at(const Duration(seconds: -5)).isExpiringSoon(), isTrue);
      expect(
        at(
          const Duration(seconds: 30),
        ).isExpiringSoon(margin: const Duration(seconds: 10)),
        isFalse,
      );
    });
  });
}
