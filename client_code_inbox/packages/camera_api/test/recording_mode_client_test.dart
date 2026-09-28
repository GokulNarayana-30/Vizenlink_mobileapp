import 'dart:convert';

import 'package:camera_api/camera_api.dart';
import 'package:test/test.dart';

import 'rest_mock_helpers.dart';

void main() {
  setUp(NuraeyeClient.debugClearCaches);

  test('getMode parses mode, schedule, and event_trigger_source_configured', () async {
    final nuraeye = NuraeyeClient(
      const CameraConnection(host: '192.168.1.50', username: 'admin', password: 'pw'),
      httpClient: mockNuraeyeRest(routeByPath({
        '/nuraeye/recordings/mode': (request) => jsonOk({
          'mode': 'scheduled',
          'schedule': [
            {'day_of_week': 1, 'start_minute': 480, 'end_minute': 1020},
          ],
          'event_trigger_source_configured': false,
        }),
      })),
    );
    final client = RecordingModeClient(nuraeye);

    final result = await client.getMode();

    expect(result, isA<CameraSuccess<RecordingModeStatus>>());
    final status = (result as CameraSuccess<RecordingModeStatus>).value;
    expect(status.mode, RecordingMode.scheduled);
    expect(status.schedule, [
      const RecordingScheduleWindow(dayOfWeek: 1, startMinute: 480, endMinute: 1020),
    ]);
    expect(status.eventTriggerSourceConfigured, false);
  });

  test('getMode parses an empty schedule for continuous mode', () async {
    final nuraeye = NuraeyeClient(
      const CameraConnection(host: '192.168.1.50', username: 'admin', password: 'pw'),
      httpClient: mockNuraeyeRest(routeByPath({
        '/nuraeye/recordings/mode': (request) => jsonOk({
          'mode': 'continuous',
          'schedule': [],
          'event_trigger_source_configured': false,
        }),
      })),
    );
    final client = RecordingModeClient(nuraeye);

    final result = await client.getMode();

    final status = (result as CameraSuccess<RecordingModeStatus>).value;
    expect(status.mode, RecordingMode.continuous);
    expect(status.schedule, isEmpty);
  });

  test('setMode sends schedule only for scheduled mode', () async {
    final nuraeye = NuraeyeClient(
      const CameraConnection(host: '192.168.1.50', username: 'admin', password: 'pw'),
      httpClient: mockNuraeyeRest(routeByPath({
        '/nuraeye/recordings/mode': (request) {
          expect(request.method, 'POST');
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          expect(body, {
            'mode': 'scheduled',
            'schedule': [
              {'day_of_week': 1, 'start_minute': 480, 'end_minute': 1020},
            ],
          });
          return jsonOk(const {});
        },
      })),
    );
    final client = RecordingModeClient(nuraeye);

    final result = await client.setMode(
      RecordingMode.scheduled,
      schedule: const [
        RecordingScheduleWindow(dayOfWeek: 1, startMinute: 480, endMinute: 1020),
      ],
    );

    expect(result, isA<CameraSuccess<void>>());
  });

  test('setMode omits schedule for continuous mode even if one is passed', () async {
    final nuraeye = NuraeyeClient(
      const CameraConnection(host: '192.168.1.50', username: 'admin', password: 'pw'),
      httpClient: mockNuraeyeRest(routeByPath({
        '/nuraeye/recordings/mode': (request) {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          expect(body, {'mode': 'continuous'});
          return jsonOk(const {});
        },
      })),
    );
    final client = RecordingModeClient(nuraeye);

    final result = await client.setMode(
      RecordingMode.continuous,
      schedule: const [
        RecordingScheduleWindow(dayOfWeek: 1, startMinute: 480, endMinute: 1020),
      ],
    );

    expect(result, isA<CameraSuccess<void>>());
  });

  test('setMode surfaces CameraFailure for a rejected (HTTP 500) request', () async {
    final nuraeye = NuraeyeClient(
      const CameraConnection(host: '192.168.1.50', username: 'admin', password: 'pw'),
      httpClient: mockNuraeyeRest(routeByPath({
        '/nuraeye/recordings/mode': (request) =>
            jsonError(500, 'Mode not supported on this SKU, or invalid schedule'),
      })),
    );
    final client = RecordingModeClient(nuraeye);

    final result = await client.setMode(RecordingMode.eventTriggered);

    expect(result, isA<CameraFailure<void>>());
  });
}
