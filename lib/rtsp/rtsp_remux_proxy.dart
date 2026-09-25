import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;

import 'package:camera_api/camera_api.dart';

import 'rtsp_replay_client.dart';

/// One playback session: opens [RtspReplaySession] against the camera's playback RTSPS listener,
/// remuxes what it reads into fMP4 via [RtspFmp4Muxer], and serves that over a local HTTP
/// loopback server — so `video_player`/ExoPlayer (no RTSP support at all) can play this camera's
/// recorded-clip stream. See `rtsp_replay_client.dart`'s doc comment for why this replaced
/// `media_kit` entirely for this screen (`FR-MOB-114`, `BUG-021`).
///
/// **One proxy instance per playback attempt** — deliberately not a general-purpose reusable
/// server. This camera's RTSPS playback server has no `PAUSE` RTSP method at all (confirmed
/// directly from `module_rtsps.c`'s `OPTIONS` response: only `OPTIONS, DESCRIBE, SETUP, PLAY,
/// TEARDOWN`), so "pause" in this app means: remember the current position (see
/// [lastKnownPositionEpochSeconds]), fully tear this proxy down (`TEARDOWN` releases the
/// camera's playback session/resources instead of leaving it idling), and "resume" means
/// constructing a brand-new [RtspRemuxProxy] with `seekToEpochSeconds` set to that remembered
/// position — a fresh `DESCRIBE`/`SETUP`/`PLAY` with a `Range: clock=...` header, the same seek
/// mechanism `BUG-013`/`BUG-015` already fixed and hardware-verified. See
/// `recording_timeline_screen.dart`'s `_pause`/`_resume` for the caller side of this.
class RtspRemuxProxy {
  RtspRemuxProxy({
    required this.host,
    required this.port,
    required this.path,
    required this.username,
    required this.password,
    required this.clipEpochStart,
    this.seekToEpochSeconds,
    this.clipEpochEnd,
  });

  final String host;
  final int port;
  final String path;
  final String username;
  final String password;
  final int clipEpochStart;
  final int? seekToEpochSeconds;

  /// 2026-09-02, `BUG-029` — the clip's own known end (`GetRecordings`' `end` field), already
  /// known to the caller before playback starts. Optional (`null` preserves the exact previous
  /// behavior — an unknown/`0` fMP4 duration) purely so a caller that hasn't looked this up yet
  /// isn't forced to. See [RtspFmp4Muxer.totalDurationSeconds]'s own doc comment for why this
  /// matters — declaring a real duration is what lets ExoPlayer track actual playback position
  /// instead of treating the stream as unbounded live content.
  final int? clipEpochEnd;

  HttpServer? _server;
  RtspReplaySession? _rtsp;
  StreamSubscription<H264AccessUnit>? _accessUnitSub;
  StreamSubscription<AacAccessUnit>? _audioAccessUnitSub;
  final List<HttpResponse> _activeResponses = [];

  /// 2026-09-02, `BUG-029`: set once [_rtsp]'s `accessUnits` stream closes on its own (clip
  /// content genuinely exhausted, or the connection died) -- distinct from [stop] being called
  /// by the UI. Real hardware symptom this fixes: without this flag, a still-listening local
  /// HTTP server kept accepting *new* connections from ExoPlayer's own stall-triggered retries
  /// (observed climbing to 6 simultaneously open, unclosed responses in one test) even though
  /// the underlying RTSP feed was already gone for good and would never produce another byte for
  /// any of them. Checked in [_serveHttp] to refuse/immediately-close any connection accepted
  /// after this point instead of queuing it into [_activeResponses] to sit forever.
  bool _sessionEnded = false;

  /// True once the underlying RTSP feed has closed on its own (clip content exhausted, or the
  /// connection died) -- as opposed to [stop] being called by the UI. The caller (currently
  /// [recording_timeline_screen.dart]'s position timer) polls this to stop ticking the displayed
  /// clock forward and show a finished/ended state instead of leaving a frozen last value on
  /// screen indefinitely. See [_sessionEnded]'s own doc for the real symptom this addresses.
  bool get isSessionEnded => _sessionEnded;

