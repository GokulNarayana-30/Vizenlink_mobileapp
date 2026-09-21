import 'dart:convert';

import 'package:camera_api/src/wan/kvs_media/kvs_get_media_client.dart';
import 'package:camera_api/src/wan/kvs_media/kvs_media_viewer_credentials_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

KvsMediaViewerCredentials _creds() => KvsMediaViewerCredentials(
  accessKeyId: 'AKIDEXAMPLE',
  secretAccessKey: 'secret',
  sessionToken: 'tok',
  expiration: DateTime.now().toUtc().add(const Duration(minutes: 10)),
  region: 'ap-south-1',
  dataEndpoint: 'https://s-abc.kinesisvideo.ap-south-1.amazonaws.com',
);

void main() {
  test(
    'POSTs /getMedia to the data endpoint with NOW selector and SigV4 for kinesisvideo',
    () async {
      late http.BaseRequest seen;
      late String body;
      final client = KvsGetMediaClient(
        client: MockClient.streaming((req, bodyStream) async {
          seen = req;
          body = await bodyStream.bytesToString();
          return http.StreamedResponse(Stream.value([1, 2, 3]), 200);
        }),
      );
      final stream = await client.getMedia(
        credentials: _creds(),
        streamName: 'cam-high',
      );
      expect(await stream.expand((e) => e).toList(), [1, 2, 3]);

      expect(seen.method, 'POST');
      expect(seen.url.host, 's-abc.kinesisvideo.ap-south-1.amazonaws.com');
      expect(seen.url.path, '/getMedia');
      expect(jsonDecode(body), {
        'StreamName': 'cam-high',
        'StartSelector': {'StartSelectorType': 'NOW'},
      });
      final auth = seen.headers['Authorization']!;
      expect(auth, contains('/ap-south-1/kinesisvideo/aws4_request'));
      expect(seen.headers['x-amz-security-token'], 'tok');
    },
  );

  test('non-200 response throws with the status and body', () async {
    final client = KvsGetMediaClient(
      client: MockClient.streaming(
        (req, _) async =>
            http.StreamedResponse(Stream.value(utf8.encode('denied')), 403),
      ),
    );
    expect(
      client.getMedia(credentials: _creds(), streamName: 's'),
      throwsA(
        predicate(
          (e) =>
              e.toString().contains('403') && e.toString().contains('denied'),
        ),
      ),
    );
  });
}
