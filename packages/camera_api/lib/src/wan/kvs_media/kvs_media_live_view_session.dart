import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../../media/fmp4_muxer.dart';
import 'kvs_get_media_client.dart';
import 'kvs_media_viewer_credentials_client.dart';
import 'mkv_demuxer.dart';

/// One WAN playback session: fetches short-lived [KvsMediaViewerCredentials], opens a direct
/// `GetMedia` connection to AWS KVS, demuxes the raw MKV stream ([MkvDemuxer]), remuxes it into
/// fMP4, and serves that over a local HTTP loopback server — the WAN counterpart of
/// `mobile_app`'s `RtspRemuxProxy`/`RtspLiveViewProxy` (LAN RTSP playback), same overall shape
/// (`video_player`/ExoPlayer plays the local loopback URL as an ordinary progressive/live fMP4
/// source).
///
/// **Reuses [RtspFmp4Muxer] directly, not a second muxer implementation** (`kvs_fmp4_muxer.dart`,
/// deleted 2026-09-18). Direct user hardware report: WAN medium-quality video played the first
/// frame then permanently froze (audio kept advancing) — narrowed down over several real-hardware
/// test cycles to something in `KvsFmp4Muxer`'s own box construction, never conclusively pinned to
/// one specific field despite the SPS bytes and every sample's AVCC framing both being
/// independently verified byte-correct (direct comparison against a live RTSP capture of the same
/// stream, plus manual SPS bit-level decoding). Per direct user instruction, rather than keep
/// guessing at individual box fields, this now reuses `RtspFmp4Muxer` -- the implementation
/// already proven correct on real hardware for this exact "live, unbounded fMP4 over local HTTP
/// loopback" shape (both LAN live view and LAN recorded-clip playback use it). The real KVS
/// `GetMedia`/[MkvDemuxer] data path is completely unchanged -- only the final "turn already-
/// demuxed samples into fMP4 boxes" step now goes through the same code LAN RTSP uses, instead of
/// a second, subtly-different implementation.
///
/// [RtspFmp4Muxer.fragment] expects exactly one bare NALU per call (no length prefix, no
/// parameter-set NALUs — those go into the init segment's `avcC`/`hvcC` only), matching
/// `RtspLiveViewSession._emitH264AccessUnit`'s own filtering exactly. A KVS [MkvSample] can bundle
/// several NALUs together (a keyframe's SPS+PPS+IDR as one length-prefixed AVCC blob, see
/// [MkvSample]'s own doc) — [_onSample] below splits each sample into its individual NALUs and
/// applies the identical parameter-set filter before handing anything to the muxer.
///
/// **Replaces `GetHLSStreamingSessionURL`-based WAN playback entirely** (2026-09-17) — not just
/// for H.265 (which AWS rejects outright at that API:
/// `UnsupportedStreamMediaTypeException`/`GetDASHStreamingSessionURL` has the identical
/// restriction despite more permissive-sounding prose, both confirmed against the real AWS API
/// docs) but for H.264 too, so the app has exactly one WAN playback code path regardless of
/// codec — one health-check/reconnect/error-handling implementation instead of two. See
/// `kb/raw/2026-09-17-code-kvs-media-viewer-credential-vending.md` for the full reasoning and
/// live end-to-end verification (`kvs_media_viewer_credentials_test.py`, 4/4 PASS against real
/// AWS, both codecs) this replacement is based on.
///
/// **One session instance per playback attempt** — deliberately not reusable across reconnects,
/// same convention as `RtspRemuxProxy`. On any disconnect/error, the caller is responsible for
/// constructing a fresh instance (existing WAN retry logic in `LiveViewController` already
/// handles this at a higher level).
class KvsMediaLiveViewSession {
  KvsMediaLiveViewSession({
    required this.streamName,
    KvsMediaViewerCredentialsClient? credentialsClient,
    KvsGetMediaClient? getMediaClient,
    this.credentialRefreshMargin = const Duration(seconds: 60),
    this.maxReconnectAttempts = 3,
    this.reconnectBackoff = const Duration(seconds: 1),
    this.maxPendingBytesPerClient = 2 * 1024 * 1024,
  }) : _credentialsClient =
           credentialsClient ?? KvsMediaViewerCredentialsClient(),
       _getMediaClient = getMediaClient ?? KvsGetMediaClient();

