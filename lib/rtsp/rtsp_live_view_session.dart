import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:camera_api/camera_api.dart' show VideoCodec;
import 'package:crypto/crypto.dart' show md5;
import 'package:flutter/foundation.dart' show debugPrint;

/// One reconstructed H.264 access unit read off the camera's live-view RTSPS session — see
/// `rtsp_replay_client.dart`'s `H264AccessUnit` for the packetization details this mirrors
/// exactly (this camera's RTP packetizer is the same code path for both playback and live).
class LiveH264AccessUnit {
  const LiveH264AccessUnit({
    required this.nalu,
    required this.rtpTimestamp90k,
    required this.isKeyframe,
  });

  final Uint8List nalu;
  final int rtpTimestamp90k;
  final bool isKeyframe;
}

/// One raw AAC access unit read off the camera's live-view audio RTP channel — see
/// `rtsp_replay_client.dart`'s `AacAccessUnit` for the RFC 3640 AAC-hbr framing this mirrors.
class LiveAacAccessUnit {
  const LiveAacAccessUnit({required this.aac, required this.rtpTimestamp});

  final Uint8List aac;
  final int rtpTimestamp;
}

class RtspLiveViewException implements Exception {
  RtspLiveViewException(this.message);
  final String message;
  @override
  String toString() => 'RtspLiveViewException: $message';
}

