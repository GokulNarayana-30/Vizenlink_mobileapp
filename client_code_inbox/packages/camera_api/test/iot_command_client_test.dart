import 'package:camera_api/camera_api.dart';
import 'package:test/test.dart';

class _FakeTransport implements IotTransport {
  final List<Map<String, dynamic>> published = [];
  final List<Map<String, dynamic>> publishedAndWaited = [];

  /// Every `timeout` this transport was actually handed, in call order — backs the
  /// timeout-pass-through tests below (2026-09-15 fix: a caller-supplied timeout used to be
  /// silently dropped by callers like `WanDeviceIdentityClient.getDeviceIdentity`).
  final List<Duration> timeouts = [];

  /// Queue of responses `publishAndWait` returns, in call order — `null` means "no reply"
  /// (timeout). Defaults to a single `{"status": "ok"}` reply if left empty.
  final List<Map<String, dynamic>?> replies = [];

  @override
  Future<void> publish(String thingName, Map<String, dynamic> body) async {
    published.add(body);
  }

  @override
  Future<Map<String, dynamic>?> publishAndWait(
    String thingName,
    Map<String, dynamic> body, {
    Duration timeout = const Duration(seconds: 12),
  }) async {
    publishedAndWaited.add(body);
    timeouts.add(timeout);
    if (replies.isEmpty) return {'status': 'ok'};
    return replies.removeAt(0);
  }
}