  /// The `GetMedia` connection is proactively replaced with one signed by freshly vended
  /// credentials this long before the current credentials expire.
  final Duration credentialRefreshMargin;

  /// Consecutive failed (re)connect attempts — including connections that end before delivering
  /// a single sample — before the session gives up and sets [isSessionEnded].
  final int maxReconnectAttempts;

  /// Delay before reconnect attempt N is `reconnectBackoff * 2^(N-1)`.
  final Duration reconnectBackoff;

  /// Per-HTTP-client cap on bytes queued for a slow reader. Beyond it, non-keyframe video (and
  /// audio) fragments are dropped for that client until the next keyframe, bounding memory on an
  /// unbounded live stream.
  final int maxPendingBytesPerClient;

  /// Full per-quality KVS stream name (`"<thingName>-<quality>"`, e.g. `VZL-CAM-000001-high`).
  final String streamName;

  final KvsMediaViewerCredentialsClient _credentialsClient;
  final KvsGetMediaClient _getMediaClient;

  HttpServer? _server;
  MkvDemuxer? _demuxer;
  StreamSubscription<List<int>>? _mediaSub;
  StreamSubscription<MkvEvent>? _eventSub;
  RtspFmp4Muxer? _muxer;
  final List<HttpResponse> _activeResponses = [];
  final Map<HttpResponse, Future<void>> _writeChains = {};
  final Map<HttpResponse, int> _pendingBytes = {};
  final Set<HttpResponse> _awaitingKeyframe = {};

  KvsMediaViewerCredentials? _credentials;
  Timer? _refreshTimer;
  int _connectionGeneration = 0;
  int _consecutiveFailures = 0;
  bool _reconnecting = false;

  bool _sessionEnded = false;
  bool get isSessionEnded => _sessionEnded;

  /// Ground-truth "is real media still arriving off the wire" signal — mirrors
  /// `RtspLiveViewSession.lastPacketAt` (`BUG-030`). Updated every time a real video *or* audio
  /// sample is demuxed from the `GetMedia` stream, regardless of whether `video_player`'s own
  /// reported position looks like it's advancing. The screen-level stall poller
  /// (`LiveViewScreen._pollWanStall`) must check this before trusting the position heuristic —
  /// omitting that check for the WAN/KVS path (leaving it wired only for the LAN RTSP path) is
  /// exactly what let a perfectly healthy KVS session get torn down/reconnected every ~20s.
  DateTime? lastSampleAt;

  Uint8List? _initSegmentBytes;

  // Track numbers from the Tracks element — [RtspFmp4Muxer] itself is transport-agnostic and
  // carries no notion of an MKV track number, unlike the deleted `KvsFmp4Muxer`, which stored
  // the whole `MkvTrackInfo` for this purpose.
  int? _videoTrackNumber;
  int? _audioTrackNumber;
  bool _isHevc = false;
  int? _audioSampleRate;

  int? _firstVideoTimestampMs;
  int? _lastVideoTimestampMs;
  int? _firstAudioTimestampMs;
  int? _lastAudioTimestampMs;
  int _videoSampleCount = 0;

  /// The local URL to hand to `VideoPlayerController.networkUrl()` — set once [start] completes.
  Uri? url;

  void Function(String message)? onLog;
  void _log(String message) =>
      onLog?.call('[KvsMediaLiveViewSession] $message');

  /// Fetches credentials, opens the `GetMedia` connection, and starts the local HTTP server.
  /// Throws if credential vending or the initial `GetMedia` request fails — surfaced to the
  /// caller before any local server exists. Demuxing/remuxing/serving happens in the background
  /// from here on.
  Future<void> start() async {
    final mediaStream = await _openStream();
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    url = Uri.parse('http://127.0.0.1:${_server!.port}/stream.mp4');
    _log('loopback server bound at $url');
    unawaited(_serveHttp());
    _attach(mediaStream);
  }

