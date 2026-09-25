import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:camera_api/camera_api.dart' show VideoCodec;
import 'package:crypto/crypto.dart' show md5;
import 'package:flutter/foundation.dart' show debugPrint;

/// One reconstructed H.264 access unit read off the camera's RTSPS playback session — this
/// firmware's `RTSPS_SendH264Frame()` (`module_rtsps.c`) sends exactly one NALU per input
/// sample, so in practice this is always exactly one NALU (a slice), never SPS/PPS (those are
/// only ever carried out-of-band, via `DESCRIBE`'s SDP `sprop-parameter-sets` — see
/// [RtspReplaySession.sps]/[RtspReplaySession.pps]). [nalu] is the raw NALU bytes (starting with
/// the NAL header byte itself, no start code and no length prefix — [RtspFmp4Muxer] adds the
/// length prefix an `avc1` sample entry requires).
class H264AccessUnit {
  const H264AccessUnit({
    required this.nalu,
    required this.rtpTimestamp90k,
    required this.isKeyframe,
  });

  final Uint8List nalu;

  /// The RTP 90kHz-clock timestamp this access unit arrived under — directly comparable across
  /// packets within one session (this camera's own packetizer uses `timestamp_ms * 90`, see
  /// `RTSPS_SendH264Frame()`), and the only server-side-authoritative position signal available
  /// (not the client player's own, possibly-buffered, position).
  final int rtpTimestamp90k;

  final bool isKeyframe;
}

/// 2026-09-02, `FR-MOB-114` audio playback: one raw AAC access unit read off the camera's audio
/// RTP channel (RFC 3640, "AAC-hbr" mode — the exact payload format `module_rtsps.c`'s DESCRIBE
/// SDP already advertises via `a=fmtp:... mode=AAC-hbr;sizelength=13;indexlength=3;
/// indexdeltalength=3`, once `BUG-017`-adjacent playback_demuxer_bind.c actually populates a
/// clip's audio info — see that fix's own doc for the "audio not audible at all" root cause).
/// [aac] is the raw AAC access unit bytes (no ADTS header, no RTP AU-header — [RtspFmp4Muxer]'s
/// audio track expects raw AAC per ISO/IEC 14496-3, matching what an `mp4a` sample entry stores).
class AacAccessUnit {
  const AacAccessUnit({required this.aac, required this.rtpTimestamp});

  final Uint8List aac;

  /// The RTP timestamp this access unit arrived under, at the AUDIO clock rate (see
  /// [RtspReplaySession.audioSampleRate] — NOT the video 90kHz clock H264AccessUnit uses).
  final int rtpTimestamp;
}

class RtspReplayException implements Exception {
  RtspReplayException(this.message);
  final String message;
  @override
  String toString() => 'RtspReplayException: $message';
}

/// A real RTSP/1.0-over-TLS client speaking exactly what `module_rtsps.c`'s playback listener
/// implements: `OPTIONS`/`DESCRIBE`/`SETUP`/`PLAY`/`TEARDOWN`, TCP-interleaved (`$`-framed) RTP,
/// and RFC 2617 Digest auth with no `qop` (`realm="ONVIF"`, `algorithm=MD5`) — ported faithfully
/// from `testing_utilities/playback_rtsp_test.py`'s `RtspsSession` (this project's own
/// hardware-verified reference for this exact protocol, written the same day
/// `rtsp_digest_auth.c`'s server-side implementation was, and re-verified hardware-side across
/// `BUG-011`/`012`/`013`/`015`) rather than re-deriving the protocol from scratch. See that
/// file's own class doc for the algorithm this mirrors:
/// `response = MD5(HA1:nonce:HA2)`, `HA1 = MD5(username:realm:password)`, `HA2 = MD5(method:uri)`.
///
/// Exists to replace `media_kit`/libmpv for this screen (`FR-MOB-114`) — see
/// `design/stages/mobile-app-android-3-video-image-pipeline/bugs/
/// 021-rtsp-spike-playback-blank-video-transport-mismatch.md` for why: ten iterations of
/// real-hardware-verified fixes (a genuine camera-firmware race, `BUG-015`, plus several real
/// client-side `media_kit`/`media_kit_video` bugs) still left decoded frames never reaching the
/// screen, isolated to `media_kit_video`'s own Android GPU/texture attachment — and separately,
/// this app needs to keep working on older Android versions than `media_kit`'s bundled native
/// builds comfortably support. This class plus [RtspFmp4Muxer] and `RtspRemuxProxy` let
/// `video_player`/ExoPlayer (already proven to render fine on this exact hardware, for both
/// WebRTC live view and recorded-clip playback) consume this RTSPS stream instead, by remuxing
/// it into fMP4 served over a local HTTP loopback.
class RtspReplaySession {
  RtspReplaySession._(
    this._socket,
    this._host,
    this._port,
    this._path,
    this._username,
    this._password,
  );

  final SecureSocket _socket;
  final String _host;
  final int _port;
  final String _path;
  final String _username;
  final String _password;