void main() {
  test(
    'sendStartCloudStreaming (FR-CF-154) goes through publishAndWait with params.quality, '
    'returns the reply',
    () async {
      final transport = _FakeTransport()
        ..replies.add({
          'status': 'ok',
          'output': {'token': 42, 'quality': 'high'},
        });
      final client = IotCommandClient('VZL-CAM-000001', transport: transport);

      final reply = await client.sendStartCloudStreaming('high');

      expect(transport.publishedAndWaited.single['command'], IotCommandClient.startCloudStreaming);
      expect(transport.publishedAndWaited.single['params'], {'quality': 'high'});
      expect(reply, {'token': 42, 'quality': 'high'});
    },
  );

  test('sendStopCloudStreaming publishes command=1 with params.token when given', () async {
    final transport = _FakeTransport();
    final client = IotCommandClient('VZL-CAM-000001', transport: transport);

    await client.sendStopCloudStreaming(token: 42);

    expect(transport.published, [
      {
        'command': IotCommandClient.stopCloudStreaming,
        'params': {'token': 42},
      },
    ]);
  });

  test('sendStopCloudStreaming with no token omits params (legacy stop-everything)', () async {
    final transport = _FakeTransport();
    final client = IotCommandClient('VZL-CAM-000001', transport: transport);

    await client.sendStopCloudStreaming();

    expect(transport.published, [
      {'command': IotCommandClient.stopCloudStreaming},
    ]);
  });

  test(
    'getCloudStreamingStatus goes through the generic publishAndWait request/response path '
    '(command=4)',
    () async {
      final transport = _FakeTransport()
        ..replies.add({
          'status': 'ok',
          'output': {'stream_status': 'active'},
        });
      final client = IotCommandClient('VZL-CAM-000001', transport: transport);

      final output = await client.sendCommandWithResponse(IotCommandClient.getCloudStreamingStatus);

      expect(transport.publishedAndWaited.single['command'], IotCommandClient.getCloudStreamingStatus);
      expect(output, {'stream_status': 'active'});
    },
  );

  test('a camera-side failure (status != ok) throws', () async {
    final transport = _FakeTransport()..replies.add({'status': 'error'});
    final client = IotCommandClient('VZL-CAM-000001', transport: transport);

    expect(
      client.sendCommandWithResponse(IotCommandClient.setMirrorFlip),
      throwsA(predicate((e) => e.toString().contains('failed on camera'))),
    );
  });

  test(
    'sendCommandWithResponse includes command+params and returns the output object',
    () async {
      final transport = _FakeTransport()
        ..replies.add({
          'status': 'ok',
          'output': {'type': 'Grey', 'color_capable': true, 'smart_capable': false},
        });
      final client = IotCommandClient('VZL-CAM-000001', transport: transport);

      final output = await client.sendCommandWithResponse(
        IotCommandClient.setNightVisionType,
        params: {'type': 'Grey'},
      );

      final body = transport.publishedAndWaited.single;
      expect(body['command'], IotCommandClient.setNightVisionType);
      expect(body['params'], {'type': 'Grey'});
      expect(body['request_id'], isNotNull);
      expect(output, {'type': 'Grey', 'color_capable': true, 'smart_capable': false});
    },
  );

  test(
    'a timeout (no reply) is retried once — a second-attempt reply succeeds without the '
    'caller ever seeing the timeout',
    () async {
      final transport = _FakeTransport()
        ..replies.add(null)
        ..replies.add({
          'status': 'ok',
          'output': {'mode': 'Both'},
        });
      final client = IotCommandClient('VZL-CAM-000001', transport: transport);

      final output = await client.sendCommandWithResponse(IotCommandClient.getMirrorFlip);

      expect(transport.publishedAndWaited.length, 2);
      expect(output, {'mode': 'Both'});
    },
  );

  test('a second consecutive timeout is not retried again — it is surfaced', () async {
    final transport = _FakeTransport()
      ..replies.add(null)
      ..replies.add(null);
    final client = IotCommandClient('VZL-CAM-000001', transport: transport);

    await expectLater(
      client.sendCommandWithResponse(IotCommandClient.getMirrorFlip),
      throwsA(predicate((e) => e.toString().contains('timed out'))),
    );
    expect(transport.publishedAndWaited.length, 2);
  });

  test('a genuine camera-side failure is not retried', () async {
    final transport = _FakeTransport()..replies.add({'status': 'error'});
    final client = IotCommandClient('VZL-CAM-000001', transport: transport);

    await expectLater(
      client.sendCommandWithResponse(IotCommandClient.setMirrorFlip),
      throwsA(predicate((e) => e.toString().contains('failed on camera'))),
    );
    expect(transport.publishedAndWaited.length, 1);
  });

  test('sendCommandWithResponse omits params entirely when none are given', () async {
    final transport = _FakeTransport()
      ..replies.add({
        'status': 'ok',
        'output': {'type': 'Grey'},
      });
    final client = IotCommandClient('VZL-CAM-000001', transport: transport);

    await client.sendCommandWithResponse(IotCommandClient.getNightVisionType);

    expect(transport.publishedAndWaited.single.containsKey('params'), isFalse);
  });

  test(
    'a successful reply with no output field (every Set*/Delete* command\'s real shape) '
    'returns an empty map, not null — null must mean "no reply arrived", never "arrived with '
    'nothing to report" (regression: every WAN Set*/Delete* client checks output == null to '
    'mean timeout, so this used to misreport every successful Set as a timeout once the '
    'Lambda relay — which used to default this itself — was removed)',
    () async {
      final transport = _FakeTransport()..replies.add({'status': 'ok'});
      final client = IotCommandClient('VZL-CAM-000001', transport: transport);

      final output = await client.sendCommandWithResponse(IotCommandClient.setCameraLocation);

      expect(output, isNotNull);
      expect(output, <String, dynamic>{});
    },
  );

  test('each command gets a fresh, distinct request_id', () async {
    final transport = _FakeTransport();
    final client = IotCommandClient('VZL-CAM-000001', transport: transport);

    await client.sendCommandWithResponse(IotCommandClient.getMirrorFlip);
    await client.sendCommandWithResponse(IotCommandClient.getMirrorFlip);

    final ids = transport.publishedAndWaited.map((b) => b['request_id']).toSet();
    expect(ids.length, 2);
  });

  test('sendCommandWithResponse defaults to a 12s wait when given no timeout', () async {
    final transport = _FakeTransport();
    final client = IotCommandClient('VZL-CAM-000001', transport: transport);

    await client.sendCommandWithResponse(IotCommandClient.getMirrorFlip);

    expect(transport.timeouts.single, const Duration(seconds: 12));
  });

  test('sendCommandWithResponse passes timeoutSeconds through to the transport', () async {
    final transport = _FakeTransport();
    final client = IotCommandClient('VZL-CAM-000001', transport: transport);

    await client.sendCommandWithResponse(IotCommandClient.getMirrorFlip, timeoutSeconds: 5);

    expect(transport.timeouts.single, const Duration(seconds: 5));
  });

  test(
    'sendCommandWithResponse(retryOnTimeout: false) makes a single attempt and throws on '
    'a bare timeout, instead of retrying',
    () async {
      final transport = _FakeTransport()..replies.add(null);
      final client = IotCommandClient('VZL-CAM-000001', transport: transport);

      await expectLater(
        client.sendCommandWithResponse(IotCommandClient.getMirrorFlip, retryOnTimeout: false),
        throwsA(isA<Exception>()),
      );
      expect(transport.publishedAndWaited.length, 1);
    },
  );

  test(
    'sendCommandWithResponse still retries once by default (retryOnTimeout defaults true)',
    () async {
      final transport = _FakeTransport()
        ..replies.add(null)
        ..replies.add(null);
      final client = IotCommandClient('VZL-CAM-000001', transport: transport);

      await expectLater(
        client.sendCommandWithResponse(IotCommandClient.getMirrorFlip),
        throwsA(isA<Exception>()),
      );
      expect(transport.publishedAndWaited.length, 2);
    },
  );

  test(
    'WanDeviceIdentityClient.getDeviceIdentity honours its own timeout (regression: this used '
    'to be silently dropped, so a 5s caller-requested timeout actually took up to ~24s)',
    () async {
      final transport = _FakeTransport()
        ..replies.add({
          'status': 'ok',
          'output': {'name': 'Front Door', 'location': 'Porch', 'timezone': 'UTC'},
        });
      final iot = IotCommandClient('VZL-CAM-000001', transport: transport);
      final client = WanDeviceIdentityClient('VZL-CAM-000001', iotCommandClient: iot);

      await client.getDeviceIdentity(timeout: const Duration(seconds: 5));

      expect(transport.timeouts.single, const Duration(seconds: 5));
    },
  );
}