  /// Vends credentials if none are held or they are about to expire, then opens `GetMedia`.
  Future<Stream<List<int>>> _openStream() async {
    var credentials = _credentials;
    if (credentials == null ||
        credentials.isExpiringSoon(margin: credentialRefreshMargin)) {
      credentials = await _credentialsClient.getCredentials(streamName);
      _credentials = credentials;
      _log(
        'vended credentials for $streamName, dataEndpoint=${credentials.dataEndpoint}, '
        'expires=${credentials.expiration}',
      );
    }
    final stream = await _getMediaClient.getMedia(
      credentials: credentials,
      streamName: streamName,
    );
    _scheduleRefresh(credentials);
    return stream;
  }

  void _scheduleRefresh(KvsMediaViewerCredentials credentials) {
    _refreshTimer?.cancel();
    var delay =
        credentials.expiration.difference(DateTime.now().toUtc()) -
        credentialRefreshMargin;
    if (delay < const Duration(seconds: 1)) delay = const Duration(seconds: 1);
    _refreshTimer = Timer(delay, () {
      _log(
        'credentials near expiry — re-establishing GetMedia with fresh credentials',
      );
      _credentials = null;
      unawaited(_reconnect(countAsFailure: false));
    });
  }

  /// Wires a fresh `GetMedia` byte stream into a new demuxer, retiring any previous connection.
  /// The muxer, init segment and HTTP clients survive, so the player sees one continuous stream.
  void _attach(Stream<List<int>> mediaStream) {
    final generation = ++_connectionGeneration;
    _mediaSub?.cancel();
    _eventSub?.cancel();
    _demuxer?.close();

    final demuxer = MkvDemuxer();
    _demuxer = demuxer;
    _eventSub = demuxer.events.listen(
      _onMkvEvent,
      onError: (Object e) {
        _log('demuxer error: $e');
      },
    );
    _mediaSub = mediaStream.listen(
      (chunk) {
        if (generation == _connectionGeneration) {
          demuxer.addChunk(Uint8List.fromList(chunk));
        }
      },
      onError: (Object e) {
        if (generation != _connectionGeneration) return;
        _log('GetMedia stream error: $e');
        unawaited(_reconnect(countAsFailure: true));
      },
      onDone: () {
        if (generation != _connectionGeneration) return;
        _log(
          'GetMedia stream ended (TTL, camera stopped streaming, or connection lost)',
        );
        unawaited(
          _reconnect(countAsFailure: _lastSampleOnThisConnection == null),
        );
      },
    );
    _lastSampleOnThisConnection = null;
  }

  DateTime? _lastSampleOnThisConnection;

  Future<void> _reconnect({required bool countAsFailure}) async {
    if (_sessionEnded || _reconnecting) return;
    _reconnecting = true;
    try {
      if (countAsFailure) _consecutiveFailures++;
      while (!_sessionEnded) {
        if (_consecutiveFailures > maxReconnectAttempts) {
          _log(
            'giving up after $_consecutiveFailures consecutive failed GetMedia attempts',
          );
          _sessionEnded = true;
          _refreshTimer?.cancel();
          _closeAllResponses();
          return;
        }
        if (_consecutiveFailures > 0) {
          await Future<void>.delayed(
            reconnectBackoff * (1 << (_consecutiveFailures - 1)),
          );
          if (_sessionEnded) return;
        }
        try {
          final stream = await _openStream();
          if (_sessionEnded) return;
          _attach(stream);
          _log('GetMedia re-established');
          return;
        } catch (e) {
          _log('GetMedia reconnect failed: $e');
          _credentials = null;
          _consecutiveFailures++;
        }
      }
    } finally {
      _reconnecting = false;
    }
  }

