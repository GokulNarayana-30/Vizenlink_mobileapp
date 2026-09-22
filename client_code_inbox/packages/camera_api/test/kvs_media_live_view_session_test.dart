import 'dart:async';
import 'dart:io';

import 'package:camera_api/src/wan/kvs_media/kvs_get_media_client.dart';
import 'package:camera_api/src/wan/kvs_media/kvs_media_live_view_session.dart';
import 'package:camera_api/src/wan/kvs_media/kvs_media_viewer_credentials_client.dart';
import 'package:test/test.dart';

class _FakeCredentialsClient extends KvsMediaViewerCredentialsClient {
  _FakeCredentialsClient(this.ttl);
  final Duration ttl;
  int calls = 0;

  @override
  Future<KvsMediaViewerCredentials> getCredentials(String streamName) async {
    calls++;
    return KvsMediaViewerCredentials(
      accessKeyId: 'AKIA$calls',
      secretAccessKey: 'secret',
      sessionToken: 'token',
      expiration: DateTime.now().toUtc().add(ttl),
      region: 'ap-south-1',
      dataEndpoint: 'https://s-test.kinesisvideo.ap-south-1.amazonaws.com',
    );
  }
}

/// Each getMedia() call hands out a fresh controller so a test can end one connection while
/// keeping the next one alive.
class _FakeGetMediaClient extends KvsGetMediaClient {
  final List<StreamController<List<int>>> connections = [];
  final List<String> accessKeysUsed = [];
  int failNext = 0;

  @override
  Future<Stream<List<int>>> getMedia({
    required KvsMediaViewerCredentials credentials,
    required String streamName,
  }) async {
    accessKeysUsed.add(credentials.accessKeyId);
    if (failNext > 0) {
      failNext--;
      throw Exception('GetMedia failed (500)');
    }
    final c = StreamController<List<int>>();
    connections.add(c);
    return c.stream;
  }

  @override
  void close() {}
}

Future<void> _pump([int ms = 30]) =>
    Future<void>.delayed(Duration(milliseconds: ms));

void main() {
  final fixture = File('test/fixtures/kvs_h264_fragment.mkv').readAsBytesSync();

  Future<void> feed(StreamController<List<int>> c, {int chunk = 8192}) async {
    for (var i = 0; i < fixture.length; i += chunk) {
      c.add(fixture.sublist(i, (i + chunk).clamp(0, fixture.length)));
      await _pump(1);
    }
  }

  late _FakeCredentialsClient creds;
  late _FakeGetMediaClient media;

  KvsMediaLiveViewSession make({
    Duration ttl = const Duration(minutes: 15),
    Duration refreshMargin = const Duration(seconds: 60),
    int maxAttempts = 3,
    int maxPending = 2 * 1024 * 1024,
  }) {
    creds = _FakeCredentialsClient(ttl);
    media = _FakeGetMediaClient();
    return KvsMediaLiveViewSession(
      streamName: 'VZL-CAM-000001-medium',
      credentialsClient: creds,
      getMediaClient: media,
      credentialRefreshMargin: refreshMargin,
      maxReconnectAttempts: maxAttempts,
      reconnectBackoff: const Duration(milliseconds: 10),
      maxPendingBytesPerClient: maxPending,
    );
  }

  Future<List<int>> collect(
    Future<HttpClientResponse> f,
    List<int> into,
  ) async {
    final r = await f;
    r.listen(into.addAll);
    return into;
  }

  // Response headers only go out with the first bytes written (init segment), so callers must
  // feed media before awaiting the returned future.
  Future<HttpClientResponse> connectClient(KvsMediaLiveViewSession s) async {
    final req = await HttpClient().getUrl(s.url!);
    return req.close();
  }

  test(
    'start() vends once, opens GetMedia and serves fMP4 from the fixture',
    () async {
      final s = make();
      await s.start();
      expect(creds.calls, 1);
      final received = <int>[];
      final done = collect(connectClient(s), received);
      await _pump(50);
      await feed(media.connections.single);
      await done;
      await _pump(100);
      expect(s.lastSampleAt, isNotNull);
      expect(received.length, greaterThan(1000));
      // ftyp box right after the 4-byte size.
      expect(String.fromCharCodes(received.sublist(4, 8)), 'ftyp');
      await s.stop();
    },
  );

  test(
    'stream ending mid-session is transparently re-established, session stays alive',
    () async {
      final s = make();
      await s.start();
      final received = <int>[];
      final done = collect(connectClient(s), received);
      await _pump(50);
      await feed(media.connections[0]);
      await done;
      await media.connections[0].close();
      await _pump(100);
      expect(media.connections.length, 2);
      expect(s.isSessionEnded, isFalse);
      final before = received.length;
      await feed(media.connections[1]);
      await _pump(100);
      expect(received.length, greaterThan(before));
      await s.stop();
    },
  );

  test(
    'credentials are re-vended and GetMedia reopened ahead of expiry',
    () async {
      // TTL 1.5s with a 1s margin -> refresh fires after the 1s floor.
      final s = make(
        ttl: const Duration(milliseconds: 1500),
        refreshMargin: const Duration(seconds: 1),
      );
      await s.start();
      await feed(media.connections[0]);
      await _pump(1400);
      expect(creds.calls, greaterThanOrEqualTo(2));
      expect(media.connections.length, greaterThanOrEqualTo(2));
      expect(media.accessKeysUsed.first, 'AKIA1');
      expect(media.accessKeysUsed.last, isNot('AKIA1'));
      expect(s.isSessionEnded, isFalse);
      await s.stop();
    },
  );

  test(
    'connections that end without delivering data eventually end the session',
    () async {
      final s = make(maxAttempts: 2);
      await s.start();
      await media.connections[0].close();
      for (var i = 0; i < 50 && !s.isSessionEnded; i++) {
        await _pump(20);
        if (media.connections.isNotEmpty && i > 0) {
          for (final c in media.connections) {
            if (!c.isClosed) await c.close();
          }
        }
      }
      expect(s.isSessionEnded, isTrue);
      await s.stop();
    },
  );

  test('reconnect failures (GetMedia errors) count toward giving up', () async {
    final s = make(maxAttempts: 2);
    await s.start();
    media.failNext = 100;
    await media.connections[0].close();
    for (var i = 0; i < 50 && !s.isSessionEnded; i++) {
      await _pump(20);
    }
    expect(s.isSessionEnded, isTrue);
    await s.stop();
  });

  test('stop() marks the session ended', () async {
    final s = make();
    await s.start();
    expect(s.isSessionEnded, isFalse);
    await s.stop();
    expect(s.isSessionEnded, isTrue);
  });

  test(
    'a client over the pending cap gets fewer bytes than an unconstrained one',
    () async {
      // Dropping whole fragments must never leave a torn box in the stream the player reads.
      bool boxAligned(List<int> b) {
        var i = 0;
        while (i + 8 <= b.length) {
          final size =
              (b[i] << 24) | (b[i + 1] << 16) | (b[i + 2] << 8) | b[i + 3];
          if (size < 8) return false;
          i += size;
        }
        return i == b.length;
      }

      Future<int> run(int cap) async {
        final s = make(maxPending: cap);
        await s.start();
        final received = <int>[];
        final done = collect(connectClient(s), received);
        await _pump(50);
        await feed(media.connections.single, chunk: 16384);
        await done;
        await _pump(200);
        await s.stop();
        expect(boxAligned(received), isTrue, reason: 'cap=$cap left a torn box');
        return received.length;
      }

      final capped = await run(1);
      final free = await run(1 << 30);
      expect(capped, lessThan(free));
    },
  );
}
