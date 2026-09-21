import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'wan_auth.dart';

/// AWS Signature Version 4 — presigned-URL signing for the IoT MQTT-over-WSS endpoint. A
/// `camera_api`-local copy of `alerts_api`'s `AwsSigV4.presignWebSocketUrl` (this package can't
/// depend on `alerts_api` — different packages, no shared-utility package exists yet), ported
/// from the same proven source (`testing_utilities/kvs_livestream_test.py`'s
/// `_sigv4_websocket_url`) per this repo's Python-script-is-the-reference convention. No AWS SDK
/// dependency — plain HMAC-SHA256 (`crypto` package).
class AwsSigV4 {
  const AwsSigV4._();

  static List<int> _hmac(List<int> key, String data) =>
      Hmac(sha256, key).convert(utf8.encode(data)).bytes;

  static String _hex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  static String _sha256Hex(String data) => sha256.convert(utf8.encode(data)).toString();

  static List<int> _signingKey(String secretKey, String dateStamp, String region, String service) {
    List<int> key = utf8.encode('AWS4$secretKey');
    key = _hmac(key, dateStamp);
    key = _hmac(key, region);
    key = _hmac(key, service);
    key = _hmac(key, 'aws4_request');
    return key;
  }

  /// Presigns a `wss://` URL for AWS IoT's MQTT-over-WebSocket endpoint (query-string SigV4, not
  /// a header) — mirrors `_sigv4_websocket_url` in the Python reference exactly (same query
  /// param set/order, `iotdevicegateway` service, empty-body payload hash).
  static Uri presignWebSocketUrl({
    required WanAwsCredentials credentials,
    required String endpoint,
    required String region,
    DateTime? now,
  }) {
    const service = 'iotdevicegateway';
    const algorithm = 'AWS4-HMAC-SHA256';
    now = (now ?? DateTime.now()).toUtc();
    final amzDate =
        '${now.year.toString().padLeft(4, '0')}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}'
        'T${now.hour.toString().padLeft(2, '0')}${now.minute.toString().padLeft(2, '0')}${now.second.toString().padLeft(2, '0')}Z';
    final dateStamp = amzDate.substring(0, 8);
    final credentialScope = '$dateStamp/$region/$service/aws4_request';

    final credentialParam = Uri.encodeComponent('${credentials.accessKeyId}/$credentialScope');
    var query =
        'X-Amz-Algorithm=$algorithm'
        '&X-Amz-Credential=$credentialParam'
        '&X-Amz-Date=$amzDate'
        '&X-Amz-SignedHeaders=host';

    const canonicalUri = '/mqtt';
    final payloadHash = _sha256Hex('');
    final canonicalRequest = 'GET\n$canonicalUri\n$query\nhost:$endpoint\n\nhost\n$payloadHash';
    final stringToSign =
        '$algorithm\n$amzDate\n$credentialScope\n${_sha256Hex(canonicalRequest)}';

    final signingKey = _signingKey(credentials.secretKey, dateStamp, region, service);
    final signature = _hex(_hmac(signingKey, stringToSign));

    query += '&X-Amz-Signature=$signature';
    query += '&X-Amz-Security-Token=${Uri.encodeComponent(credentials.sessionToken)}';

    return Uri.parse('wss://$endpoint$canonicalUri?$query');
  }

  /// Signs a POST request with a JSON body — header-based SigV4 (`Authorization` header), the
  /// other flavor alongside [presignWebSocketUrl]'s query-string variant. Added for
  /// `KvsGetMediaClient`'s `POST /getMedia` call (`kinesisvideo` service — **not**
  /// `kinesis-video-media`; verified directly against real `boto3`/`botocore` traffic before
  /// writing this, since a wrong service-signing name silently produces a rejected signature
  /// with no useful error otherwise: `botocore`'s own `ClientModel.signing_name` for the
  /// `kinesis-video-media` boto3 client is `kinesisvideo`, and a captured real request confirmed
  /// the exact canonical-header set (`content-type;host;x-amz-date[;x-amz-security-token]` —
  /// note `x-amz-security-token` **is** part of `SignedHeaders` whenever a session token is
  /// present, unlike some other AWS SDKs' behavior) and body-hash placement below).
  ///
  /// Returns the full header map to send with the request — caller still owns constructing and
  /// sending the actual HTTP request (this package uses `package:http`'s streamed-response API
  /// for `GetMedia` specifically, since the response body is an unbounded live byte stream, not
  /// a normal buffered response).
  static Map<String, String> signJsonPost({
    required WanAwsCredentials credentials,
    required String host,
    required String path,
    required String region,
    required String service,
    required List<int> bodyBytes,
    DateTime? now,
  }) {
    const algorithm = 'AWS4-HMAC-SHA256';
    now = (now ?? DateTime.now()).toUtc();
    final amzDate =
        '${now.year.toString().padLeft(4, '0')}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}'
        'T${now.hour.toString().padLeft(2, '0')}${now.minute.toString().padLeft(2, '0')}${now.second.toString().padLeft(2, '0')}Z';
    final dateStamp = amzDate.substring(0, 8);
    final credentialScope = '$dateStamp/$region/$service/aws4_request';

    final headers = <String, String>{
      'content-type': 'application/json',
      'host': host,
      'x-amz-date': amzDate,
      if (credentials.sessionToken.isNotEmpty) 'x-amz-security-token': credentials.sessionToken,
    };
    final signedHeaderNames = headers.keys.toList()..sort();
    final canonicalHeaders =
        signedHeaderNames.map((k) => '$k:${headers[k]}\n').join();
    final signedHeadersList = signedHeaderNames.join(';');
    final payloadHash = sha256.convert(bodyBytes).toString();

    final canonicalRequest =
        'POST\n$path\n\n$canonicalHeaders\n$signedHeadersList\n$payloadHash';
    final stringToSign =
        '$algorithm\n$amzDate\n$credentialScope\n${_sha256Hex(canonicalRequest)}';

    final signingKey = _signingKey(credentials.secretKey, dateStamp, region, service);
    final signature = _hex(_hmac(signingKey, stringToSign));

    return {
      ...headers,
      'Authorization': '$algorithm Credential=${credentials.accessKeyId}/$credentialScope, '
          'SignedHeaders=$signedHeadersList, Signature=$signature',
    };
  }
}
