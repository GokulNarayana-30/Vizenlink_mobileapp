import 'package:camera_api/camera_api.dart';
import 'package:test/test.dart';

class _ScriptedTransport implements IotTransport {
  _ScriptedTransport(this.reply);
  final Map<String, dynamic>? Function(Map<String, dynamic> body) reply;
  final List<Map<String, dynamic>> sent = [];

  @override
  Future<void> publish(String thingName, Map<String, dynamic> body) async {}

  @override
  Future<Map<String, dynamic>?> publishAndWait(
    String thingName,
    Map<String, dynamic> body, {
    Duration timeout = const Duration(seconds: 12),
  }) async {
    sent.add(body);
    final r = reply(body);
    return r == null
        ? null
        : {'request_id': body['request_id'], 'status': 'ok', ...r};
  }
}

IotCommandClient _iot(_ScriptedTransport t) =>
    IotCommandClient('VZL-CAM-000001', transport: t);

void main() {
  group('WanClipPlaybackClient', () {
    test('stream name is <thing>-playback', () {
      expect(
        wanClipPlaybackStreamName('VZL-CAM-000001'),
        'VZL-CAM-000001-playback',
      );
    });

    test(
      'startClip sends command 75 with clip id and start offset, no retry on timeout',
      () async {
        final t = _ScriptedTransport((_) => null);
        final client = WanClipPlaybackClient(
          'VZL-CAM-000001',
          iotCommandClient: _iot(t),
        );
        final result = await client.startClip(1789550949, startMs: 5000);
        expect(result, isA<CameraFailure<void>>());
        expect((result as CameraFailure<void>).reason, contains('timed out'));
        expect(t.sent, hasLength(1)); // no automatic second Start
        expect(t.sent.single['command'], 75);
        expect(t.sent.single['params'], {
          'clip_epoch_start': 1789550949,
          'start_time_ms': 5000,
        });
      },
    );

    test('stop/pause/resume map to 79/77/78', () async {
      final t = _ScriptedTransport((_) => {});
      final client = WanClipPlaybackClient(
        'VZL-CAM-000001',
        iotCommandClient: _iot(t),
      );
      expect(await client.stop(), isA<CameraSuccess<void>>());
      expect(await client.pause(), isA<CameraSuccess<void>>());
      expect(await client.resume(startMs: 2000), isA<CameraSuccess<void>>());
      expect(t.sent.map((b) => b['command']), [79, 77, 78]);
      expect(t.sent[2]['params'], {'start_time_ms': 2000});
    });

    test('a transport failure becomes CameraFailure', () async {
      final t = _ScriptedTransport((_) => throw Exception('offline'));
      final client = WanClipPlaybackClient(
        'VZL-CAM-000001',
        iotCommandClient: _iot(t),
      );
      final r = await client.stop();
      expect(r, isA<CameraFailure<void>>());
    });
  });

  group('WanRecordingsClient', () {
    test(
      'getRecordingDates parses YYYYMMDD into local midnight dates',
      () async {
        final t = _ScriptedTransport(
          (b) => {
            'output': {
              'dates': [
                {'date': '20260915', 'clip_count': 3},
                {'date': '20260916', 'clip_count': 1},
              ],
            },
          },
        );
        final client = WanRecordingsClient(
          'VZL-CAM-000001',
          iotCommandClient: _iot(t),
        );
        final r = await client.getRecordingDates(
          start: 1,
          end: 2,
          tzOffsetMinutes: 330,
        );
        expect((r as CameraSuccess<List<DateTime>>).value, [
          DateTime(2026, 9, 15),
          DateTime(2026, 9, 16),
        ]);
        expect(t.sent.single['command'], 81);
        expect(t.sent.single['params']['tz_offset_minutes'], 330);
      },
    );

    test('getRecordings follows pages by offset until more is false', () async {
      final t = _ScriptedTransport((b) {
        final offset = b['params']['offset'] as int;
        return {
          'output': offset == 0
              ? {
                  'clips': [
                    {'id': 100, 'end': 160},
                    {'id': 200, 'end': 260},
                  ],
                  'more': true,
                }
              : {
                  'clips': [
                    {'id': 300, 'end': 360},
                  ],
                  'more': false,
                },
        };
      });
      final client = WanRecordingsClient(
        'VZL-CAM-000001',
        iotCommandClient: _iot(t),
      );
      final r = await client.getRecordings(start: 0, end: 1000);
      final clips = (r as CameraSuccess<List<RecordingClip>>).value;
      expect(clips.map((c) => c.id), [100, 200, 300]);
      expect(clips.map((c) => c.start), [100, 200, 300]);
      expect(clips.map((c) => c.end), [160, 260, 360]);
      expect(t.sent.map((b) => b['params']['offset']), [0, 2]);
    });

    test('malformed clip entry is a CameraFailure', () async {
      final t = _ScriptedTransport(
        (_) => {
          'output': {
            'clips': [
              {'id': 'x'},
            ],
            'more': false,
          },
        },
      );
      final client = WanRecordingsClient(
        'VZL-CAM-000001',
        iotCommandClient: _iot(t),
      );
      expect(
        await client.getRecordings(start: 0, end: 1),
        isA<CameraFailure<List<RecordingClip>>>(),
      );
    });

    test('no reply surfaces as a timed-out failure', () async {
      final t = _ScriptedTransport((_) => null);
      final client = WanRecordingsClient(
        'VZL-CAM-000001',
        iotCommandClient: _iot(t),
      );
      expect(
        await client.getRecordings(start: 0, end: 1),
        isA<CameraFailure<List<RecordingClip>>>(),
      );
    });
  });
}