  /// The elapsed-seconds-since-this-clip's-start position of the most recently emitted access
  /// unit, tracked from the camera's own RTP timestamps (server-side-authoritative — never the
  /// player's own, possibly-buffered, position estimate). Updated continuously while streaming;
  /// read by [recording_timeline_screen.dart]'s pause handler as the position to resume from.
  int? lastKnownPositionEpochSeconds;

  int? _firstRtpTimestamp90k;
  int? _lastRtpTimestamp90k;

  /// 2026-09-02, `FR-MOB-114` audio playback — same role as [_firstRtpTimestamp90k]/
  /// [_lastRtpTimestamp90k], but in the audio track's own clock (RTP audio's timestamp already
  /// ticks at exactly the sample rate, not 90kHz) and tracked completely independently, since
  /// audio and video access units arrive as two separate streams with no guaranteed interleave.
  int? _firstAudioRtpTimestamp;
  int? _lastAudioRtpTimestamp;

  /// The local URL to hand to `VideoPlayerController.networkUrl()` — set once [start] completes.
  Uri? url;

  /// Opens the RTSP session (throws if that fails — surfaced to the caller before any HTTP
  /// server exists) and starts the local HTTP server. Completes once both are ready; the actual
  /// RTSP→fMP4 streaming to whichever client connects happens in the background from here on.
  Future<void> start() async {
    _rtsp = await RtspReplaySession.open(
      host: host,
      port: port,
      path: path,
      username: username,
      password: password,
      clipEpochStart: clipEpochStart,
      seekToEpochSeconds: seekToEpochSeconds,
    );
    final sps = _rtsp!.sps;
    final pps = _rtsp!.pps;
    if (sps == null || pps == null) {
      await _rtsp!.close();
      throw RtspReplayException(
        'DESCRIBE succeeded but no SPS/PPS was parsed from the SDP',
      );
    }
    final isHevc = _rtsp!.videoCodec == VideoCodec.h265;
    if (isHevc && _rtsp!.vps == null) {
      // A recorded clip's SDP normally carries VPS, so this is only reached
      // if the server ever omits it — then it can only arrive in-band, and
      // the RTP read loop has to be running to see it. Start it early, ahead
      // of the usual startReading() below. Deliberately does NOT attach
      // _accessUnitSub yet: `accessUnits` is a broadcast controller that
      // drops adds when nothing is listening, which is what we want — any
      // access unit arriving during this wait is one no HTTP client could
      // have received anyway, and it keeps the first-access-unit
      // forced-keyframe override landing on the first unit the real
      // listener actually processes.
      _rtsp!.startReading();
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (_rtsp!.vps == null && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      if (_rtsp!.vps == null) {
        await _rtsp!.close();
        throw RtspReplayException(
          'H.265 clip but no VPS in the SDP or in-band within 10s',
        );
      }
    }

    final dims = _parseSpsDimensions(sps) ?? (width: 2560, height: 1440);
    // 2026-09-02, `FR-MOB-114` audio playback: RtspReplaySession.hasAudio is only ever true when
    // playback_demuxer_bind.c's prvPopulateAudioInfoFromDemuxer() found a real, supported audio
    // track on this clip AND the audio SETUP above succeeded -- see hasAudio's own doc comment.
    final muxer = RtspFmp4Muxer(
      sps: sps,
      pps: pps,
      width: dims.width,
      height: dims.height,
      videoCodec: _rtsp!.videoCodec,
      vps: isHevc ? _rtsp!.vps : null,
      audioSpecificConfig: _rtsp!.hasAudio ? _rtsp!.audioSpecificConfig : null,
      audioSampleRate: _rtsp!.hasAudio ? _rtsp!.audioSampleRate : null,
      audioChannelCount: _rtsp!.hasAudio ? _rtsp!.audioChannelCount : null,
      // BUG-029: this session's own remaining duration -- if seeking mid-clip, only the part
      // from the seek point to the clip's real end will ever stream in THIS session (a fresh
      // fMP4 stream that starts its own timestamps at 0 regardless of where in the real clip
      // playback resumed), not the clip's full duration.
      totalDurationSeconds: clipEpochEnd != null
          ? clipEpochEnd! - (seekToEpochSeconds ?? clipEpochStart)
          : null,
    );

    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    url = Uri.parse('http://127.0.0.1:${_server!.port}/stream.mp4');
    debugPrint(
      '[RtspRemuxProxy] loopback server bound at $url, dims=${dims.width}x${dims.height}, '
      'audio=${muxer.hasAudioTrack ? '${_rtsp!.audioSampleRate}Hz/${_rtsp!.audioChannelCount}ch' : 'none'}',
    );
    unawaited(_serveHttp());

    _rtsp!.startReading();
    _accessUnitSub = _rtsp!.accessUnits.stream.listen(
      (au) => _onAccessUnit(au, muxer),
      onDone: () {
        debugPrint(
          '[RtspRemuxProxy] RTSP session ended (clip finished or connection lost) -- '
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
        // BUG-029: the underlying RTSP feed is already gone for good -- closing immediately
        // rather than queuing this into _activeResponses (which would never receive another
        // fragment) lets ExoPlayer see a clean, prompt end of stream on this retry instead of
        // becoming yet another connection that silently hangs forever.
        debugPrint(
          '[RtspRemuxProxy] HTTP client connected after session end -- closing immediately',
        );
        await request.response.close();
        continue;
      }
      debugPrint(
        '[RtspRemuxProxy] HTTP client connected (${_activeResponses.length + 1} active)',
      );
      request.response.headers.contentType = ContentType('video', 'mp4');
      // No contentLength set -- dart:io serves this as chunked transfer-encoding automatically,
      // which is exactly what a live-appending fMP4 stream needs (ExoPlayer's default extractor
      // handles a fragmented moov + open-ended body as a live/progressive source).
      if (_initSegmentSent != null) {
        unawaited(_writeToResponse(request.response, _initSegmentSent!));
      }
      _activeResponses.add(request.response);
      unawaited(
        request.response.done.catchError((Object _) {}).whenComplete(() {
          debugPrint('[RtspRemuxProxy] HTTP client disconnected');
          _activeResponses.remove(request.response);
          _writeChains.remove(request.response);
        }),
      );
    }
  }

  List<int>? _initSegmentSent;
  int _accessUnitCount = 0;

  // [AI Fix] 2026-09-02: real bug found from a direct hardware capture -- `r.add(...)` followed
  // by an un-awaited `r.flush()` (BUG-022's own follow-up fix) let a SECOND `add()` on the same
  // response race that flush()'s still-in-flight socket write. dart:io's HttpResponse throws
  // "Bad state: StreamSink is bound to a stream" when that happens -- synchronous and unhandled,
  // so the write is silently dropped. This hit on the very first access unit (the init segment's
  // `add()` raced against the first fragment's `add()`, both inside the same `_onAccessUnit`
  // call) -- confirmed via logcat: `[RtspRemuxProxy] init segment built...` immediately followed
  // by the unhandled exception at this file's `_onAccessUnit`, then every later access unit
  // (#2-180+) went out with no further exceptions. Losing exactly the stream's opening sample
  // (right after the init segment, before ExoPlayer has anything else to decode) is consistent
  // with the observed symptom: codec configures from the init segment, then nothing ever
  // visibly renders. Fixed by chaining writes per response -- each `add()`+`flush()` now waits
  // for the previous one on that same response to finish before starting, so two writes to one
  // socket never overlap.
  final Map<HttpResponse, Future<void>> _writeChains = {};

  Future<void> _writeToResponse(HttpResponse r, List<int> bytes) {
    final previous = _writeChains[r] ?? Future<void>.value();
    final next = previous
        .then((_) async {
          r.add(bytes);
          await r.flush();
        })
        .catchError((Object e, StackTrace st) {
          // A write failing (client disconnected mid-write, socket reset) is normal and already
          // handled by the `.done` listener removing this response from `_activeResponses` -- just
          // log it here so a real failure doesn't look identical to a silently-dropped write again.
          debugPrint('[RtspRemuxProxy] write to client failed: $e');
        });
    _writeChains[r] = next;
    return next;
  }

  /// Builds and sends the init segment exactly once, whichever access-unit stream (video or
  /// audio, 2026-09-02 `FR-MOB-114`) produces the very first sample of the session -- both
  /// tracks' config (SPS/PPS, and audioSpecificConfig/sampleRate/channelCount when present) is
  /// already fully known from DESCRIBE by the time either stream starts producing samples, so
  /// there's never a real ordering dependency here, just "whichever happens first triggers it."
  void _ensureInitSegmentSent(RtspFmp4Muxer muxer) {
    if (_initSegmentSent != null) return;
    _initSegmentSent = muxer.initSegment();
    debugPrint(
      '[RtspRemuxProxy] init segment built (${_initSegmentSent!.length} bytes), '
      'sending to ${_activeResponses.length} already-connected client(s)',
    );
    for (final r in _activeResponses) {
      unawaited(_writeToResponse(r, _initSegmentSent!));
    }
  }

  void _onAccessUnit(H264AccessUnit au, RtspFmp4Muxer muxer) {
    _firstRtpTimestamp90k ??= au.rtpTimestamp90k;
    _ensureInitSegmentSent(muxer);

    // Duration for this fragment: gap to the previous access unit's timestamp (90kHz ticks),
    // clamped to a sane default (this camera targets ~20fps -> ~4500 ticks) for the very first
    // frame, where there's no previous timestamp to diff against.
    const defaultDurationTicks = 4500;
    final baseMediaDecodeTime = au.rtpTimestamp90k - _firstRtpTimestamp90k!;
    final durationTicks = _lastRtpTimestamp90k == null
        ? defaultDurationTicks
        : (au.rtpTimestamp90k - _lastRtpTimestamp90k!).clamp(1, 90000);
    _lastRtpTimestamp90k = au.rtpTimestamp90k;

    // [AI Fix] 2026-09-02, BUG-024 real root cause found via direct `ffprobe`/`ffmpeg` testing
    // on this PC (bypassing the phone entirely -- see BUG-017's Iteration 2 for the full
    // writeup): `ffprobe -show_frames` against this exact camera correctly decodes access unit
    // #1 as `key_frame=1, pict_type=I` -- the underlying H.264 bitstream is completely valid and
    // really is an I-frame, regardless of what `nal_unit_type` the wire reports. ffmpeg
    // determines this from the slice header's own `slice_type` field, not from the NAL header's
    // type bits -- `au.isKeyframe` (derived purely from `nal_unit_type==5`) was never a reliable
    // signal for this camera's encoder in the first place, and chasing the camera into emitting
    // a "correct" NAL type was solving the wrong layer. The camera's own server-side logic
    // (`prvFindStartIndices()`, module_rtsps.c) already guarantees every fresh `PLAY` starts
    // exactly at a real keyframe -- so access unit #1 of every session is unconditionally the
    // sync sample, independent of the wire's NAL type. ExoPlayer trusts `trun`'s
    // `sample_is_non_sync_sample` flag directly and never re-parses the bitstream itself, so
    // this is the one place that actually needs to be correct.
    final isKeyframe = _accessUnitCount == 0 || au.isKeyframe;
    // [AI Fix] 2026-09-02 -- REVERTED same day: a follow-up attempt here rewrote this access
    // unit's own NALU header (nal_unit_type 1->5) to match the container-level flag above,
    // reasoning MediaCodec might independently distrust a nal_unit_type=1 slice marked as a sync
    // sample. That was wrong and made things worse: real-hardware logcat showed the decoder
    // accepting every input frame but emitting `NO_OUTPUT work returned` forever (650+ frames,
    // zero decoded output) -- a silent internal jam, not a hard error. Root cause: an IDR slice's
    // header is not just a non-IDR slice with a different NAL type byte -- H.264 mandates an
    // extra syntax element (idr_pic_id) that only exists in a genuine IDR slice's own bitstream,
    // right after fields a non-IDR slice's header also has. Flipping only the outer NAL header
    // byte left the decoder expecting IDR-shaped bits it never actually received, desyncing its
    // own slice-header parsing from that point on -- exactly why `ffmpeg`'s own successful
    // decode (BUG-024 Iteration 2) never hit this: it parsed the slice using its REAL
    // nal_unit_type (1, non-IDR) and derived pict_type from slice_type alone, never reinterpreting
    // the bits as IDR-formatted. Leaving the NALU bytes untouched -- `isKeyframe` above (the
    // container-level trun flag) is the only lever that should exist here.
    if (isKeyframe) {
      // [AI Fix] 2026-09-02 diagnostic instrumentation: a PC-side capture of this proxy's own
      // HTTP output (via `adb forward` + curl) proved every ordinary fragment's trun/mdat
      // structure is byte-perfect, but that capture joined the session after the real access
      // unit #1 had already been sent to the phone's own player, so the forced-keyframe
      // fragment itself was never directly inspected. Dump its raw NALU bytes here instead --
      // reaches logcat on every future keyframe-forced fragment (just #1 per session in
      // practice), no PC-side race needed. Remove once root-caused.
      final dumpLen = au.nalu.length < 32 ? au.nalu.length : 32;
      final hex = au.nalu
          .sublist(0, dumpLen)
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join(' ');
      debugPrint(
        '[RtspRemuxProxy] KEYFRAME fragment nalu: length=${au.nalu.length} first32=$hex',
      );
    }
    final fragment = muxer.fragment(
      nalu: au.nalu,
      baseMediaDecodeTime90k: baseMediaDecodeTime,
      durationTicks: durationTicks,
      isKeyframe: isKeyframe,
    );
    // BUG-022 follow-up 2026-09-01: HttpResponse.add() buffers internally -- without an
    // explicit flush(), written bytes weren't guaranteed to actually reach the client's socket
    // promptly. See _writeToResponse's doc above for why this now goes through a per-response
    // write chain instead of a bare add()+unawaited(flush()) pair.
    for (final r in _activeResponses) {
      unawaited(_writeToResponse(r, fragment));
    }

    _accessUnitCount++;
    if (_accessUnitCount <= 5 || _accessUnitCount % 20 == 0) {
      debugPrint(
        '[RtspRemuxProxy] access unit #$_accessUnitCount: ${au.nalu.length} bytes, '
        'keyframe=$isKeyframe (wire nal_type flag was ${au.isKeyframe}), rtpTs=${au.rtpTimestamp90k}, sent to '
        '${_activeResponses.length} client(s)',
      );
    }

    final elapsedSeconds = baseMediaDecodeTime ~/ RtspFmp4Muxer.timescale;
    lastKnownPositionEpochSeconds =
        (seekToEpochSeconds ?? clipEpochStart) + elapsedSeconds;
  }

  int _audioAccessUnitCount = 0;

  /// 2026-09-02, `FR-MOB-114` audio playback -- mirrors [_onAccessUnit]'s own shape exactly, but
  /// for the audio track (`muxer.audioFragment`, track_ID=2) and in the audio clock (this
  /// track's own sample rate, not video's 90kHz -- see [RtspFmp4Muxer.audioFragment]'s own doc).
  /// Every AAC access unit is independently decodable, so there's no keyframe-forcing question
  /// here the way [_onAccessUnit] has for video.
  void _onAudioAccessUnit(AacAccessUnit au, RtspFmp4Muxer muxer) {
    _firstAudioRtpTimestamp ??= au.rtpTimestamp;
    _ensureInitSegmentSent(muxer);

    const defaultDurationTicks =
        1024; // one AAC frame's worth of samples, the common case
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
        '[RtspRemuxProxy] audio access unit #$_audioAccessUnitCount: ${au.aac.length} bytes, '
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

  /// Tears down the RTSP session (`TEARDOWN`, releasing the camera's playback slot) and the
  /// local HTTP server. Safe to call more than once.
  Future<void> stop() async {
    debugPrint(
      '[RtspRemuxProxy] stop() -- accessUnitCount=$_accessUnitCount, '
      'lastKnownPositionEpochSeconds=$lastKnownPositionEpochSeconds',
    );
    await _accessUnitSub?.cancel();
    await _audioAccessUnitSub?.cancel();
    _closeAllResponses();
    await _rtsp?.close();
    await _server?.close(force: true);
    debugPrint('[RtspRemuxProxy] stop() complete');
  }

  static ({int width, int height})? _parseSpsDimensions(List<int> sps) {
    // Full SPS parsing (Exp-Golomb bitstream) is out of scope for this use case -- this camera's
    // playback resolution is already known ahead of time from GetRecordings/the live encoder
    // config, so [start] falls back to a fixed default (2560x1440, this device's configured
    // resolution) rather than parsing it out of the SPS bitstream here. Kept as an explicit
    // named function (returning null) rather than inlining the fallback, so a future real parser
    // has an obvious place to live without touching call sites.
    return null;
  }
}
