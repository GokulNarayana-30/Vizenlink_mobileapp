import 'package:camera_api/camera_api.dart';
import 'package:test/test.dart';

class _FakeTransport implements IotTransport {
  _FakeTransport(this.publishAndWaitImpl);

  final Future<Map<String, dynamic>?> Function(Map<String, dynamic> body) publishAndWaitImpl;
  Map<String, dynamic>? captured;

  @override
  Future<void> publish(String thingName, Map<String, dynamic> body) async {}

  @override
  Future<Map<String, dynamic>?> publishAndWait(
    String thingName,
    Map<String, dynamic> body, {
    Duration timeout = const Duration(seconds: 12),
  }) async {
    captured = body;
    return publishAndWaitImpl(body);
  }
}

void main() {
  test('getMode parses the same fields as the LAN client', () async {
    final transport = _FakeTransport((_) async => {
      'status': 'ok',
      'output': {
        'mode': 'scheduled',
        'schedule': [
          {'day_of_week': 1, 'start_minute': 480, 'end_minute': 1020},
        ],
        'event_trigger_source_configured': false,
      },
    });
    final iot = IotCommandClient('VZL-CAM-000001', transport: transport);

    final client = WanRecordingModeClient('VZL-CAM-000001', iotCommandClient: iot);
    final result = await client.getMode();

    expect(transport.captured!['command'], IotCommandClient.getRecordingMode);

    switch (result) {
      case CameraSuccess(:final value):
        expect(value.mode, RecordingMode.scheduled);
        expect(value.schedule, [
          const RecordingScheduleWindow(dayOfWeek: 1, startMinute: 480, endMinute: 1020),
        ]);
        expect(value.eventTriggerSourceConfigured, false);
      default:
        fail('Expected CameraSuccess, got $result');
    }
  });

  test('setMode sends the wire mode and schedule, reports success once the camera replies', () async {
    final transport = _FakeTransport((_) async => {'status': 'ok', 'output': <String, dynamic>{}});
    final iot = IotCommandClient('VZL-CAM-000001', transport: transport);

    final client = WanRecordingModeClient('VZL-CAM-000001', iotCommandClient: iot);
    final result = await client.setMode(
      RecordingMode.scheduled,
      schedule: const [
        RecordingScheduleWindow(dayOfWeek: 1, startMinute: 480, endMinute: 1020),
      ],
    );

    expect(transport.captured!['command'], IotCommandClient.setRecordingMode);
    expect(transport.captured!['params'], {
      'mode': 'scheduled',
      'schedule': [
        {'day_of_week': 1, 'start_minute': 480, 'end_minute': 1020},
      ],
    });
    expect(result, isA<CameraSuccess<void>>());
  });

  test('setMode omits schedule for continuous mode', () async {
    final transport = _FakeTransport((_) async => {'status': 'ok', 'output': <String, dynamic>{}});
    final iot = IotCommandClient('VZL-CAM-000001', transport: transport);

    final client = WanRecordingModeClient('VZL-CAM-000001', iotCommandClient: iot);
    await client.setMode(RecordingMode.continuous);

    expect(transport.captured!['params'], {'mode': 'continuous'});
  });

  test('getSupportedModes parses the wire mode array', () async {
    final transport = _FakeTransport((_) async => {
      'status': 'ok',
      'output': {
        'supported_modes': ['continuous', 'scheduled', 'event_triggered'],
      },
    });
    final iot = IotCommandClient('VZL-CAM-000001', transport: transport);

    final client = WanRecordingModeClient('VZL-CAM-000001', iotCommandClient: iot);
    final result = await client.getSupportedModes();

    expect(transport.captured!['command'], IotCommandClient.getSupportedRecordingModes);
    switch (result) {
      case CameraSuccess(:final value):
        expect(value, [
          RecordingMode.continuous,
          RecordingMode.scheduled,
          RecordingMode.eventTriggered,
        ]);
      default:
        fail('Expected CameraSuccess, got $result');
    }
  });

  test('a camera timeout (no reply, even after the one-shot retry) surfaces as CameraFailure, not a thrown exception', () async {
    final transport = _FakeTransport((_) async => null);
    final iot = IotCommandClient('VZL-CAM-000001', transport: transport);

    final client = WanRecordingModeClient('VZL-CAM-000001', iotCommandClient: iot);
    final result = await client.getMode();

    // sendCommandWithResponse throws on retry exhaustion rather than returning null in this
    // configuration -- caught by this client's own try/catch, same as
    // WanNightVisionClient.getNightVisionType's equivalent test.
    expect(result, isA<CameraFailure<RecordingModeStatus>>());
  });
}