  int _cseq = 0;
  String? _nonce;
  Uint8List _recvBytes = Uint8List(0);
  int _recvOffset = 0;
  final StreamController<Uint8List> _incoming = StreamController<Uint8List>();
  StreamSubscription<Uint8List>? _socketSub;
  bool _played = false;
  bool _closed = false;

  /// Populated by [describe] — base64-decoded H.264 SPS (Annex-B start code stripped; see
  /// `_stripStartCode`), read from the SDP's `sprop-parameter-sets` — the only reliable source
  /// for these on this camera (in-band SPS/PPS NALUs are never sent over RTP, see this class's
  /// own top-level doc).
  Uint8List? sps;
  Uint8List? pps;

  /// Detected from the DESCRIBE SDP's `a=rtpmap:<pt>` line for the video
  /// track. Defaults to [VideoCodec.h264] until DESCRIBE actually runs.
  ///
  /// This camera records some clips as H.265, and the failure without this is
  /// silent and total: an H.265 clip's SDP carries `sprop-vps=`/`sprop-sps=`/
  /// `sprop-pps=` and no `sprop-parameter-sets`, so an H.264-only [_parseSdp]
  /// throws and the whole clip reports as "no recording available" even
  /// though it is right there on the camera.
  VideoCodec videoCodec = VideoCodec.h264;

  /// The video track's RTP payload type from the SDP's `m=video` line — this
  /// camera uses 96 today, but [_handleRtpPacket] checks this rather than
  /// hardcoding it.
  int? _videoPayloadType;

  /// H.265 only. Unlike live view, a recorded clip's SDP advertises VPS up
  /// front (a demuxed clip's sample data has no in-band VPS to fall back on),
  /// so this is normally set by [_parseSdp]. If the server ever omits it, it
  /// stays null until [_emitOrCaptureH265Nalu] captures an in-band one.
  Uint8List? vps;

  /// 2026-09-02, `FR-MOB-114` audio playback. Populated by [_parseSdp] only when the SDP's
  /// `m=audio` section is present (i.e. this clip actually has audio -- see
  /// `playback_demuxer_bind.c`'s `prvPopulateAudioInfoFromDemuxer()` for when the server omits
  /// it). `null` means no audio for this clip; every audio field below is only meaningful
  /// together with the others, never independently null once one is set.
  int? _audioPayloadType;
  int? audioSampleRate;
  int? audioChannelCount;

  /// AAC AudioSpecificConfig bytes (ISO/IEC 14496-3), decoded from the SDP `a=fmtp:PT config=`
  /// hex attribute -- exactly the 2 bytes `RtspFmp4Muxer`'s audio `esds` box needs, and
  /// exactly what `module_rtsps.c`'s own DESCRIBE handler already builds server-side (see its
  /// `aac_config` local -- this is the client-side mirror of that same value).
  Uint8List? audioSpecificConfig;

  bool get hasAudio => _audioPayloadType != null;