/// A real RTSP/1.0-over-TLS client for this camera's **live-view** RTSPS listener (the
/// `transport: "rtsp"` fallback `STREAMING_GUIDE.md` §2.5 describes, used when the camera's
/// firmware build has `WEBRTC_STREAMING` disabled — the current default). **Adapted from**
/// `rtsp_replay_client.dart`'s `RtspReplaySession` (the pre-existing, ten-iteration
/// hardware-verified recorded-clip playback client) rather than re-deriving the protocol from
/// scratch — same `OPTIONS`/`DESCRIBE`/`SETUP`/`PLAY`/`TEARDOWN` engine, RFC 2617 Digest auth,
/// and RTP depacketization, with the clip-specific concepts that class has (seek via `Range:
/// clock=...`, a bound clip's start/end epoch) dropped entirely — live view has neither.
///
/// Deliberately a separate class rather than reusing `RtspReplaySession` directly: that class's
/// entire doc/API surface (its own name, `clipEpochStart`, `seekToEpochSeconds`) is written in
/// terms of a bounded recorded clip, which would read confusingly (and invite an unsafe
/// feature — seeking live video makes no sense) if reused as-is for an unbounded live session.
class RtspLiveViewSession {
  RtspLiveViewSession._(
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

  /// Populated by [_parseSdp] — base64-decoded H.264 SPS (Annex-B start code stripped), read from
  /// the SDP's `sprop-parameter-sets` — the only reliable source for these on this camera (in-band
  /// SPS/PPS NALUs are never sent over RTP).
  Uint8List? sps;
  Uint8List? pps;

  /// Detected from the DESCRIBE SDP's `a=rtpmap:<pt>` line for the video track.
  /// Defaults to [VideoCodec.h264] (this camera's original encoding) until
  /// DESCRIBE actually runs.
  VideoCodec videoCodec = VideoCodec.h264;

  /// The video track's RTP payload type from the SDP's `m=video` line — this
  /// camera uses 96 today, but [_handleRtpPacket] checks this rather than
  /// hardcoding it.
  int? _videoPayloadType;

  /// H.265 only — this camera never advertises VPS in the SDP (it reuses
  /// `sprop-parameter-sets` for SPS+PPS only), so unlike [sps]/[pps] this is
  /// populated later, by [_emitOrCaptureH265Nalu] capturing the first in-band
  /// VPS NALU (type 32). It always arrives before any real video access unit
  /// on a fresh PLAY, because the firmware's own per-client keyframe gate
  /// won't release video until its VPS/SPS/PPS/IDR bundle has gone out.
  Uint8List? vps;

  /// Populated by [_parseSdp] only when the SDP's `m=audio` section is present — `null` means no
  /// audio for this stream; every audio field below is only meaningful together with the others.
  int? _audioPayloadType;
  int? audioSampleRate;
  int? audioChannelCount;

  /// AAC AudioSpecificConfig bytes (ISO/IEC 14496-3), decoded from the SDP `a=fmtp:PT config=`
  /// hex attribute — exactly what `RtspFmp4Muxer`'s audio `esds` box needs.
  Uint8List? audioSpecificConfig;

  bool get hasAudio => _audioPayloadType != null;

  /// Opens the TLS connection and performs `DESCRIBE`+`SETUP`+`PLAY` (no `Range` header — live
  /// view always plays from "now", there is no seek concept), so callers get a single async
  /// factory that's either fully ready to stream or throws. [host]/[port]/[path] come from
  /// parsing `GetLiveStreamUri`'s resolved `rtsps://host:port/path` target.
  static Future<RtspLiveViewSession> open({
    required String host,
    required int port,
    required String path,
    required String username,
    required String password,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final socket = await SecureSocket.connect(
      host,
      port,
      timeout: timeout,
      onBadCertificate: (_) =>
          true, // self-signed cert, same trust posture as createCameraHttpClient()
    );
    final session = RtspLiveViewSession._(
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
        throw RtspLiveViewException(
          'DESCRIBE failed: HTTP-style status ${describeResp.status}',
        );
      }
      session._parseSdp(utf8.decode(describeResp.body, allowMalformed: true));

      final setupResp = await session._request('SETUP', {
        'Transport': 'RTP/AVP/TCP;unicast;interleaved=0-1',
      }, timeout);
      if (setupResp.status != 200) {
        throw RtspLiveViewException('SETUP failed: status ${setupResp.status}');
      }

      // Second, real SETUP for the audio track, only when DESCRIBE's SDP actually advertised
      // one — mirrors rtsp_replay_client.dart's own audio-SETUP handling exactly.
      if (session.hasAudio) {
        final audioSetupResp = await session._request(
          'SETUP',
          {'Transport': 'RTP/AVP/TCP;unicast;interleaved=2-3'},
          timeout,
          uriOverride: '${session._uri}/streamid=1',
        );
        if (audioSetupResp.status != 200) {
          // Non-fatal — fall back to video-only live view rather than failing the whole
          // session over an audio-track SETUP failure.
          debugPrint(
            '[RtspLiveViewSession] audio SETUP failed: status ${audioSetupResp.status} '
            '-- continuing video-only',
          );
          session._audioPayloadType = null;
        }
      }

      final playResp = await session._request('PLAY', const {}, timeout);
      if (playResp.status != 200) {
        throw RtspLiveViewException('PLAY failed: status ${playResp.status}');
      }
      session._played = true;
      debugPrint(
        '[RtspLiveViewSession] PLAY 200 -- sps=${session.sps?.length ?? 0} bytes, '
        'pps=${session.pps?.length ?? 0} bytes, audio=${session.hasAudio ? '${session.audioSampleRate}Hz/${session.audioChannelCount}ch' : 'none'}, '
        'host=$host:$port$path',
      );
      return session;
    } catch (_) {
      await session.close();
      rethrow;
    }
  }

  void _onSocketData(Uint8List chunk) {
    if (!_incoming.isClosed) _incoming.add(chunk);
  }

  /// Access units read off the interleaved stream after `PLAY` — call [startReading] once, then
  /// listen to this. A fresh [LiveH264AccessUnit] is emitted every time a complete NALU is
  /// reconstructed (single-packet NALU or a fully-reassembled FU-A sequence).
  final StreamController<LiveH264AccessUnit> accessUnits =
      StreamController<LiveH264AccessUnit>.broadcast();

  /// Raw AAC access units read off the audio RTP channel (only populated when [hasAudio] is true
  /// and the audio SETUP above succeeded) — same broadcast/lifecycle shape as [accessUnits].
  final StreamController<LiveAacAccessUnit> audioAccessUnits =
      StreamController<LiveAacAccessUnit>.broadcast();

  bool _reading = false;

  /// Starts the background read loop that demultiplexes `$`-framed interleaved RTP off the
  /// shared TCP/TLS connection and depacketizes H.264 (RFC 6184: single-NAL-unit packets and
  /// FU-A fragmentation — this camera never sends STAP-A). Emits onto [accessUnits] until
  /// [close] is called or the connection ends.
  void startReading() {
    if (_reading) return;
    _reading = true;
    unawaited(_readLoop());
  }

  Uint8List? _fuBuffer;
  int? _fuTimestamp;
  bool? _fuIsKeyframe;
  int _interleavedPacketCount = 0;

  /// Cumulative wire bytes read off this connection (every interleaved
  /// `$`-framed packet's own `length`, video and audio both — the real
  /// network throughput, not just the depacketized payload after RTP/AU
  /// framing is stripped). [RtspLiveViewProxy] exposes this so
  /// `LiveViewController` can compute a real, live `measuredBitrateKbps`
  /// for this transport the same way it already does for the WebRTC path's
  /// `RTCPeerConnection.getStats()` — added 2026-09-15, real gap: this
  /// camera's firmware has WebRTC disabled, so the RTSP-over-LAN fallback
  /// is this app's actual default LAN path, and it never fed the bitrate
  /// badge (LIVE-038) any number at all before this.
  int bytesReceived = 0;

  /// How long to wait for the *next* interleaved packet before treating this session as over —
  /// unlike a recorded clip, live view has no natural "content exhausted" point, so a stall this
  /// long only ever means a genuinely dead connection (camera rebooted, network dropped). Same
  /// value `rtsp_replay_client.dart`'s own stall timeout uses, tuned against real inter-packet
  /// gaps on this hardware.
  static const Duration _interPacketStallTimeout = Duration(seconds: 8);

  Future<void> _readLoop() async {
    debugPrint('[RtspLiveViewSession] _readLoop starting');
    try {
      while (!_closed) {
        final marker = await _readExact(1).timeout(
          _interPacketStallTimeout,
          onTimeout: () => throw RtspLiveViewException(
            'no interleaved data for ${_interPacketStallTimeout.inSeconds}s -- '
            'treating as connection lost',
          ),
        );
        if (marker[0] != 0x24 /* '$' */ ) {
          continue;
        }
        final hdr = await _readExact(3);
        final channel = hdr[0];
        final length = (hdr[1] << 8) | hdr[2];
        final payload = await _readExact(length);
        _interleavedPacketCount++;
        bytesReceived += length;
        if (_interleavedPacketCount <= 3 || _interleavedPacketCount % 50 == 0) {
          debugPrint(
            '[RtspLiveViewSession] interleaved packet #$_interleavedPacketCount '
            'channel=$channel length=$length',
          );
        }
        if (channel == 0) {
          _handleRtpPacket(payload);
        } else if (channel == 2) {
          _handleAudioRtpPacket(payload);
        }
      }
    } catch (e, st) {
      debugPrint('[RtspLiveViewSession] _readLoop ended -- error: $e\n$st');
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
        (packet[4] << 24) | (packet[5] << 16) | (packet[6] << 8) | packet[7];
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
      _emitH264AccessUnit(rtpPayload, timestamp, nalType == 5);
      return;
    }

    // STAP-A/STAP-B/MTAP — not sent by this camera; ignore rather than
    // misinterpret as a bare NALU.
  }

  void _emitH264AccessUnit(Uint8List nalu, int timestamp, bool isKeyframe) {
    if (accessUnits.isClosed) return;
    final nalType = nalu.isEmpty ? 0 : (nalu[0] & 0x1F);
    if (nalType == 6 || nalType == 7 || nalType == 8 || nalType == 9) return;
    accessUnits.add(
      LiveH264AccessUnit(
        nalu: nalu,
        rtpTimestamp90k: timestamp,
        isKeyframe: isKeyframe,
      ),
    );
  }

  /// RFC 7798 §4.4.3 FU reassembly + §4.4.1 single-NALU passthrough for H.265.
  /// HEVC's NAL header is 2 bytes (vs H.264's 1) and its FU framing differs
  /// structurally: a 2-byte PayloadHdr (`nal_unit_type` = 49) followed by a
  /// separate 1-byte FU header (S/E bits + 6-bit FuType), reconstructed back
  /// into a real 2-byte NAL header.
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
        // Missing the start fragment (packet loss) — drop this partial
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
      // which this camera sends). 19-21 = IDR_W_RADL/IDR_N_LP/CRA_NUT, the
      // IRAP range the firmware's own keyframe gate checks.
      _emitOrCaptureH265Nalu(
        rtpPayload,
        timestamp,
        nalType >= 19 && nalType <= 21,
      );
    }
  }

  /// H.265 counterpart of [_emitH264AccessUnit] — but VPS(32) is captured into
  /// [vps] instead of discarded (this camera only ever sends it in-band), and
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
      LiveH264AccessUnit(
        nalu: nalu,
        rtpTimestamp90k: timestamp,
        isKeyframe: isKeyframe,
      ),
    );
  }

  /// RFC 3640 §3.2.1 "AU Header Section" depacketizer for AAC-hbr — see
  /// `rtsp_replay_client.dart`'s own copy of this for the full field-layout doc.
  void _handleAudioRtpPacket(Uint8List packet) {
    if (packet.length < 12) return;
    final payloadType = packet[1] & 0x7F;
    if (_audioPayloadType == null || payloadType != _audioPayloadType) return;
    final timestamp =
        (packet[4] << 24) | (packet[5] << 16) | (packet[6] << 8) | packet[7];
    final rtpPayload = packet.sublist(12);
    if (rtpPayload.length < 2) return;

    final auHeadersLengthBits = (rtpPayload[0] << 8) | rtpPayload[1];
    final auHeadersLengthBytes = (auHeadersLengthBits + 7) ~/ 8;
    if (2 + auHeadersLengthBytes > rtpPayload.length) return;
    final auHeaderCount = auHeadersLengthBits ~/ 16;
    if (auHeaderCount == 0) return;

    final auSizes = <int>[];
    for (var i = 0; i < auHeaderCount; i++) {
      final headerOffset = 2 + i * 2;
      final header =
          (rtpPayload[headerOffset] << 8) | rtpPayload[headerOffset + 1];
      auSizes.add(header >> 3);
    }

    var offset = 2 + auHeadersLengthBytes;
    for (final size in auSizes) {
      if (offset + size > rtpPayload.length) break;
      if (!audioAccessUnits.isClosed) {
        audioAccessUnits.add(
          LiveAacAccessUnit(
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
              .completeError(RtspLiveViewException('connection closed'));
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

  Future<_RtspResponse> _readResponse() async {
    Uint8List marker;
    while (true) {
      marker = await _readExact(1);
      if (marker[0] != 0x24) break;
      final hdr = await _readExact(3);
      final length = (hdr[1] << 8) | hdr[2];
      await _readExact(length);
    }
    final firstLine = await _readLineStartingWith(marker);
    if (!firstLine.startsWith('RTSP/1.0')) {
      throw RtspLiveViewException(
        'unexpected line waiting for RTSP response: $firstLine',
      );
    }
    final statusMatch = RegExp(r'^RTSP/1\.0 (\d+) ').firstMatch(firstLine);
    if (statusMatch == null) {
      throw RtspLiveViewException('malformed status line: $firstLine');
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

  void _parseSdp(String sdp) {
    final videoMatch = RegExp(r'm=video \d+ RTP/AVP (\d+)').firstMatch(sdp);
    if (videoMatch == null) {
      throw RtspLiveViewException('DESCRIBE SDP has no m=video line');
    }
    _videoPayloadType = int.parse(videoMatch.group(1)!);
    final videoRtpmapMatch = RegExp(
      'a=rtpmap:$_videoPayloadType (H264|H265)/90000',
    ).firstMatch(sdp);
    videoCodec = videoRtpmapMatch?.group(1) == 'H265'
        ? VideoCodec.h265
        : VideoCodec.h264;

    // This camera's DESCRIBE handler reuses H.264's `sprop-parameter-sets`
    // attribute for H.265's SPS+PPS too (not RFC 7798's `sprop-sps=`/
    // `sprop-pps=`), which is why an H.265 stream still parses here.
    final fmtpMatch = RegExp(
      r'sprop-parameter-sets=([A-Za-z0-9+/=]+),([A-Za-z0-9+/=]+)',
    ).firstMatch(sdp);
    if (fmtpMatch == null) {
      throw RtspLiveViewException(
        'DESCRIBE SDP has no sprop-parameter-sets -- cannot build avcC/hvcC',
      );
    }
    sps = base64.decode(_padBase64(fmtpMatch.group(1)!));
    pps = base64.decode(_padBase64(fmtpMatch.group(2)!));

    final audioMatch = RegExp(r'm=audio \d+ RTP/AVP (\d+)').firstMatch(sdp);
    if (audioMatch == null) return;
    final pt = int.parse(audioMatch.group(1)!);

    final rtpmapMatch = RegExp(
      'a=rtpmap:$pt [^/]+/(\\d+)(?:/(\\d+))?',
    ).firstMatch(sdp);
    if (rtpmapMatch == null) return;
    final sampleRate = int.parse(rtpmapMatch.group(1)!);
    final channels = rtpmapMatch.group(2) != null
        ? int.parse(rtpmapMatch.group(2)!)
        : 1;

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

  /// No `PAUSE` method exists on this camera's live-view RTSPS listener (confirmed via
  /// `module_rtsps.c`'s `OPTIONS` response, same as the playback listener) — `close()` always
  /// fully tears the session down, there's no lighter-weight "pause" to fall back to.
  Future<void> teardown() async {
    if (!_played || _closed) return;
    try {
      await _request('TEARDOWN', const {}, const Duration(seconds: 5));
    } catch (_) {
      // Best-effort — an idle timeout camera-side is the fallback if this doesn't land.
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