  void _onMkvEvent(MkvEvent event) {
    if (event is MkvTracksReady) {
      final video = event.video;
      if (video == null) {
        _log(
          'Tracks ready but no video track found — cannot build init segment',
        );
        return;
      }
      final audio = event.audio;
      _videoTrackNumber = video.trackNumber;
      _audioTrackNumber = audio?.trackNumber;
      if (_muxer != null) {
        _log(
          'Tracks re-announced after reconnect — keeping existing init segment',
        );
        return;
      }
      _isHevc = video.isHevc;
      _audioSampleRate = audio?.samplingFrequency;

      final params = _extractParamSets(video);
      _muxer = RtspFmp4Muxer(
        sps: params.sps,
        pps: params.pps,
        width: video.width ?? 0,
        height: video.height ?? 0,
        videoCodec: _isHevc ? VideoCodec.h265 : VideoCodec.h264,
        vps: params.vps,
        audioSpecificConfig: audio?.codecPrivate,
        audioSampleRate: audio?.samplingFrequency,
        audioChannelCount: audio?.channels,
        // Genuinely live/unbounded — leaving this null (duration 0) is exactly the "unbounded
        // live content" signal ExoPlayer needs, same as `RtspLiveViewProxy`'s own proven-working
        // convention. A first attempt at this bug gave it a large placeholder duration instead,
        // reasoning from `BUG-029` -- wrongly (that bug was the opposite situation, a *bounded*
        // clip wrongly treated as live). A real-hardware re-test confirmed the misdiagnosis: the
        // placeholder duration made `VideoPlayerController.value.position` advance, but at
        // roughly 1/8th real-time speed (ExoPlayer switching into VOD-style buffering, which a
        // near-real-time trickle of data can't fill fast enough) -- not a fix, just a different
        // symptom. Reverted; never set this to a non-null value again without a specific,
        // hardware-tested reason.
        totalDurationSeconds: null,
      );
      _initSegmentBytes = _muxer!.initSegment();
      _log(
        'init segment built (${_initSegmentBytes!.length} bytes), video=${video.codecId} '
        '${video.width}x${video.height}, audio=${audio?.codecId ?? 'none'}',
      );
      for (final r in _activeResponses) {
        unawaited(_writeToResponse(r, _initSegmentBytes!));
      }
      return;
    }
    if (event is MkvSample) {
      _onSample(event);
    }
  }

