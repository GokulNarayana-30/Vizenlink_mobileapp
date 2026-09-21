import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;

import 'package:camera_api/camera_api.dart';

import 'rtsp_live_view_session.dart';

/// One live-view session: opens [RtspLiveViewSession] against the camera's live-view RTSPS
/// listener (the `transport: "rtsp"` fallback resolved by `LiveStreamUriClient.getLiveStreamUri`
/// — see `packages/camera_api/STREAMING_GUIDE.md` §2.5), remuxes what it reads into fMP4 via
/// [RtspFmp4Muxer] (**reused unchanged** from Playback's own proxy), and serves that over a local
/// HTTP loopback server — so `video_player`/ExoPlayer (the same player `LiveViewController`
/// already uses for the WAN/KVS transport) can play this camera's live feed when WebRTC isn't
/// available.
///
/// **Adapted from** `rtsp_remux_proxy.dart`'s `RtspRemuxProxy` (recorded-clip playback) rather
/// than written from scratch — same init-segment/per-response-write-chain/access-unit-forwarding
/// shape, with every clip-specific concept (seek, a bound clip's start/end epoch, resumable
/// position tracking) dropped: live view has none of those, it always plays from "now" and never
/// ends on its own. [RtspFmp4Muxer] is constructed with `totalDurationSeconds: null` — that
/// class's own doc explains why: `null` is exactly the "unbounded/growing" signal ExoPlayer's
/// extractor needs to treat this as live content instead of a bounded/seekable file.
///
/// **One proxy instance per connection attempt** — same lifecycle contract as `RtspRemuxProxy`
/// (see [LiveViewController] for the reconnect posture: on [isSessionEnded] or a `video_player`
/// error, tear this down and construct a brand-new instance against a freshly-resolved
/// `getLiveStreamUri()` target, mirroring `STREAMING_GUIDE.md` §2.4's WebRTC reconnect posture —
/// a plain retry, no special-casing).
class RtspLiveViewProxy {
  RtspLiveViewProxy({
    required this.host,
    required this.port,
    required this.path,
    required this.username,
    required this.password,
    this.fallbackResolution = (width: 1280, height: 720),
  });

  final String host;
  final int port;
  final String path;
  final String username;
  final String password;

  /// Used only when [_parseSpsDimensions] can't determine the real dimensions
  /// (always, today — see that method's doc). Pass the caller's own
  /// already-known resolution for this profile/stream (e.g.
  /// `OnvifVideoEncoderClient.getProfiles()`'s `MediaProfile.resolution`)
  /// rather than relying on the 1280x720 default, which is only correct for
  /// whichever profile happens to actually be 720p.
  final ({int width, int height}) fallbackResolution;

  HttpServer? _server;
  RtspLiveViewSession? _rtsp;
  StreamSubscription<LiveH264AccessUnit>? _accessUnitSub;
  StreamSubscription<LiveAacAccessUnit>? _audioAccessUnitSub;
  final List<HttpResponse> _activeResponses = [];

  /// Set once [_rtsp]'s `accessUnits` stream closes on its own (connection lost — live content
  /// never "finishes" the way a clip does) — distinct from [stop] being called by the caller.
  /// Same real-hardware-found reason `RtspRemuxProxy._sessionEnded` exists: without this, a
  /// still-listening local HTTP server keeps accepting *new* connections from `video_player`'s
  /// own stall-triggered retries even though the underlying RTSP feed is already gone for good.
  bool _sessionEnded = false;

  /// True once the underlying RTSP feed has closed on its own — [LiveViewController] polls this
  /// the same way it already polls the WAN transport's own stall signals, to trigger a fresh
  /// reconnect rather than leaving a frozen last frame on screen indefinitely.
  bool get isSessionEnded => _sessionEnded;

  /// Cumulative wire bytes received on the underlying RTSP connection so far — see
  /// [RtspLiveViewSession.bytesReceived]'s own doc. `0` once the session is gone (post-[stop]).
  int get bytesReceived => _rtsp?.bytesReceived ?? 0;

  /// The local URL to hand to `VideoPlayerController.networkUrl()` — set once [start] completes.
  Uri? url;

  int? _firstRtpTimestamp90k;
  int? _lastRtpTimestamp90k;
  int? _firstAudioRtpTimestamp;
  int? _lastAudioRtpTimestamp;

