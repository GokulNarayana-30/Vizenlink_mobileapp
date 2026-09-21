import 'dart:convert';

import 'package:camera_api/src/wan/aws_sigv4.dart';
import 'package:camera_api/src/wan/wan_auth.dart';
import 'package:crypto/crypto.dart';
import 'package:test/test.dart';

List<int> _hmac(List<int> key, String data) =>
    Hmac(sha256, key).convert(utf8.encode(data)).bytes;

void main() {
  final creds = WanAwsCredentials(
    accessKeyId: 'AKIDEXAMPLE',
    secretKey: 'wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY',
    sessionToken: 'TOKEN',
  );
  final now = DateTime.utc(2026, 9, 21, 12, 30, 45);
  final body = utf8.encode('{"StreamName":"s"}');

  String expectedSignature(String service) {
    final payloadHash = sha256.convert(body).toString();
    const headers =
        'content-type:application/json\nhost:s-x.kinesisvideo.ap-south-1.amazonaws.com\n'
        'x-amz-date:20260921T123045Z\nx-amz-security-token:TOKEN\n';
    const signed = 'content-type;host;x-amz-date;x-amz-security-token';
    final canonical = 'POST\n/getMedia\n\n$headers\n$signed\n$payloadHash';
    final scope = '20260921/ap-south-1/$service/aws4_request';
    final sts =
        'AWS4-HMAC-SHA256\n20260921T123045Z\n$scope\n${sha256.convert(utf8.encode(canonical))}';
    var k = _hmac(utf8.encode('AWS4${creds.secretKey}'), '20260921');
    k = _hmac(k, 'ap-south-1');
    k = _hmac(k, service);
    k = _hmac(k, 'aws4_request');
    return Hmac(sha256, k).convert(utf8.encode(sts)).toString();
  }

  Map<String, String> sign(String service) => AwsSigV4.signJsonPost(
    credentials: creds,
    host: 's-x.kinesisvideo.ap-south-1.amazonaws.com',
    path: '/getMedia',
    region: 'ap-south-1',
    service: service,
    bodyBytes: body,
    now: now,
  );

  test(
    'signature matches an independent SigV4 computation for service kinesisvideo',
    () {
      final h = sign('kinesisvideo');
      expect(
        h['Authorization'],
        'AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20260921/ap-south-1/kinesisvideo/aws4_request, '
        'SignedHeaders=content-type;host;x-amz-date;x-amz-security-token, '
        'Signature=${expectedSignature('kinesisvideo')}',
      );
      expect(h['x-amz-date'], '20260921T123045Z');
      expect(h['x-amz-security-token'], 'TOKEN');
      expect(h['host'], 's-x.kinesisvideo.ap-south-1.amazonaws.com');
    },
  );

  test(
    'a different service name yields a different signature (wrong service fails silently at AWS)',
    () {
      expect(
        sign('kinesisvideo')['Authorization'],
        isNot(sign('kinesis')['Authorization']),
      );
    },
  );

  test('empty session token is omitted from signed headers', () {
    final h = AwsSigV4.signJsonPost(
      credentials: WanAwsCredentials(
        accessKeyId: 'A',
        secretKey: 'S',
        sessionToken: '',
      ),
      host: 'h',
      path: '/p',
      region: 'r',
      service: 'x',
      bodyBytes: body,
      now: now,
    );
    expect(h.containsKey('x-amz-security-token'), isFalse);
    expect(
      h['Authorization'],
      contains('SignedHeaders=content-type;host;x-amz-date,'),
    );
  });
}