  void _onSample(MkvSample sample) {
    final muxer = _muxer;
    if (muxer == null) {
      return; // shouldn't happen — Tracks always precedes samples on this wire
    }

    final isVideo = sample.trackNumber == _videoTrackNumber;
    final isAudio =
        _audioTrackNumber != null && sample.trackNumber == _audioTrackNumber;
    if (!isVideo && !isAudio) return;

    lastSampleAt = DateTime.now();
    _lastSampleOnThisConnection = lastSampleAt;
    _consecutiveFailures = 0;

    if (isVideo) {
      _firstVideoTimestampMs ??= sample.timestampMs;
      const defaultDurationMs = 50; // ~20fps fallback for the very first frame
      final durationMs = _lastVideoTimestampMs == null
          ? defaultDurationMs
          : (sample.timestampMs - _lastVideoTimestampMs!).clamp(1, 5000);
      _lastVideoTimestampMs = sample.timestampMs;
      final baseMs = sample.timestampMs - _firstVideoTimestampMs!;
      final isKeyframe = _videoSampleCount == 0 || sample.isKeyframe;

      // [RtspFmp4Muxer]'s own timescale is 90000 (the RTP clock) -- convert this session's
      // millisecond-based timestamps once, here, rather than changing the muxer's public API.
      final baseMediaDecodeTime90k = baseMs * 90;
      final durationTicks = durationMs * 90;

      for (final nalu in _splitAvccNalus(sample.data)) {
        if (nalu.isEmpty) continue;
        final nalType = _naluType(nalu, isHevc: _isHevc);
        if (_isParameterSetNalu(nalType, isHevc: _isHevc)) {
          // SPS/PPS/VPS/AUD/SEI -- already baked into the init segment's avcC/hvcC (or, for
          // VPS, never advertised at all -- see RtspFmp4Muxer's own doc), never resent as an
          // ongoing fMP4 sample. Mirrors RtspLiveViewSession._emitH264AccessUnit's/
          // _emitOrCaptureH265Nalu's identical filter exactly.
          continue;
        }
        final fragment = muxer.fragment(
          nalu: nalu,
          baseMediaDecodeTime90k: baseMediaDecodeTime90k,
          durationTicks: durationTicks,
          isKeyframe: isKeyframe,
        );
        _broadcast(fragment, isVideo: true, isKeyframe: isKeyframe);
      }
      _videoSampleCount++;
    } else {
      _firstAudioTimestampMs ??= sample.timestampMs;
      const defaultDurationMs =
          23; // one ~1024-sample AAC frame at 44.1kHz, rounded
      final durationMs = _lastAudioTimestampMs == null
          ? defaultDurationMs
          : (sample.timestampMs - _lastAudioTimestampMs!).clamp(1, 5000);
      _lastAudioTimestampMs = sample.timestampMs;
      final baseMs = sample.timestampMs - _firstAudioTimestampMs!;

      // The audio track's own mdhd.timescale is its real sample rate (e.g. 8000Hz), not
      // milliseconds -- RtspFmp4Muxer.audioFragment's own doc says its tick params are "in this
      // track's OWN timescale" (RTSP's RTP audio clock already ticks natively at the sample
      // rate, so that path never needed a conversion). This session's timestamps are
      // milliseconds throughout (KVS's own Cluster timecodes, confirmed real epoch-ms), so they
      // need converting here -- ms * sampleRate / 1000.
      final sampleRate = _audioSampleRate ?? 8000;
      final baseMediaDecodeTimeAudioTicks = (baseMs * sampleRate) ~/ 1000;
      final durationTicks = ((durationMs * sampleRate) ~/ 1000).clamp(
        1,
        sampleRate,
      );

      final fragment = muxer.audioFragment(
        aac: sample.data,
        baseMediaDecodeTimeAudioTicks: baseMediaDecodeTimeAudioTicks,
        durationTicks: durationTicks,
      );
      _broadcast(fragment, isVideo: false, isKeyframe: false);
    }
  }

  /// Sends a media fragment to every client, dropping it for any client whose queue is over
  /// [maxPendingBytesPerClient]. A dropped video fragment poisons the decode until the next
  /// keyframe, so that client skips all non-keyframe video until one arrives.
  void _broadcast(
    List<int> fragment, {
    required bool isVideo,
    required bool isKeyframe,
  }) {
    for (final r in List.of(_activeResponses)) {
      if (isVideo && isKeyframe) {
        _awaitingKeyframe.remove(r);
      } else if (isVideo && _awaitingKeyframe.contains(r)) {
        continue;
      }
      if ((_pendingBytes[r] ?? 0) > maxPendingBytesPerClient) {
        if (isVideo && isKeyframe) {
          // Keyframes are never dropped — the queue is bounded by the next drop cycle.
        } else {
          if (isVideo) _awaitingKeyframe.add(r);
          continue;
        }
      }
      unawaited(_writeToResponse(r, fragment));
    }
  }

  /// Splits an AVCC-formatted byte blob (a sequence of `[4-byte big-endian length][NALU bytes]`
  /// — [MkvSample.data]'s own documented shape for a video track) into its individual NALUs,
  /// stripping the length prefixes. Malformed trailing data (a truncated final length/NALU) is
  /// silently dropped rather than throwing — matches [MkvDemuxer]'s own "drop, don't crash on a
  /// malformed tail" convention elsewhere.
  static List<Uint8List> _splitAvccNalus(Uint8List data) {
    final nalus = <Uint8List>[];
    var pos = 0;
    while (pos + 4 <= data.length) {
      final len =
          (data[pos] << 24) |
          (data[pos + 1] << 16) |
          (data[pos + 2] << 8) |
          data[pos + 3];
      pos += 4;
      if (len <= 0 || pos + len > data.length) break;
      nalus.add(Uint8List.sublistView(data, pos, pos + len));
      pos += len;
    }
    return nalus;
  }

