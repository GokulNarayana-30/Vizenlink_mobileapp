import 'package:camera_api/camera_api.dart';
import 'package:test/test.dart';

import 'rest_mock_helpers.dart';

Map<String, dynamic> _clip(int start) => {
  'id': start,
  'start': start,
  'end': start + 60,
  'size_bytes': 12000000,
  'active': false,
};

void main() {
  setUp(NuraeyeClient.debugClearCaches);

  test('getAllRecordings returns a single page as-is when not truncated', () async {
    final nuraeye = NuraeyeClient(
      const CameraConnection(host: '192.168.1.50', username: 'admin', password: 'pw'),
      httpClient: mockNuraeyeRest(routeByPath({
        '/nuraeye/recordings': (request) => jsonOk({
          'storage_available': true,
          'card_present': true,
          'truncated': false,
          'recordings': [_clip(100), _clip(200)],
        }),
      })),
    );
    final client = RecordingsClient(nuraeye);

    final result = await client.getAllRecordings();

    expect(result, isA<CameraSuccess<RecordingsList>>());
    final list = (result as CameraSuccess<RecordingsList>).value;
    expect(list.clips.map((c) => c.id), [100, 200]);
    expect(list.truncated, false);
  });

  // Real bug found 2026-09-24: a naive single-page getRecordings() silently hid every clip
  // newer than whatever filled the first response's buffer (oldest-first) once a camera
  // accumulated enough history -- this is the pagination fix's core behavior.
  test('getAllRecordings pages forward past a truncated response using the last clip start + 1', () async {
    final requestedStarts = <int?>[];
    final nuraeye = NuraeyeClient(
      const CameraConnection(host: '192.168.1.50', username: 'admin', password: 'pw'),
      httpClient: mockNuraeyeRest(routeByPath({
        '/nuraeye/recordings': (request) {
          final start = request.url.queryParameters['start'];
          requestedStarts.add(start == null ? null : int.parse(start));
          if (start == null) {
            // Page 1: oldest-first, truncated -- the newest clip (300) never fits.
            return jsonOk({
              'storage_available': true,
              'card_present': true,
              'truncated': true,
              'recordings': [_clip(100), _clip(200)],
            });
          }
          // Page 2: requested with start = 201 (last page's max start + 1).
          expect(int.parse(start), 201);
          return jsonOk({
            'storage_available': true,
            'card_present': true,
            'truncated': false,
            'recordings': [_clip(300)],
          });
        },
      })),
    );
    final client = RecordingsClient(nuraeye);

    final result = await client.getAllRecordings();

    expect(result, isA<CameraSuccess<RecordingsList>>());
    final list = (result as CameraSuccess<RecordingsList>).value;
    // All three clips present, including the one hidden behind page 1's truncation -- this is
    // exactly the scheduled-recording-clips-invisible symptom this fix resolves.
    expect(list.clips.map((c) => c.id), [100, 200, 300]);
    expect(list.truncated, false);
    expect(requestedStarts, [null, 201]);
  });

  test('getAllRecordings stops and reports truncated: true once maxPages is hit', () async {
    var callCount = 0;
    final nuraeye = NuraeyeClient(
      const CameraConnection(host: '192.168.1.50', username: 'admin', password: 'pw'),
      httpClient: mockNuraeyeRest(routeByPath({
        '/nuraeye/recordings': (request) {
          callCount++;
          final base = callCount * 100;
          return jsonOk({
            'storage_available': true,
            'card_present': true,
            'truncated': true, // never a clean final page
            'recordings': [_clip(base)],
          });
        },
      })),
    );
    final client = RecordingsClient(nuraeye);

    final result = await client.getAllRecordings(maxPages: 3);

    expect(result, isA<CameraSuccess<RecordingsList>>());
    final list = (result as CameraSuccess<RecordingsList>).value;
    expect(list.clips.length, 3);
    expect(list.truncated, true); // real "there might be even more" signal
    expect(callCount, 3);
  });

  test('getAllRecordings stops on an empty truncated page rather than looping forever', () async {
    final nuraeye = NuraeyeClient(
      const CameraConnection(host: '192.168.1.50', username: 'admin', password: 'pw'),
      httpClient: mockNuraeyeRest(routeByPath({
        '/nuraeye/recordings': (request) => jsonOk({
          'storage_available': true,
          'card_present': true,
          'truncated': true,
          'recordings': <Map<String, dynamic>>[],
        }),
      })),
    );
    final client = RecordingsClient(nuraeye);

    final result = await client.getAllRecordings();

    expect(result, isA<CameraSuccess<RecordingsList>>());
    final list = (result as CameraSuccess<RecordingsList>).value;
    expect(list.clips, isEmpty);
  });

  test('getAllRecordings surfaces CameraFailure from any page without retrying forever', () async {
    final nuraeye = NuraeyeClient(
      const CameraConnection(host: '192.168.1.50', username: 'admin', password: 'pw'),
      httpClient: mockNuraeyeRest(routeByPath({
        '/nuraeye/recordings': (request) => jsonError(500, 'storage error'),
      })),
    );
    final client = RecordingsClient(nuraeye);

    final result = await client.getAllRecordings();

    expect(result, isA<CameraFailure<RecordingsList>>());
  });
}