  /// Opens the RTSP session (throws if that fails — surfaced to the caller before any HTTP
  /// server exists) and starts the local HTTP server. Completes once both are ready; the actual
  /// RTSP→fMP4 streaming to whichever client connects happens in the background from here on.
  Future<void> start() async {
    _rtsp = await RtspLiveViewSession.open(
      host: host,
      port: port,
      path: path,
      username: username,
      password: password,
    );
    final sps = _rtsp!.sps;
    final pps = _rtsp!.pps;
    if (sps == null || pps == null) {
      await _rtsp!.close();
      throw RtspLiveViewException(
        'DESCRIBE succeeded but no SPS/PPS was parsed from the SDP',
      );
    }
    final dims = _parseSpsDimensions(sps) ?? fallbackResolution;
    final muxer = RtspFmp4Muxer(
      sps: sps,
      pps: pps,
      width: dims.width,
      height: dims.height,
      audioSpecificConfig: _rtsp!.hasAudio ? _rtsp!.audioSpecificConfig : null,
      audioSampleRate: _rtsp!.hasAudio ? _rtsp!.audioSampleRate : null,
      audioChannelCount: _rtsp!.hasAudio ? _rtsp!.audioChannelCount : null,
      // Unbounded live content — see this class's own doc comment for why `null` (not a real
      // number) is the correct value here, unlike RtspRemuxProxy's bounded-clip duration.
      totalDurationSeconds: null,
    );

    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    url = Uri.parse('http://127.0.0.1:${_server!.port}/live.mp4');
    debugPrint(
      '[RtspLiveViewProxy] loopback server bound at $url, dims=${dims.width}x${dims.height}, '
      'audio=${muxer.hasAudioTrack ? '${_rtsp!.audioSampleRate}Hz/${_rtsp!.audioChannelCount}ch' : 'none'}',
    );
    unawaited(_serveHttp());

    _rtsp!.startReading();
    _accessUnitSub = _rtsp!.accessUnits.stream.listen(
      (au) => _onAccessUnit(au, muxer),
      onDone: () {
        debugPrint(
          '[RtspLiveViewProxy] RTSP session ended (connection lost) -- '
          'closing ${_activeResponses.length} open response(s), refusing further connections',
        );
        _sessionEnded = true;
        _closeAllResponses();
      },
    );
    if (muxer.hasAudioTrack) {
      _audioAccessUnitSub = _rtsp!.audioAccessUnits.stream.listen(
        (au) => _onAudioAccessUnit(au, muxer),
      );
    }
  }

  Future<void> _serveHttp() async {
    await for (final request in _server!) {
      if (request.method != 'GET') {
        request.response.statusCode = HttpStatus.methodNotAllowed;
        await request.response.close();
        continue;
      }
      if (_sessionEnded) {
        debugPrint(
          '[RtspLiveViewProxy] HTTP client connected after session end -- closing immediately',
        );
        await request.response.close();
        continue;
      }
      debugPrint(
        '[RtspLiveViewProxy] HTTP client connected (${_activeResponses.length + 1} active)',
      );
      request.response.headers.contentType = ContentType('video', 'mp4');
      // No contentLength set -- served as chunked transfer-encoding, exactly what a
      // live-appending fMP4 stream needs.
      if (_initSegmentSent != null) {
        unawaited(_writeToResponse(request.response, _initSegmentSent!));
      }
      _activeResponses.add(request.response);
      unawaited(
        request.response.done.catchError((Object _) {}).whenComplete(() {
          debugPrint('[RtspLiveViewProxy] HTTP client disconnected');
          _activeResponses.remove(request.response);
          _writeChains.remove(request.response);
        }),
      );
    }
  }

  List<int>? _initSegmentSent;
  int _accessUnitCount = 0;

  /// Same per-response write-chain fix `RtspRemuxProxy._writeToResponse` documents (a real bug
  /// found via hardware capture: an un-awaited `flush()` let a second `add()` on the same
  /// response race it, silently dropping the write) — each `add()`+`flush()` waits for the
  /// previous one on that same response before starting.
  final Map<HttpResponse, Future<void>> _writeChains = {};

  Future<void> _writeToResponse(HttpResponse r, List<int> bytes) {
    final previous = _writeChains[r] ?? Future<void>.value();
    final next = previous
        .then((_) async {
          r.add(bytes);
          await r.flush();
        })
        .catchError((Object e, StackTrace st) {
          debugPrint('[RtspLiveViewProxy] write to client failed: $e');
        });
    _writeChains[r] = next;
    return next;
  }

  void _ensureInitSegmentSent(RtspFmp4Muxer muxer) {
    if (_initSegmentSent != null) return;
    _initSegmentSent = muxer.initSegment();
    debugPrint(
      '[RtspLiveViewProxy] init segment built (${_initSegmentSent!.length} bytes), '
      'sending to ${_activeResponses.length} already-connected client(s)',
    );
    for (final r in _activeResponses) {
      unawaited(_writeToResponse(r, _initSegmentSent!));
    }
  }