  static int _naluType(Uint8List nalu, {required bool isHevc}) =>
      isHevc ? (nalu[0] >> 1) & 0x3F : nalu[0] & 0x1F;

  /// Same NALU types `RtspLiveViewSession` already excludes from its own ongoing per-frame
  /// stream (`_emitH264AccessUnit`/`_emitOrCaptureH265Nalu`) — parameter sets and non-VCL units
  /// that only ever belong in the init segment's `avcC`/`hvcC`, never as an fMP4 sample of their
  /// own. H.264: SEI(6)/SPS(7)/PPS(8)/AUD(9). H.265: VPS(32)/SPS(33)/PPS(34)/AUD(35)/
  /// SEI-prefix(39)/SEI-suffix(40).
  static bool _isParameterSetNalu(int nalType, {required bool isHevc}) => isHevc
      ? (nalType == 32 ||
            nalType == 33 ||
            nalType == 34 ||
            nalType == 35 ||
            nalType == 39 ||
            nalType == 40)
      : (nalType == 6 || nalType == 7 || nalType == 8 || nalType == 9);

  Future<void> _serveHttp() async {
    await for (final request in _server!) {
      if (request.method != 'GET') {
        request.response.statusCode = HttpStatus.methodNotAllowed;
        await request.response.close();
        continue;
      }
      if (_sessionEnded) {
        await request.response.close();
        continue;
      }
      _log('HTTP client connected (${_activeResponses.length + 1} active)');
      request.response.headers.contentType = ContentType('video', 'mp4');
      if (_initSegmentBytes != null) {
        unawaited(_writeToResponse(request.response, _initSegmentBytes!));
      }
      _activeResponses.add(request.response);
      unawaited(
        request.response.done.catchError((Object _) {}).whenComplete(() {
          _log('HTTP client disconnected');
          _activeResponses.remove(request.response);
          _writeChains.remove(request.response);
          _pendingBytes.remove(request.response);
          _awaitingKeyframe.remove(request.response);
        }),
      );
    }
  }

  /// Chains writes per response so two writes to the same socket never overlap — same real bug
  /// class `RtspRemuxProxy._writeToResponse` was fixed for (an un-awaited `flush()` racing the
  /// next `add()` throws `StreamSink is bound to a stream`, silently dropping a write).
  Future<void> _writeToResponse(HttpResponse r, List<int> bytes) {
    final previous = _writeChains[r] ?? Future<void>.value();
    _pendingBytes[r] = (_pendingBytes[r] ?? 0) + bytes.length;
    final next = previous
        .then((_) async {
          r.add(bytes);
          await r.flush();
        })
        .catchError((Object e, StackTrace st) {
          _log('write to client failed: $e');
        })
        .whenComplete(() {
          final left = (_pendingBytes[r] ?? 0) - bytes.length;
          if (left > 0) {
            _pendingBytes[r] = left;
          } else {
            _pendingBytes.remove(r);
          }
        });
    _writeChains[r] = next;
    return next;
  }

  void _closeAllResponses() {
    for (final r in List.of(_activeResponses)) {
      r.close().catchError((Object _) {});
    }
    _activeResponses.clear();
    _writeChains.clear();
    _pendingBytes.clear();
    _awaitingKeyframe.clear();
  }

  /// Tears down the `GetMedia` connection and the local HTTP server. Safe to call more than once.
  Future<void> stop() async {
    _log('stop() — videoSampleCount=$_videoSampleCount');
    _sessionEnded = true;
    _connectionGeneration++;
    _refreshTimer?.cancel();
    await _mediaSub?.cancel();
    await _eventSub?.cancel();
    await _demuxer?.close();
    _closeAllResponses();
    _getMediaClient.close();
    await _server?.close(force: true);
    _log('stop() complete');
  }
}

class _ParamSets {
  const _ParamSets({required this.sps, required this.pps, this.vps});
  final Uint8List sps;
  final Uint8List pps;
  final Uint8List? vps;
}