  /// Opens the TLS connection and performs `DESCRIBE`+`SETUP`+`PLAY` (with an optional seek), so
  /// callers get a single async factory that's either fully ready to stream or throws. [host]/
  /// [port]/[path] come from parsing `GetReplayUri`'s response URI (`rtsps://host:port/path`) —
  /// this class always sends its own request-line/Authorization `uri` field as `rtsp://host:port
  /// path` (no `s`), matching `playback_rtsp_test.py`'s own convention exactly; the server's
  /// `rtsp_digest_verify()` (`rtsp_digest_auth.c`) trusts whatever URI string the client supplies
  /// in its own `Authorization` header for its own hash recomputation (confirmed by reading that
  /// function directly) rather than independently reconstructing/validating it against the
  /// request line, so this is safe as long as it's used consistently -- which it is here.
  ///
  /// [seekToEpochSeconds], if given, is sent as `Range: clock=<ISO8601>-` (an absolute UTC
  /// wall-clock timestamp, per `PlaybackBind_ParseRangeClockHeader()` — NOT an `npt=` relative
  /// offset). Omit to play from the start of the clip [clipEpochStart] identifies.
  static Future<RtspReplaySession> open({
    required String host,
    required int port,
    required String path,
    required String username,
    required String password,
    required int clipEpochStart,
    int? seekToEpochSeconds,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final socket = await SecureSocket.connect(
      host,
      port,
      timeout: timeout,
      onBadCertificate: (_) =>
          true, // self-signed cert, same trust posture as createCameraHttpClient()
    );
    final session = RtspReplaySession._(
      socket,
      host,
      port,
      path,
      username,
      password,
    );
    session._socketSub = socket.listen(
      session._onSocketData,
      onError: (Object _) => session._incoming.close(),
      onDone: () => session._incoming.close(),
      cancelOnError: true,
    );

    try {
      final describeResp = await session._request('DESCRIBE', {
        'Accept': 'application/sdp',
      }, timeout);
      if (describeResp.status != 200) {
        throw RtspReplayException(
          'DESCRIBE failed: HTTP-style status ${describeResp.status}',
        );
      }
      session._parseSdp(utf8.decode(describeResp.body, allowMalformed: true));

      final setupResp = await session._request('SETUP', {
        'Transport': 'RTP/AVP/TCP;unicast;interleaved=0-1',
      }, timeout);
      if (setupResp.status != 200) {
        throw RtspReplayException('SETUP failed: status ${setupResp.status}');
      }

      // 2026-09-02, `FR-MOB-114` audio playback: a second, real SETUP for the audio track,
      // only when DESCRIBE's SDP actually advertised one (see `hasAudio`'s own doc comment).
      // module_rtsps.c's SETUP handler assigns channel 2-3 for any request whose line contains
      // "streamid=1" -- resolved here the same way `a=control:streamid=1` is meant to be,
      // against this session's own base path.
      if (session.hasAudio) {
        final audioSetupResp = await session._request(
          'SETUP',
          {'Transport': 'RTP/AVP/TCP;unicast;interleaved=2-3'},
          timeout,
          uriOverride: '${session._uri}/streamid=1',
        );
        if (audioSetupResp.status != 200) {
          // Non-fatal -- fall back to video-only playback rather than failing the whole
          // session over an audio-track SETUP failure the user would rather not lose video for.
          debugPrint(
            '[RtspReplaySession] audio SETUP failed: status ${audioSetupResp.status} '
            '-- continuing video-only',
          );
          session._audioPayloadType = null;
        }
      }

      final playHeaders = <String, String>{};
      if (seekToEpochSeconds != null) {
        playHeaders['Range'] =
            'clock=${_formatClockTimestamp(seekToEpochSeconds)}-';
      }
      final playResp = await session._request('PLAY', playHeaders, timeout);
      if (playResp.status != 200) {
        throw RtspReplayException('PLAY failed: status ${playResp.status}');
      }
      session._played = true;
      debugPrint(
        '[RtspReplaySession] PLAY 200 -- sps=${session.sps?.length ?? 0} bytes, '
        'pps=${session.pps?.length ?? 0} bytes, audio=${session.hasAudio ? '${session.audioSampleRate}Hz/${session.audioChannelCount}ch' : 'none'}, '
        'host=$host:$port$path'
        '${seekToEpochSeconds != null ? ", seekTo=$seekToEpochSeconds" : ""}',
      );
      return session;
    } catch (_) {
      await session.close();
      rethrow;
    }
  }

  /// `YYYY-MM-DDTHH:MM:SSZ`, exactly 19 chars before the trailing `Z` — the server's
  /// `PlaybackBind_ParseRangeClockHeader()` parses this by fixed width (`BUG-013`'s own fix), so
  /// this must NOT include fractional seconds the way `DateTime.toIso8601String()` would.
  static String _formatClockTimestamp(int epochSeconds) {
    final dt = DateTime.fromMillisecondsSinceEpoch(
      epochSeconds * 1000,
      isUtc: true,
    );
    String p2(int v) => v.toString().padLeft(2, '0');
    return '${dt.year.toString().padLeft(4, '0')}-${p2(dt.month)}-${p2(dt.day)}'
        'T${p2(dt.hour)}:${p2(dt.minute)}:${p2(dt.second)}Z';
  }

  void _onSocketData(Uint8List chunk) {
    if (!_incoming.isClosed) _incoming.add(chunk);
  }

  /// Access units read off the interleaved stream after `PLAY` — call [startReading] once, then
  /// listen to this. A fresh [H264AccessUnit] is emitted every time a complete NALU is
  /// reconstructed (either a single-packet NALU or a fully-reassembled FU-A sequence), matching
  /// `RTSPS_SendH264Frame()`'s own packetization scheme exactly (see that function's own comment
  /// for why marker-bit-per-NALU, not marker-bit-per-multi-NALU-frame, is the right completion
  /// signal here).
  final StreamController<H264AccessUnit> accessUnits =
      StreamController<H264AccessUnit>.broadcast();

  /// 2026-09-02, `FR-MOB-114` audio playback: raw AAC access units read off the audio RTP
  /// channel (only ever populated when [hasAudio] is true and the audio SETUP succeeded) --
  /// same broadcast/lifecycle shape as [accessUnits].
  final StreamController<AacAccessUnit> audioAccessUnits =
      StreamController<AacAccessUnit>.broadcast();

  bool _reading = false;

  /// Starts the background read loop that demultiplexes `$`-framed interleaved RTP off the
  /// shared TCP/TLS connection and depacketizes H.264 (RFC 6184: single-NAL-unit packets and
  /// FU-A fragmentation — this camera never sends STAP-A, confirmed directly from
  /// `RTSPS_SendH264Frame()`'s own two-branch packetizer, so that mode isn't implemented here).
  /// Emits onto [accessUnits] until [close] is called or the connection ends.
  void startReading() {
    if (_reading) return;
    _reading = true;
    unawaited(_readLoop());
  }

  Uint8List? _fuBuffer;
  int? _fuTimestamp;
  bool? _fuIsKeyframe;
  int _interleavedPacketCount = 0;

  /// 2026-09-02, `BUG-029`: how long to wait for the *next* interleaved packet before treating
  /// the session as over. There is no RTSP-level or connection-level end-of-stream signal for
  /// "this clip's real content is exhausted" (the server just goes quiet on the same still-open
  /// TCP connection, confirmed on real hardware — a 20s clip's RTP feed ran clean, then produced
  /// zero further bytes) -- without this, [_readLoop] blocks on [_readExact] forever, this
  /// session's streams never close, and the consumer (`RtspRemuxProxy`) has no way to know
  /// playback is done. Comfortably above the largest normal inter-packet gap seen in real
  /// testing (audio/video RTP typically tens-to-low-hundreds of ms apart even across a keyframe).
  static const Duration _interPacketStallTimeout = Duration(seconds: 8);

  Future<void> _readLoop() async {
    debugPrint('[RtspReplaySession] _readLoop starting');
    try {
      while (!_closed) {
        final marker = await _readExact(1).timeout(
          _interPacketStallTimeout,
          onTimeout: () => throw RtspReplayException(
            'no interleaved data for ${_interPacketStallTimeout.inSeconds}s -- '
            'treating as end of clip playback',
          ),
        );
        if (marker[0] != 0x24 /* '$' */ ) {
          // Not interleaved data -- shouldn't happen once we're only reading RTP (no further
          // requests go out on this connection while streaming), but don't spin forever on
          // unexpected bytes.
          continue;
        }
        final hdr = await _readExact(3);
        final channel = hdr[0];
        final length = (hdr[1] << 8) | hdr[2];
        final payload = await _readExact(length);
        _interleavedPacketCount++;
        if (_interleavedPacketCount <= 3 || _interleavedPacketCount % 50 == 0) {
          debugPrint(
            '[RtspReplaySession] interleaved packet #$_interleavedPacketCount '
            'channel=$channel length=$length',
          );
        }
        // channel 0 = video RTP (interleaved=0-1), channel 2 = audio RTP (interleaved=2-3,
        // 2026-09-02 FR-MOB-114 audio playback -- only ever assigned when the audio SETUP above
        // succeeded). 1/3 are each track's own RTCP channel -- ignored, this client never sends
        // receiver reports and the server doesn't require them.
        if (channel == 0) {
          _handleRtpPacket(payload);
        } else if (channel == 2) {
          _handleAudioRtpPacket(payload);
        }
      }
    } catch (e, st) {
      // Connection closed/errored -- normal end-of-stream for this reader, but logged (not
      // silently swallowed) since a mid-stream death here is otherwise invisible: it happens in
      // the background after RtspRemuxProxy.start() has already returned successfully, so
      // nothing at the call site would ever see it. debugPrint, not dart:developer's log() --
      // see recording_timeline_screen.dart's _logError doc for why (log() needs an active
      // DevTools/VM-service connection to reach adb logcat at all; debugPrint always does).
      debugPrint('[RtspReplaySession] _readLoop ended -- error: $e\n$st');
    } finally {
      if (!accessUnits.isClosed) unawaited(accessUnits.close());
      if (!audioAccessUnits.isClosed) unawaited(audioAccessUnits.close());
    }
  }

  void _handleRtpPacket(Uint8List packet) {
    if (packet.length < 12) return;
    final payloadType = packet[1] & 0x7F;
    if (payloadType != (_videoPayloadType ?? 96)) return;
    final timestamp =
        ((packet[4] << 24) | (packet[5] << 16) | (packet[6] << 8) | packet[7]) &
        0xFFFFFFFF;
    final rtpPayload = packet.sublist(12);
    if (rtpPayload.isEmpty) return;

    if (videoCodec == VideoCodec.h265) {
      _handleH265RtpPayload(rtpPayload, timestamp);
    } else {
      _handleH264RtpPayload(rtpPayload, timestamp);
    }
  }

  void _handleH264RtpPayload(Uint8List rtpPayload, int timestamp) {
    final nalHeader = rtpPayload[0];
    final nalType = nalHeader & 0x1F;

    if (nalType == 28) {
      // FU-A (RFC 6184 §5.8).
      if (rtpPayload.length < 2) return;
      final fuHeader = rtpPayload[1];
      final start = (fuHeader & 0x80) != 0;
      final end = (fuHeader & 0x40) != 0;
      final fragment = rtpPayload.sublist(2);
      if (start) {
        final reconstructedNalHeader = (nalHeader & 0xE0) | (fuHeader & 0x1F);
        final builder = BytesBuilder();
        builder.addByte(reconstructedNalHeader);
        builder.add(fragment);
        _fuBuffer = builder.toBytes();
        _fuTimestamp = timestamp;
        _fuIsKeyframe = (fuHeader & 0x1F) == 5;
      } else if (_fuBuffer != null && _fuTimestamp == timestamp) {
        final builder = BytesBuilder();
        builder.add(_fuBuffer!);
        builder.add(fragment);
        _fuBuffer = builder.toBytes();
      } else {
        // Missing the start fragment (packet loss) -- drop this partial reassembly rather than
        // emit a corrupt NALU.
        _fuBuffer = null;
        return;
      }
      if (end && _fuBuffer != null) {
        _emitH264AccessUnit(_fuBuffer!, timestamp, _fuIsKeyframe ?? false);
        _fuBuffer = null;
        _fuTimestamp = null;
      }
      return;
    }

    if (nalType >= 1 && nalType <= 23) {
      // Single NAL unit packet -- the whole RTP payload is the NALU, unmodified.
      _emitH264AccessUnit(rtpPayload, timestamp, nalType == 5);
      return;
    }

    // STAP-A/STAP-B/MTAP etc. -- not sent by this camera (see class doc); ignore rather than
    // misinterpret as a bare NALU.
  }

  /// RFC 7798 §4.4.3 FU reassembly + §4.4.1 single-NALU passthrough for
  /// H.265. HEVC's NAL header is 2 bytes (vs H.264's 1) and its FU framing
  /// differs structurally: a 2-byte PayloadHdr (`nal_unit_type` = 49) followed
  /// by a separate 1-byte FU header (S/E bits + 6-bit FuType), reconstructed
  /// back into a real 2-byte NAL header.
  void _handleH265RtpPayload(Uint8List rtpPayload, int timestamp) {
    if (rtpPayload.length < 2) return;
    final payloadHdr0 = rtpPayload[0];
    final payloadHdr1 = rtpPayload[1];
    final nalType = (payloadHdr0 >> 1) & 0x3F;

    if (nalType == 49) {
      if (rtpPayload.length < 3) return;
      final fuHeader = rtpPayload[2];
      final start = (fuHeader & 0x80) != 0;
      final end = (fuHeader & 0x40) != 0;
      final fuType = fuHeader & 0x3F;
      final fragment = rtpPayload.sublist(3);
      if (start) {
        final reconstructedByte0 = (payloadHdr0 & 0x81) | (fuType << 1);
        final builder = BytesBuilder()
          ..addByte(reconstructedByte0)
          ..addByte(payloadHdr1)
          ..add(fragment);
        _fuBuffer = builder.toBytes();
        _fuTimestamp = timestamp;
        _fuIsKeyframe = fuType >= 19 && fuType <= 21;
      } else if (_fuBuffer != null && _fuTimestamp == timestamp) {
        final builder = BytesBuilder()
          ..add(_fuBuffer!)
          ..add(fragment);
        _fuBuffer = builder.toBytes();
      } else {
        // Missing the start fragment (packet loss) -- drop this partial
        // reassembly rather than emit a corrupt NALU.
        _fuBuffer = null;
        return;
      }
      if (end && _fuBuffer != null) {
        _emitOrCaptureH265Nalu(_fuBuffer!, timestamp, _fuIsKeyframe ?? false);
        _fuBuffer = null;
        _fuTimestamp = null;
      }
      return;
    }

    if (nalType <= 47) {
      // Single NALU packet (48 = Aggregation, 49 = FU, 50 = PACI, none of
      // which this camera sends). 19-21 = IDR_W_RADL/IDR_N_LP/CRA_NUT.
      _emitOrCaptureH265Nalu(
        rtpPayload,
        timestamp,
        nalType >= 19 && nalType <= 21,
      );
    }
  }

  /// H.265 counterpart of [_emitH264AccessUnit] — VPS(32) is captured into
  /// [vps] rather than discarded (in case the SDP omitted it), and
  /// SPS(33)/PPS(34)/AUD(35)/SEI(39/40) are filtered the same defensive way
  /// H.264's 6/7/8/9 are.
  void _emitOrCaptureH265Nalu(Uint8List nalu, int timestamp, bool isKeyframe) {
    if (nalu.length < 2) return;
    final nalType = (nalu[0] >> 1) & 0x3F;
    if (nalType == 32) {
      vps ??= nalu;
      return;
    }
    if (nalType == 33 ||
        nalType == 34 ||
        nalType == 35 ||
        nalType == 39 ||
        nalType == 40) {
      return;
    }
    if (accessUnits.isClosed) return;
    accessUnits.add(
      H264AccessUnit(
        nalu: nalu,
        rtpTimestamp90k: timestamp,
        isKeyframe: isKeyframe,
      ),
    );
  }

  void _emitH264AccessUnit(Uint8List nalu, int timestamp, bool isKeyframe) {
    if (accessUnits.isClosed) return;
    // Defensive filter, matching standard fMP4-muxer practice: an in-band parameter-set/AUD/SEI
    // NALU (types 6/7/8/9) should never reach mdat -- SPS/PPS are already in the init segment's
    // avcC (from DESCRIBE's SDP), and this camera isn't believed to ever send these in-band
    // anyway (see class doc), but this costs nothing and avoids ever muxing something that isn't
    // real slice data if that assumption is ever wrong.
    final nalType = nalu.isEmpty ? 0 : (nalu[0] & 0x1F);
    if (nalType == 6 || nalType == 7 || nalType == 8 || nalType == 9) return;
    accessUnits.add(
      H264AccessUnit(
        nalu: nalu,
        rtpTimestamp90k: timestamp,
        isKeyframe: isKeyframe,
      ),
    );
  }

  /// 2026-09-02, `FR-MOB-114` audio playback. RFC 3640 §3.2.1 "AU Header Section" depacketizer
  /// for AAC-hbr (`sizelength=13;indexlength=3;indexdeltalength=3`, matching this camera's own
  /// `module_rtsps.c` DESCRIBE `a=fmtp` exactly): a 2-byte AU-headers-length prefix (in BITS),
  /// followed by one 16-bit AU-header per access unit in this packet (13-bit size + 3-bit
  /// index/index-delta -- this camera always sends exactly one AAC frame per RTP packet in
  /// practice, so this loop's general form costs nothing extra but doesn't assume it), then the
  /// AU payloads themselves, back to back, each exactly the length its own header declared.
  void _handleAudioRtpPacket(Uint8List packet) {
    if (packet.length < 12) return;
    final payloadType = packet[1] & 0x7F;
    if (_audioPayloadType == null || payloadType != _audioPayloadType) return;
    final timestamp =
        ((packet[4] << 24) | (packet[5] << 16) | (packet[6] << 8) | packet[7]) &
        0xFFFFFFFF;
    final rtpPayload = packet.sublist(12);
    if (rtpPayload.length < 2) return;

    final auHeadersLengthBits = (rtpPayload[0] << 8) | rtpPayload[1];
    final auHeadersLengthBytes = (auHeadersLengthBits + 7) ~/ 8;
    if (2 + auHeadersLengthBytes > rtpPayload.length) {
      return; // malformed -- header claims more than we have
    }
    final auHeaderCount =
        auHeadersLengthBits ~/ 16; // each AU-header is exactly 16 bits here
    if (auHeaderCount == 0) return;

    final auSizes = <int>[];
    for (var i = 0; i < auHeaderCount; i++) {
      final headerOffset = 2 + i * 2;
      final header =
          (rtpPayload[headerOffset] << 8) | rtpPayload[headerOffset + 1];
      auSizes.add(
        header >> 3,
      ); // top 13 bits = AU-size; low 3 bits = index/index-delta, unused here
    }

    var offset = 2 + auHeadersLengthBytes;
    for (final size in auSizes) {
      if (offset + size > rtpPayload.length) {
        break; // malformed/truncated -- stop rather than read OOB
      }
      if (!audioAccessUnits.isClosed) {
        audioAccessUnits.add(
          AacAccessUnit(
            aac: rtpPayload.sublist(offset, offset + size),
            rtpTimestamp: timestamp,
          ),
        );
      }
      offset += size;
    }
  }

  Future<Uint8List> _readExact(int n) async {
    while (_recvBytes.length - _recvOffset < n) {
      final chunk = await _nextChunk();
      final combined = BytesBuilder();
      combined.add(_recvBytes.sublist(_recvOffset));
      combined.add(chunk);
      _recvBytes = combined.toBytes();
      _recvOffset = 0;
    }
    final result = _recvBytes.sublist(_recvOffset, _recvOffset + n);
    _recvOffset += n;
    return result;
  }

  final List<Completer<Uint8List>> _pendingChunkWaiters = [];
  StreamSubscription<Uint8List>? _incomingSub;
  final List<Uint8List> _chunkQueue = [];

  Future<Uint8List> _nextChunk() {
    _incomingSub ??= _incoming.stream.listen(
      (chunk) {
        if (_pendingChunkWaiters.isNotEmpty) {
          _pendingChunkWaiters.removeAt(0).complete(chunk);
        } else {
          _chunkQueue.add(chunk);
        }
      },
      onDone: () {
        while (_pendingChunkWaiters.isNotEmpty) {
          _pendingChunkWaiters
              .removeAt(0)
              .completeError(RtspReplayException('connection closed'));
        }
      },
    );
    if (_chunkQueue.isNotEmpty) {
      return Future.value(_chunkQueue.removeAt(0));
    }
    final completer = Completer<Uint8List>();
    _pendingChunkWaiters.add(completer);
    return completer.future;
  }

  String get _uri => 'rtsp://$_host:$_port$_path';

  String _digestHeader(String method, String uri) {
    final ha1 = md5
        .convert(utf8.encode('$_username:ONVIF:$_password'))
        .toString();
    final ha2 = md5.convert(utf8.encode('$method:$uri')).toString();
    final response = md5.convert(utf8.encode('$ha1:$_nonce:$ha2')).toString();
    return 'Digest username="$_username", realm="ONVIF", nonce="$_nonce", uri="$uri", response="$response"';
  }

  /// [uriOverride] 2026-09-02, `FR-MOB-114` audio playback: the video SETUP always targets this
  /// session's base path (the server treats that as "streamid=0" by default, per
  /// `module_rtsps.c`'s own `is_audio = strstr(ptr, "streamid=1")` check), but a *second*, real
  /// SETUP is required for the audio track, whose request line must literally contain
  /// "streamid=1" -- resolved from the SDP's own `a=control:streamid=1` relative control
  /// attribute against this session's base path, same as `streamid=0`'s implicit default.
  Future<_RtspResponse> _request(
    String method,
    Map<String, String> extraHeaders,
    Duration timeout, {
    String? uriOverride,
  }) async {
    final uri = uriOverride ?? _uri;
    _cseq++;
    final headerLines = <String>['$method $uri RTSP/1.0', 'CSeq: $_cseq'];
    if (_nonce != null) {
      headerLines.add('Authorization: ${_digestHeader(method, uri)}');
    }
    extraHeaders.forEach((k, v) => headerLines.add('$k: $v'));
    final req = '${headerLines.join('\r\n')}\r\n\r\n';
    _socket.add(utf8.encode(req));
    await _socket.flush();

    final resp = await _readResponse().timeout(timeout);
    if (resp.status == 401 && _nonce == null) {
      final wwwAuth = resp.headers['WWW-Authenticate'] ?? '';
      final nonceMatch = RegExp('nonce="([^"]+)"').firstMatch(wwwAuth);
      if (nonceMatch != null) {
        _nonce = nonceMatch.group(1);
        return _request(
          method,
          extraHeaders,
          timeout,
          uriOverride: uriOverride,
        );
      }
    }
    return resp;
  }

  /// Demuxes any `$`-framed interleaved data that may already be sitting ahead of the next RTSP
  /// text response (normal on this connection once streaming has started — see
  /// `playback_rtsp_test.py`'s own `_read_response()` for why this exact discipline matters, a
  /// real lesson from `BUG-011` Iteration 4) before parsing the response itself.
  Future<_RtspResponse> _readResponse() async {
    Uint8List marker;
    while (true) {
      marker = await _readExact(1);
      if (marker[0] != 0x24) break;
      final hdr = await _readExact(3);
      final length = (hdr[1] << 8) | hdr[2];
      await _readExact(length);
    }
    // Put the non-'$' byte back by re-reading a line starting with it.
    final firstLine = await _readLineStartingWith(marker);
    if (!firstLine.startsWith('RTSP/1.0')) {
      throw RtspReplayException(
        'unexpected line waiting for RTSP response: $firstLine',
      );
    }
    final statusMatch = RegExp(r'^RTSP/1\.0 (\d+) ').firstMatch(firstLine);
    if (statusMatch == null) {
      throw RtspReplayException('malformed status line: $firstLine');
    }
    final status = int.parse(statusMatch.group(1)!);

    final headers = <String, String>{};
    while (true) {
      final line = await _readLine();
      if (line.isEmpty) break;
      final idx = line.indexOf(':');
      if (idx > 0) {
        headers[line.substring(0, idx).trim()] = line.substring(idx + 1).trim();
      }
    }
    var body = Uint8List(0);
    final cl = headers['Content-Length'];
    if (cl != null) body = await _readExact(int.parse(cl));
    return _RtspResponse(status, headers, body);
  }

  Future<String> _readLineStartingWith(Uint8List firstByte) async {
    final builder = BytesBuilder();
    builder.add(firstByte);
    while (true) {
      final b = await _readExact(1);
      if (b[0] == 0x0D) {
        final lf = await _readExact(1);
        if (lf[0] == 0x0A) break;
        builder.addByte(b[0]);
        builder.addByte(lf[0]);
        continue;
      }
      builder.addByte(b[0]);
    }
    return utf8.decode(builder.toBytes(), allowMalformed: true);
  }

  Future<String> _readLine() async {
    final builder = BytesBuilder();
    while (true) {
      final b = await _readExact(1);
      if (b[0] == 0x0D) {
        final lf = await _readExact(1);
        if (lf[0] == 0x0A) break;
        builder.addByte(b[0]);
        builder.addByte(lf[0]);
        continue;
      }
      builder.addByte(b[0]);
    }
    return utf8.decode(builder.toBytes(), allowMalformed: true);
  }

  /// Parses `sprop-parameter-sets=<base64-SPS>,<base64-PPS>` out of the SDP `a=fmtp:` line —
  /// the only source this class trusts for SPS/PPS (see class doc). Also parses the `m=audio`
  /// section, if present, for `FR-MOB-114` audio playback (2026-09-02) -- see `hasAudio`'s own
  /// doc comment for when the server omits it entirely.
  void _parseSdp(String sdp) {
    final videoMatch = RegExp(r'm=video \d+ RTP/AVP (\d+)').firstMatch(sdp);
    if (videoMatch == null) {
      throw RtspReplayException('DESCRIBE SDP has no m=video line');
    }
    _videoPayloadType = int.parse(videoMatch.group(1)!);
    final videoRtpmapMatch = RegExp(
      'a=rtpmap:$_videoPayloadType (H264|H265)/90000',
    ).firstMatch(sdp);
    videoCodec = videoRtpmapMatch?.group(1) == 'H265'
        ? VideoCodec.h265
        : VideoCodec.h264;

    // Unlike live view, a recorded clip's H.265 SDP advertises real RFC 7798
    // sprop-vps=/sprop-sps=/sprop-pps= attributes — a demuxed clip's sample
    // data has no in-band VPS to fall back on the way a live re-encode does,
    // so playback's SDP gives the client everything up front. Try that first
    // for H.265, then fall back to the shared sprop-parameter-sets
    // convention (always H.264, and a defensive fallback for H.265 if the
    // server ever omits VPS — [vps] then stays null until the RTP layer
    // captures one).
    final vpsMatch = videoCodec == VideoCodec.h265
        ? RegExp(r'sprop-vps=([A-Za-z0-9+/=]+)').firstMatch(sdp)
        : null;
    final spsAttrMatch = videoCodec == VideoCodec.h265
        ? RegExp(r'sprop-sps=([A-Za-z0-9+/=]+)').firstMatch(sdp)
        : null;
    final ppsAttrMatch = videoCodec == VideoCodec.h265
        ? RegExp(r'sprop-pps=([A-Za-z0-9+/=]+)').firstMatch(sdp)
        : null;
    if (vpsMatch != null && spsAttrMatch != null && ppsAttrMatch != null) {
      vps = base64.decode(_padBase64(vpsMatch.group(1)!));
      sps = base64.decode(_padBase64(spsAttrMatch.group(1)!));
      pps = base64.decode(_padBase64(ppsAttrMatch.group(1)!));
    } else {
      final fmtpMatch = RegExp(
        r'sprop-parameter-sets=([A-Za-z0-9+/=]+),([A-Za-z0-9+/=]+)',
      ).firstMatch(sdp);
      if (fmtpMatch == null) {
        throw RtspReplayException(
          'DESCRIBE SDP has no sprop-parameter-sets -- cannot build avcC/hvcC',
        );
      }
      sps = base64.decode(_padBase64(fmtpMatch.group(1)!));
      pps = base64.decode(_padBase64(fmtpMatch.group(2)!));
    }

    // "m=audio 0 RTP/AVP 97" -> payload type 97. Only ever present when
    // playback_demuxer_bind.c's prvPopulateAudioInfoFromDemuxer() found a real, supported audio
    // track on this clip (module_rtsps.c's DESCRIBE handler omits the whole section otherwise).
    final audioMatch = RegExp(r'm=audio \d+ RTP/AVP (\d+)').firstMatch(sdp);
    if (audioMatch == null) return;
    final pt = int.parse(audioMatch.group(1)!);

    // "a=rtpmap:97 MPEG4-GENERIC/16000/1" (channel count omitted entirely for mono, per RFC
    // 4566 -- default to 1 in that case, matching module_rtsps.c's own SDP generation, which
    // only ever appends "/2" for stereo and nothing otherwise).
    final rtpmapMatch = RegExp(
      'a=rtpmap:$pt [^/]+/(\\d+)(?:/(\\d+))?',
    ).firstMatch(sdp);
    if (rtpmapMatch == null) return;
    final sampleRate = int.parse(rtpmapMatch.group(1)!);
    final channels = rtpmapMatch.group(2) != null
        ? int.parse(rtpmapMatch.group(2)!)
        : 1;

    // "a=fmtp:97 streamtype=5;profile-level-id=1;mode=AAC-hbr;sizelength=13;indexlength=3;
    // indexdeltalength=3;config=1190" -- the 2-byte AudioSpecificConfig this esds box needs.
    // Only AAC-hbr is parsed here (matches this camera's actual audio pipeline, confirmed via
    // bsp_camera_ameba.c's own AAC ADTS encoder setup) -- a PCMU/PCMA clip would reach this
    // point with `config` still null, and the caller (RtspRemuxProxy) treats that the same as
    // no audio at all rather than guessing at an unsupported codec's own framing.
    final configMatch = RegExp(
      'a=fmtp:$pt [^\\r\\n]*config=([0-9A-Fa-f]+)',
    ).firstMatch(sdp);
    if (configMatch == null) return;
    final configHex = configMatch.group(1)!;
    final config = Uint8List(configHex.length ~/ 2);
    for (var i = 0; i < config.length; i++) {
      config[i] = int.parse(configHex.substring(i * 2, i * 2 + 2), radix: 16);
    }

    _audioPayloadType = pt;
    audioSampleRate = sampleRate;
    audioChannelCount = channels;
    audioSpecificConfig = config;
  }

  static String _padBase64(String s) {
    final rem = s.length % 4;
    return rem == 0 ? s : s + ('=' * (4 - rem));
  }

  Future<void> teardown() async {
    if (!_played || _closed) return;
    try {
      await _request('TEARDOWN', const {}, const Duration(seconds: 5));
    } catch (_) {
      // Best-effort, mirroring playback_rtsp_test.py's RtspsSession.close() -- BUG-012's own
      // idle-timeout is the fallback if this doesn't land.
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await teardown();
    await _socketSub?.cancel();
    await _incomingSub?.cancel();
    if (!_incoming.isClosed) await _incoming.close();
    if (!accessUnits.isClosed) await accessUnits.close();
    if (!audioAccessUnits.isClosed) await audioAccessUnits.close();
    try {
      await _socket.close();
    } catch (_) {}
  }
}

class _RtspResponse {
  const _RtspResponse(this.status, this.headers, this.body);
  final int status;
  final Map<String, String> headers;
  final Uint8List body;
}