  void _onAccessUnit(LiveH264AccessUnit au, RtspFmp4Muxer muxer) {
    _firstRtpTimestamp90k ??= au.rtpTimestamp90k;
    _ensureInitSegmentSent(muxer);

    const defaultDurationTicks = 4500; // ~20fps at the 90kHz clock
    final baseMediaDecodeTime = au.rtpTimestamp90k - _firstRtpTimestamp90k!;
    final durationTicks = _lastRtpTimestamp90k == null
        ? defaultDurationTicks
        : (au.rtpTimestamp90k - _lastRtpTimestamp90k!).clamp(1, 90000);
    _lastRtpTimestamp90k = au.rtpTimestamp90k;

    // Same real finding RtspRemuxProxy's own doc records: this camera's server-side logic
    // guarantees every fresh PLAY starts exactly at a real keyframe, so access unit #1 of every
    // session is unconditionally the sync sample, independent of the wire's NAL type.
    final isKeyframe = _accessUnitCount == 0 || au.isKeyframe;
    final fragment = muxer.fragment(
      nalu: au.nalu,
      baseMediaDecodeTime90k: baseMediaDecodeTime,
      durationTicks: durationTicks,
      isKeyframe: isKeyframe,
    );
    for (final r in _activeResponses) {
      unawaited(_writeToResponse(r, fragment));
    }

    _accessUnitCount++;
    if (_accessUnitCount <= 5 || _accessUnitCount % 50 == 0) {
      debugPrint(
        '[RtspLiveViewProxy] access unit #$_accessUnitCount: ${au.nalu.length} bytes, '
        'keyframe=$isKeyframe, rtpTs=${au.rtpTimestamp90k}, sent to '
        '${_activeResponses.length} client(s)',
      );
    }
  }

  int _audioAccessUnitCount = 0;

  void _onAudioAccessUnit(LiveAacAccessUnit au, RtspFmp4Muxer muxer) {
    _firstAudioRtpTimestamp ??= au.rtpTimestamp;
    _ensureInitSegmentSent(muxer);

    const defaultDurationTicks = 1024; // one AAC frame's worth of samples
    final baseMediaDecodeTime = au.rtpTimestamp - _firstAudioRtpTimestamp!;
    final sampleRate = muxer.audioSampleRate!;
    final durationTicks = _lastAudioRtpTimestamp == null
        ? defaultDurationTicks
        : (au.rtpTimestamp - _lastAudioRtpTimestamp!).clamp(1, sampleRate);
    _lastAudioRtpTimestamp = au.rtpTimestamp;

    final fragment = muxer.audioFragment(
      aac: au.aac,
      baseMediaDecodeTimeAudioTicks: baseMediaDecodeTime,
      durationTicks: durationTicks,
    );
    for (final r in _activeResponses) {
      unawaited(_writeToResponse(r, fragment));
    }

    _audioAccessUnitCount++;
    if (_audioAccessUnitCount <= 5 || _audioAccessUnitCount % 50 == 0) {
      debugPrint(
        '[RtspLiveViewProxy] audio access unit #$_audioAccessUnitCount: ${au.aac.length} bytes, '
        'rtpTs=${au.rtpTimestamp}, sent to ${_activeResponses.length} client(s)',
      );
    }
  }

  void _closeAllResponses() {
    for (final r in List.of(_activeResponses)) {
      r.close().catchError((Object _) {});
    }
    _activeResponses.clear();
    _writeChains.clear();
  }

  /// Tears down the RTSP session (`TEARDOWN`, releasing the camera's live-view slot) and the
  /// local HTTP server. Safe to call more than once.
  Future<void> stop() async {
    debugPrint(
      '[RtspLiveViewProxy] stop() -- accessUnitCount=$_accessUnitCount',
    );
    await _accessUnitSub?.cancel();
    await _audioAccessUnitSub?.cancel();
    _closeAllResponses();
    await _rtsp?.close();
    await _server?.close(force: true);
    debugPrint('[RtspLiveViewProxy] stop() complete');
  }

  static ({int width, int height})? _parseSpsDimensions(List<int> sps) {
    // Full SPS parsing is out of scope here, same as RtspRemuxProxy's own doc explains — this
    // proxy now serves any of the camera's profiles (High/Medium/Low), each a different real
    // resolution (confirmed on real hardware: 1920x1080/1280x720/640x360), so there is no longer
    // one single correct fixed guess — see [fallbackResolution], which the caller should populate
    // from `OnvifVideoEncoderClient.getProfiles()`'s `MediaProfile.resolution` for whichever
    // profile this connection actually targets.
    return null;
  }
}