/// Extracts the raw parameter-set NALUs (no length prefix, no start code) [RtspFmp4Muxer]'s
/// constructor expects, directly out of [MkvTrackInfo.codecPrivate] — an already-valid
/// ISO/IEC 14496-15 `avcC`/`hvcC` blob (see [MkvTrackInfo]'s own doc). Byte layouts verified
/// directly against this camera's own firmware builders
/// (`Mkv_generateH264CodecPrivateDataFromAnnexBNalus`/`prvGenerateH265CodecPrivateDataFromParams`,
/// `module_kvs_producer.c`) and against real captured `GetMedia` bytes.
_ParamSets _extractParamSets(MkvTrackInfo video) {
  final cp = video.codecPrivate;
  if (video.isHevc) {
    // HEVCDecoderConfigurationRecord (ISO/IEC 14496-15 §8.3.3.1): a fixed 22-byte header, then
    // numOfArrays(1 byte), then per array: NAL_unit_type(1 byte, low 6 bits) + numNalus(2 bytes)
    // + per NALU: length(2 bytes) + bytes. This camera's own array order is always VPS/SPS/PPS,
    // exactly one NALU per array (module_kvs_producer.c's prvGenerateH265CodecPrivateDataFrom
    // Params) -- but this walk doesn't assume the order, just collects by NAL_unit_type.
    if (cp.length < 23) {
      throw StateError('hvcC blob too short: ${cp.length} bytes');
    }
    var pos = 22;
    final numArrays = cp[pos];
    pos += 1;
    Uint8List? vps, sps, pps;
    for (var a = 0; a < numArrays; a++) {
      final nalType = cp[pos] & 0x3F;
      pos += 1;
      final numNalus = (cp[pos] << 8) | cp[pos + 1];
      pos += 2;
      for (var n = 0; n < numNalus; n++) {
        final len = (cp[pos] << 8) | cp[pos + 1];
        pos += 2;
        final nalu = Uint8List.sublistView(cp, pos, pos + len);
        pos += len;
        if (nalType == 32) {
          vps = nalu;
        } else if (nalType == 33) {
          sps = nalu;
        } else if (nalType == 34) {
          pps = nalu;
        }
      }
    }
    if (sps == null || pps == null || vps == null) {
      throw StateError('hvcC missing VPS/SPS/PPS array(s)');
    }
    return _ParamSets(sps: sps, pps: pps, vps: vps);
  }

  // AVCDecoderConfigurationRecord (ISO/IEC 14496-15 §5.2.4.1): configurationVersion(1) +
  // AVCProfileIndication(1) + profile_compatibility(1) + AVCLevelIndication(1) +
  // lengthSizeMinusOne(1, low 2 bits) + numOfSequenceParameterSets(1, low 5 bits), then per SPS:
  // length(2 bytes) + bytes; then numOfPictureParameterSets(1 byte), then per PPS: length(2
  // bytes) + bytes.
  if (cp.length < 6) {
    throw StateError('avcC blob too short: ${cp.length} bytes');
  }
  var pos = 5;
  final numSps = cp[pos] & 0x1F;
  pos += 1;
  if (numSps < 1) {
    throw StateError('avcC declares zero SPS entries');
  }
  var spsLen = (cp[pos] << 8) | cp[pos + 1];
  pos += 2;
  final sps = Uint8List.sublistView(cp, pos, pos + spsLen);
  pos += spsLen;
  for (var i = 1; i < numSps; i++) {
    // Never observed >1 SPS from this producer, but don't assume — skip any extras correctly.
    spsLen = (cp[pos] << 8) | cp[pos + 1];
    pos += 2 + spsLen;
  }
  final numPps = cp[pos];
  pos += 1;
  if (numPps < 1) {
    throw StateError('avcC declares zero PPS entries');
  }
  final ppsLen = (cp[pos] << 8) | cp[pos + 1];
  pos += 2;
  final pps = Uint8List.sublistView(cp, pos, pos + ppsLen);
  return _ParamSets(sps: sps, pps: pps);
}
