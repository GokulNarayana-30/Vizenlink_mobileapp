import 'dart:convert';

import 'package:http/http.dart' as http;

import '../aws_sigv4.dart';
import 'kvs_media_viewer_credentials_client.dart';

/// Calls AWS KVS's `GetMedia` directly (`POST /getMedia` on the per-stream data endpoint,
/// SigV4-signed with [KvsMediaViewerCredentials]) and returns the raw response as a byte stream
/// — `GetMedia`'s response body is an unbounded, continuously-appended MKV stream (fragments
/// keep arriving as long as the connection stays open), never a fixed-size buffered response, so
/// this uses `package:http`'s streamed-request API rather than an ordinary `get`/`post` call.
///
/// Wire format verified directly against real `boto3`/`botocore` traffic before writing this
/// (captured a real `GetMedia` request/response with a fake endpoint to inspect exactly what
/// headers/body botocore sends — see [AwsSigV4.signJsonPost]'s own doc) rather than assumed from
/// documentation alone.
class KvsGetMediaClient {
  KvsGetMediaClient({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  /// Opens a `GetMedia` connection starting from the live edge (`StartSelectorType: "NOW"` —
  /// the only selector this class supports; KVS's other selectors, e.g. a specific fragment
  /// number or timestamp, are for archived playback, not live view) and returns the raw
  /// response byte stream. The returned [http.StreamedResponse.stream] stays open and keeps
  /// delivering bytes for as long as the camera keeps streaming — callers must cancel their
  /// subscription (or call [http.Client.close]) to actually end the connection; there is no
  /// natural end-of-stream for a live `GetMedia` session.
  Future<Stream<List<int>>> getMedia({
    required KvsMediaViewerCredentials credentials,
    required String streamName,
  }) async {
    final endpointUri = Uri.parse(credentials.dataEndpoint);
    final host = endpointUri.host;
    final path = '/getMedia';
    final bodyMap = {
      'StreamName': streamName,
      'StartSelector': {'StartSelectorType': 'NOW'},
    };
    final bodyBytes = utf8.encode(jsonEncode(bodyMap));

    final headers = AwsSigV4.signJsonPost(
      credentials: credentials.toWanAwsCredentials(),
      host: host,
      path: path,
      region: credentials.region,
      service: 'kinesisvideo',
      bodyBytes: bodyBytes,
    );

    final request = http.Request('POST', Uri(scheme: 'https', host: host, path: path))
      ..headers.addAll(headers)
      ..bodyBytes = bodyBytes;

    final response = await _client.send(request);
    if (response.statusCode != 200) {
      final body = await response.stream.bytesToString();
      throw Exception('GetMedia failed (${response.statusCode}): $body');
    }
    return response.stream;
  }

  void close() => _client.close();
}
