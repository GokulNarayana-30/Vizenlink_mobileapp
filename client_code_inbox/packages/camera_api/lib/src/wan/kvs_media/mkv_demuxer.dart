import 'dart:async';
import 'dart:typed_data';

/// Track metadata from an MKV `Tracks` element (ISO/IEC 21122-style Matroska, as produced by
/// AWS KVS's `PutMedia`/`GetMedia`). [codecPrivate] is, for a video track, **already** a
/// byte-for-byte valid ISO/IEC 14496-15 `avcC`/`hvcC` payload — the vendored KVS producer
/// library (and this project's own H.265 fix, `module_kvs_producer.c`'s
/// `prvGenerateH265CodecPrivateDataFromParams`) build `CodecPrivate` in exactly that format, not
/// a raw parameter-set list — `KvsMediaLiveViewSession._extractParamSets` pulls the individual
/// SPS/PPS/VPS NALUs back out of this blob directly (rather than reconstructing them from scratch
/// the way `RtspLiveViewSession`, which only ever gets bare NALUs from SDP, has to build a
/// codecPrivate blob in the first place). For an audio (`A_AAC`) track, [codecPrivate] is the raw
/// 2-byte `AudioSpecificConfig`.
class MkvTrackInfo {
  const MkvTrackInfo({
    required this.trackNumber,
    required this.trackType,
    required this.codecId,
    required this.codecPrivate,
    this.width,
    this.height,
    this.samplingFrequency,
    this.channels,
  });

  final int trackNumber;

  /// `1` = video, `2` = audio (Matroska `TrackType` values).
  final int trackType;

  /// e.g. `"V_MPEGH/ISO/HEVC"` (or the pre-`BUG-045` typo'd `"V_MPEG/ISO/HEVC"`, see [isHevc]'s
  /// own doc), `"V_MPEG4/ISO/AVC"`, `"A_AAC"`.
  final String codecId;
  final Uint8List codecPrivate;
  final int? width;
  final int? height;
  final int? samplingFrequency;
  final int? channels;

  bool get isVideo => trackType == 1;
  bool get isAudio => trackType == 2;

  /// `V_MPEGH/ISO/HEVC` is the real, spec-registered Matroska CodecID for HEVC (confirmed
  /// against ffmpeg's own compiled-in Matroska codec table). **`BUG-045` (2026-09-17)**: the
  /// camera firmware emitted `V_MPEG/ISO/HEVC` (missing the "H") until that date — AWS's KVS
  /// storage layer never validated the string, so ingestion/`GetMedia` retrieval worked fine
  /// with either spelling; only a real standards-compliant demuxer (ffmpeg, and almost certainly
  /// the AWS KVS console's own player) rejects the typo outright as an unknown codec. Accepting
  /// both here is deliberate, not a leftover: already-captured fixtures and any camera still
  /// running pre-fix firmware use the old string, and this class has no reason to reject either
  /// spelling as long as it can still tell the track is HEVC.
  bool get isHevc => codecId == 'V_MPEGH/ISO/HEVC' || codecId == 'V_MPEG/ISO/HEVC';
  bool get isAvc => codecId == 'V_MPEG4/ISO/AVC';
}

/// All tracks from one `GetMedia` session's `Tracks` element — emitted once, before any
/// [MkvSample], as the first item on [MkvDemuxer.events].
class MkvTracksReady {
  const MkvTracksReady(this.tracks);
  final List<MkvTrackInfo> tracks;

  MkvTrackInfo? get video => tracks.where((t) => t.isVideo).firstOrNull;
  MkvTrackInfo? get audio => tracks.where((t) => t.isAudio).firstOrNull;
}

/// One decoded frame from a `SimpleBlock` (or `BlockGroup`/`Block`) — [data] is the block's raw
/// payload, **already** length-prefixed AVCC/HVCC-style NALUs for a video track (the camera
/// firmware's `kvsAddMediaFrame()` runs `NALU_convertAnnexBToAvccInPlace()` before ever queuing a
/// frame — verified directly against real captured bytes: the first 4 bytes of a real video
/// block are a big-endian NALU length, not an Annex-B start code), or a raw AAC access unit for
/// an audio track. For video, `KvsMediaLiveViewSession._onSample` splits this into its individual
/// NALUs (stripping the AVCC length prefixes) before handing real (non-parameter-set) ones to
/// `RtspFmp4Muxer.fragment`, one call per NALU; audio samples are handed to
/// `RtspFmp4Muxer.audioFragment` unchanged.
class MkvSample {
  const MkvSample({
    required this.trackNumber,
    required this.timestampMs,
    required this.isKeyframe,
    required this.data,
  });
  final int trackNumber;
  final int timestampMs;
  final bool isKeyframe;
  final Uint8List data;
}

typedef MkvEvent = Object; // MkvTracksReady | MkvSample

// ---- EBML/Matroska element IDs actually handled -----------------------------------------

const _idEbml = 0x1A45DFA3;
const _idSegment = 0x18538067;
const _idInfo = 0x1549A966;
const _idTimecodeScale = 0x2AD7B1;
const _idTracks = 0x1654AE6B;
const _idTrackEntry = 0xAE;
const _idTrackNumber = 0xD7;
const _idTrackType = 0x83;
const _idCodecId = 0x86;
const _idCodecPrivate = 0x63A2;
const _idVideo = 0xE0;
const _idPixelWidth = 0xB0;
const _idPixelHeight = 0xBA;
const _idAudio = 0xE1;
const _idSamplingFrequency = 0xB5;
const _idChannels = 0x9F;
const _idCluster = 0x1F43B675;
const _idTimecode = 0xE7;
const _idSimpleBlock = 0xA3;
const _idBlockGroup = 0xA0;
const _idBlock = 0xA1;
const _idVoid = 0xEC;
const _idCrc32 = 0xBF;

/// Every element ID that can legally appear as a **direct child of `Cluster`** — anything else
/// encountered while scanning a Cluster's children means the Cluster has implicitly ended
/// (Matroska never closes an unknown-size element explicitly; the only way to know it's over is
/// recognizing the next sibling's ID isn't a valid child — verified against a real captured KVS
/// `GetMedia` stream, where a `Tags` element genuinely appears both between `Tracks`/the first
/// `Cluster` and after the last one, see `mkv_demuxer_test.dart`'s fixture-based tests).
const _clusterLevelIds = {_idTimecode, _idSimpleBlock, _idBlockGroup, 0xA7, 0xAB, 0x5854, _idVoid, _idCrc32};

/// Streaming MKV/EBML demuxer for AWS KVS's `GetMedia`/`PutMedia` wire format. Feed raw bytes as
/// they arrive over the network via [addChunk] — never call it with the whole response buffered
/// first, `GetMedia`'s response is an unbounded live stream, not a file. [events] emits exactly
/// one [MkvTracksReady] (from the stream's `Tracks` element), then an [MkvSample] per
/// `SimpleBlock` (video and audio interleaved, in wire order) for as long as [addChunk] keeps
/// being called.
///
/// **Not a general-purpose Matroska parser** — deliberately scoped to exactly what a KVS
/// `GetMedia` response contains (verified against real captured bytes, see
/// `mkv_demuxer_test.dart`): one `Tracks` element up front, then a sequence of `Cluster`s each
/// holding `SimpleBlock`s. `BlockGroup`/`Block` (the more general, less common alternative to
/// `SimpleBlock`, used e.g. for blocks needing `ReferenceBlock`) is accepted defensively (treated
/// as non-keyframe, since a `SimpleBlock`'s keyframe flag has no `BlockGroup` equivalent parsed
/// here) but has never been observed from this producer in practice.
class MkvDemuxer {
  final _controller = StreamController<MkvEvent>();
  Stream<MkvEvent> get events => _controller.stream;

  // Growable receive buffer — bytes not yet consumed by a completed element. Compacted
  // periodically (not on every chunk) to avoid an allocation per chunk while still bounding
  // memory to roughly the largest single pending element (a keyframe SimpleBlock can be
  // 100KB+, confirmed against real captured data — the very first frame of an H.265 session,
  // which bundles VPS+SPS+PPS+IDR together, was 103990 bytes).
  Uint8List _buf = Uint8List(0);
  int _pos = 0; // read cursor into _buf

  bool _tracksEmitted = false;
  final List<MkvTrackInfo> _tracks = [];

  /// Nanoseconds per raw Matroska timecode unit, from the stream's own `Info`/`TimecodeScale`
  /// element — 1,000,000 (1ms/unit) is both the Matroska spec default and this producer's real,
  /// verified value, but read the real one rather than assuming it never changes.
  int _timecodeScaleNs = 1000000;

  // Cluster-scanning state — Cluster's own base timecode (in TimecodeScale units, default
  // 1,000,000 ns == 1ms/unit, so this is directly milliseconds in practice on this producer).
  int _clusterBaseTimecode = 0;
  bool _inCluster = false;

  /// [AI Fix] direct user hardware report 2026-09-18: real video freeze/~1fps playback with
  /// audio still advancing normally — traced to `BUG-031`'s multi-fragment handling being
  /// incomplete. Each `GetMedia` fragment is a standalone Matroska Segment with its own Cluster
  /// `Timecode`, relative only to *that* fragment's own Segment (confirmed against real captured
  /// bytes: a second fragment's first Cluster timecode was near-zero again, not continuing from
  /// where the previous fragment's timestamps left off). `BUG-031` only fixed *parsing* past a
  /// fragment boundary without erroring — it never made the emitted `MkvSample.timestampMs`
  /// sequence continuous across that boundary, so every fragment boundary produced a large
  /// backward jump in the output timestamps the WAN muxer bakes into `tfdt`. ExoPlayer's fMP4
  /// extractor treats `tfdt` as absolute presentation time; a stream of non-monotonic/regressing
  /// `tfdt` values is exactly the kind of malformed timing that stalls or drastically slows down
  /// visual playback while still accepting and buffering the underlying sample data (matching
  /// the reported symptom precisely: audio kept playing, since its own timestamp track hit the
  /// same reset but evidently degrades more gracefully, while video appeared frozen/~1fps).
  ///
  /// Fix: track the last emitted *output* timestamp and, the moment a new fragment's Segment
  /// boundary is detected ([_pumpSegmentBody]'s repeat-`_idSegment` branch), mark the offset as
  /// pending; the next Cluster `Timecode` element read afterward computes a one-time
  /// `_fragmentTimeOffsetMs` so this fragment's raw (near-zero-relative) timecodes continue
  /// seamlessly from where the previous fragment's output left off, instead of restarting near
  /// zero. Applied uniformly to every sample emit site ([_emitSimpleBlock]/[_emitBlockGroup]).
  int _fragmentTimeOffsetMs = 0;
  int _lastEmittedTimestampMs = -1;
  bool _pendingFragmentBoundary = false;

  void addChunk(Uint8List chunk) {
    if (chunk.isEmpty) return;
    _appendToBuffer(chunk);
    _pump();
  }

  void _appendToBuffer(Uint8List chunk) {
    final remaining = _buf.length - _pos;
    final next = Uint8List(remaining + chunk.length);
    next.setRange(0, remaining, _buf, _pos);
    next.setRange(remaining, remaining + chunk.length, chunk);
    _buf = next;
    _pos = 0;
  }

  /// Reads an EBML element ID at [_buf]\[[at]\] — the ID *keeps* its length-marker bits (unlike
  /// a vint value), since the ID itself (marker included) is what's compared against the
  /// `_id*` constants above. Returns null if not enough bytes are buffered yet.
  ({int id, int len})? _tryReadId(int at) {
    if (at >= _buf.length) return null;
    final first = _buf[at];
    if (first == 0) return null; // invalid EBML — caller should treat as unrecoverable
    var len = 1;
    var mask = 0x80;
    while ((first & mask) == 0) {
      len++;
      mask >>= 1;
      if (len > 4) return null; // invalid — IDs are at most 4 bytes
    }
    if (at + len > _buf.length) return null;
    var val = 0;
    for (var i = 0; i < len; i++) {
      val = (val << 8) | _buf[at + i];
    }
    return (id: val, len: len);
  }

  /// Reads an EBML "vint" (variable-length integer) at [_buf]\[[at]\], stripping the
  /// length-marker bit — used for element sizes. [unknown] is true for the reserved
  /// all-ones-after-marker pattern (Matroska's "size unknown, read until a sibling ID appears"
  /// convention, used by `Segment` and `Cluster` on a live stream). Returns null if not enough
  /// bytes are buffered yet.
  ({int value, int len, bool unknown})? _tryReadVint(int at) {
    if (at >= _buf.length) return null;
    final first = _buf[at];
    if (first == 0) return null;
    var len = 1;
    var mask = 0x80;
    while ((first & mask) == 0) {
      len++;
      mask >>= 1;
      if (len > 8) return null;
    }
    if (at + len > _buf.length) return null;
    var value = first & (mask - 1);
    var isAllOnes = value == (mask - 1);
    for (var i = 1; i < len; i++) {
      value = (value << 8) | _buf[at + i];
      if (_buf[at + i] != 0xFF) isAllOnes = false;
    }
    return (value: value, len: len, unknown: isAllOnes);
  }

  /// Main incremental parse loop — runs the whole buffered prefix as far as it can go, then
  /// returns (waiting for more bytes via the next [addChunk]). Re-entrant-safe to call again
  /// with the same state on the next chunk, since it never consumes ([_pos] never advances)
  /// past a fully-parsed element.
  void _pump() {
    while (true) {
      if (!_tracksEmitted) {
        if (!_pumpUntilTracks()) return;
        continue;
      }
      if (_inCluster) {
        if (!_pumpClusterChild()) return;
        continue;
      }
      if (!_pumpSegmentBody()) return;
    }
  }

  /// Walks EBML header -> Segment -> Info/Tracks, emitting [MkvTracksReady] once `Tracks` is
  /// fully parsed. Returns false if more bytes are needed to make further progress (caller
  /// should wait for the next chunk); returns true if it made progress and should be called
  /// again (e.g. after skipping one element) in case more is already buffered.
  bool _pumpUntilTracks() {
    final idAt = _pos;
    final idResult = _tryReadId(idAt);
    if (idResult == null) return false;
    final sizeAt = idAt + idResult.len;
    final sizeResult = _tryReadVint(sizeAt);
    if (sizeResult == null) return false;
    final bodyAt = sizeAt + sizeResult.len;

    if (idResult.id == _idEbml || idResult.id == _idSegment) {
      // Both known to have a body we should descend into (Segment's is unknown-size, so
      // "descending" just means: consume the header and keep scanning from bodyAt).
      if (idResult.id == _idSegment) {
        _pos = bodyAt;
        return true;
      }
      // EBML header has a known size — skip over it as a whole.
      if (sizeResult.unknown) return false; // malformed; wait, won't resolve on its own
      if (_buf.length < bodyAt + sizeResult.value) return false;
      _pos = bodyAt + sizeResult.value;
      return true;
    }

    if (idResult.id == _idTracks) {
      if (sizeResult.unknown) return false; // Tracks is always known-size on this producer
      if (_buf.length < bodyAt + sizeResult.value) return false;
      _tracks
        ..clear()
        ..addAll(_parseTracks(bodyAt, bodyAt + sizeResult.value));
      _pos = bodyAt + sizeResult.value;
      _tracksEmitted = true;
      _controller.add(MkvTracksReady(List.unmodifiable(_tracks)));
      return true;
    }

    if (idResult.id == _idInfo && !sizeResult.unknown) {
      if (_buf.length < bodyAt + sizeResult.value) return false;
      _parseInfo(bodyAt, bodyAt + sizeResult.value);
      _pos = bodyAt + sizeResult.value;
      return true;
    }

    // Anything else at this level (Tags, SeekHead, Void, CRC32, ...) before Tracks has been
    // seen — skip it whole if its size is known; if it's Cluster (shouldn't happen before
    // Tracks on this producer, but defensively) fall through to the same unknown-size handling
    // the post-Tracks path uses.
    if (!sizeResult.unknown) {
      if (_buf.length < bodyAt + sizeResult.value) return false;
      _pos = bodyAt + sizeResult.value;
      return true;
    }
    // Unknown-size element before Tracks (shouldn't occur in practice) — bail rather than loop
    // forever; treat as unrecoverable for this connection.
    _controller.addError(StateError(
        'Unexpected unknown-size element 0x${idResult.id.toRadixString(16)} before Tracks'));
    return false;
  }

  void _parseInfo(int start, int end) {
    var pos = start;
    while (pos < end) {
      final id = _tryReadId(pos)!;
      final size = _tryReadVint(pos + id.len)!;
      final bodyAt = pos + id.len + size.len;
      if (id.id == _idTimecodeScale) {
        _timecodeScaleNs = _readUint(bodyAt, bodyAt + size.value);
      }
      pos = bodyAt + size.value;
    }
  }

  List<MkvTrackInfo> _parseTracks(int start, int end) {
    final tracks = <MkvTrackInfo>[];
    var pos = start;
    while (pos < end) {
      final id = _tryReadId(pos)!;
      final size = _tryReadVint(pos + id.len)!;
      final bodyAt = pos + id.len + size.len;
      if (id.id == _idTrackEntry) {
        tracks.add(_parseTrackEntry(bodyAt, bodyAt + size.value));
      }
      pos = bodyAt + size.value;
    }
    return tracks;
  }

  MkvTrackInfo _parseTrackEntry(int start, int end) {
    int trackNumber = 0, trackType = 0;
    String codecId = '';
    Uint8List codecPrivate = Uint8List(0);
    int? width, height, samplingFrequency, channels;

    var pos = start;
    while (pos < end) {
      final id = _tryReadId(pos)!;
      final size = _tryReadVint(pos + id.len)!;
      final bodyAt = pos + id.len + size.len;
      final bodyEnd = bodyAt + size.value;
      switch (id.id) {
        case _idTrackNumber:
          trackNumber = _readUint(bodyAt, bodyEnd);
          break;
        case _idTrackType:
          trackType = _readUint(bodyAt, bodyEnd);
          break;
        case _idCodecId:
          codecId = String.fromCharCodes(_buf.sublist(bodyAt, bodyEnd));
          break;
        case _idCodecPrivate:
          codecPrivate = Uint8List.fromList(_buf.sublist(bodyAt, bodyEnd));
          break;
        case _idVideo:
          var vp = bodyAt;
          while (vp < bodyEnd) {
            final vid = _tryReadId(vp)!;
            final vsize = _tryReadVint(vp + vid.len)!;
            final vBodyAt = vp + vid.len + vsize.len;
            if (vid.id == _idPixelWidth) width = _readUint(vBodyAt, vBodyAt + vsize.value);
            if (vid.id == _idPixelHeight) height = _readUint(vBodyAt, vBodyAt + vsize.value);
            vp = vBodyAt + vsize.value;
          }
          break;
        case _idAudio:
          var ap = bodyAt;
          while (ap < bodyEnd) {
            final aid = _tryReadId(ap)!;
            final asize = _tryReadVint(ap + aid.len)!;
            final aBodyAt = ap + aid.len + asize.len;
            if (aid.id == _idSamplingFrequency) {
              samplingFrequency = _readIeeeFloat64(aBodyAt, aBodyAt + asize.value)?.round();
            }
            if (aid.id == _idChannels) channels = _readUint(aBodyAt, aBodyAt + asize.value);
            ap = aBodyAt + asize.value;
          }
          break;
        default:
          break;
      }
      pos = bodyEnd;
    }
    return MkvTrackInfo(
      trackNumber: trackNumber,
      trackType: trackType,
      codecId: codecId,
      codecPrivate: codecPrivate,
      width: width,
      height: height,
      samplingFrequency: samplingFrequency,
      channels: channels,
    );
  }

  int _readUint(int start, int end) {
    var v = 0;
    for (var i = start; i < end; i++) {
      v = (v << 8) | _buf[i];
    }
    return v;
  }

  /// EBML "Float" element (used for `SamplingFrequency`) — big-endian IEEE 754, 4 or 8 bytes.
  double? _readIeeeFloat64(int start, int end) {
    final len = end - start;
    final bytes = _buf.buffer.asByteData(_buf.offsetInBytes + start, len);
    if (len == 4) return bytes.getFloat32(0, Endian.big);
    if (len == 8) return bytes.getFloat64(0, Endian.big);
    return null;
  }

  /// Scans Segment-level children once Tracks has already been seen: skips known-size elements
  /// whole (Tags, Cues, ...), and for Cluster, parses its children (Timecode/SimpleBlock) one at
  /// a time via [_clusterLevelIds] to detect where it implicitly ends.
  ///
  /// **`BUG-031` (2026-09-17, real hardware finding):** AWS KVS's actual `GetMedia` response is
  /// **not** one continuous Segment for the whole live session — it's a sequence of self-contained
  /// Matroska "fragments," each a standalone document with its own fresh EBML header + Segment +
  /// Info + Tracks, confirmed directly against a real `GetMedia` byte stream (a second `Segment`
  /// element ID, `0x18538067`, appeared ~3s into a live session). This demuxer was built and
  /// fixture-tested only against a single captured fragment, so it treated the second fragment's
  /// EBML/Segment boundary as a fatal, unrecoverable error — and since the error path never
  /// advanced [_pos], every subsequent [addChunk] re-hit the exact same stuck byte position and
  /// re-threw, spamming thousands of identical errors while producing zero further [MkvSample]s
  /// forever (the app-visible symptom: WAN playback connects, decodes the very first segment, then
  /// never renders another frame — reported as "freezing"). Track info (codec/dimensions) is
  /// assumed stable across fragments of one `GetMedia` connection (same camera, same quality tier,
  /// same KVS producer config for the connection's lifetime), so a repeat EBML/Info/Tracks is
  /// skipped rather than re-parsed/re-emitted — re-emitting [MkvTracksReady] here would make
  /// `KvsMediaLiveViewSession` rebuild its muxer and inject a second init segment mid-stream,
  /// which an already-playing `video_player` does not expect.
  bool _pumpSegmentBody() {
    final idAt = _pos;
    final idResult = _tryReadId(idAt);
    if (idResult == null) return false;
    final sizeAt = idAt + idResult.len;
    final sizeResult = _tryReadVint(sizeAt);
    if (sizeResult == null) return false;
    final bodyAt = sizeAt + sizeResult.len;

    if (idResult.id == _idCluster) {
      _clusterBaseTimecode = 0;
      _inCluster = true;
      _pos = bodyAt;
      return true;
    }

    if (idResult.id == _idSegment) {
      // A new fragment's Segment (unknown-size) -- descend into its body, same as the very first
      // Segment in `_pumpUntilTracks`. This branch only ever fires for a second-or-later Segment
      // (the first is consumed by `_pumpUntilTracks` before `_tracksEmitted` flips true, see
      // `_pump()`), so it's an unconditional, reliable fragment-boundary signal -- see
      // `_fragmentTimeOffsetMs`'s own doc comment for why this needs to be tracked at all.
      _pendingFragmentBoundary = true;
      _pos = bodyAt;
      return true;
    }

    if (idResult.id == _idEbml || idResult.id == _idTracks || idResult.id == _idInfo) {
      // A new fragment's own EBML header / Info / Tracks -- all known-size on this producer;
      // skip whole, already have what we need from the first fragment.
      if (sizeResult.unknown) return false; // malformed; wait, won't resolve on its own
      if (_buf.length < bodyAt + sizeResult.value) return false;
      _pos = bodyAt + sizeResult.value;
      return true;
    }

    if (!sizeResult.unknown) {
      if (_buf.length < bodyAt + sizeResult.value) return false;
      _pos = bodyAt + sizeResult.value;
      return true;
    }
    // Unknown-size, non-Cluster/-Segment element at Segment level — not expected from this
    // producer.
    _controller.addError(
        StateError('Unexpected unknown-size element 0x${idResult.id.toRadixString(16)} at Segment level'));
    return false;
  }

  /// Called from [_pump] while [_inCluster] — kept as a distinct path from [_pumpSegmentBody]
  /// so the "is this ID still a Cluster child?" check runs on every element, not just at
  /// Cluster entry.
  bool _pumpClusterChild() {
    final idAt = _pos;
    final idResult = _tryReadId(idAt);
    if (idResult == null) return false;

    if (!_clusterLevelIds.contains(idResult.id)) {
      // Not a Cluster child -- the Cluster has implicitly ended; hand control back to
      // Segment-level scanning without consuming these bytes.
      _inCluster = false;
      return true;
    }

    final sizeAt = idAt + idResult.len;
    final sizeResult = _tryReadVint(sizeAt);
    if (sizeResult == null) return false;
    final bodyAt = sizeAt + sizeResult.len;
    if (sizeResult.unknown) {
      // BlockGroup is the only Cluster child that could plausibly be unknown-size in a general
      // Matroska stream; this producer has never been observed emitting one. Bail defensively
      // rather than loop forever on a shape this demuxer doesn't understand.
      _controller.addError(StateError(
          'Unexpected unknown-size element 0x${idResult.id.toRadixString(16)} inside Cluster'));
      return false;
    }
    if (_buf.length < bodyAt + sizeResult.value) return false;
    final bodyEnd = bodyAt + sizeResult.value;

    switch (idResult.id) {
      case _idTimecode:
        _clusterBaseTimecode = _readUint(bodyAt, bodyEnd);
        if (_pendingFragmentBoundary) {
          // First Cluster Timecode read since a fragment boundary. [AI Fix] corrected same day,
          // direct user hardware re-test: this camera's KVS producer actually encodes real
          // absolute Unix epoch milliseconds as the raw Cluster Timecode (confirmed against real
          // captured bytes -- printed values are exactly current-epoch-ms scale), not small
          // segment-relative values the way a generic Matroska stream normally would. So a real
          // fragment boundary's timestamps are already naturally continuous on their own -- only
          // this class's own synthetic multi-fragment *test* (which concatenates one captured
          // fragment with an exact byte-for-byte copy of itself) produces an artificial backward
          // jump, since the "second fragment" is literally the same captured moment replayed, not
          // a real later one. The first version of this fix computed and applied a correction
          // unconditionally on every real fragment boundary too, nudging already-correct
          // timestamps by a small (usually negative) amount every few seconds -- compounding into
          // exactly the "video not moving at all" regression a direct user report caught. Now
          // only ever applied when a real regression is detected (this fragment's own base is at
          // or behind what was already emitted) -- a genuine reset/backward jump, whatever
          // produces one, still gets corrected; naturally-continuous real timestamps are left
          // completely alone.
          final rawBaseMs = _rawUnitsToMs(_clusterBaseTimecode);
          if (rawBaseMs <= _lastEmittedTimestampMs) {
            _fragmentTimeOffsetMs = (_lastEmittedTimestampMs + 1) - rawBaseMs;
          }
          _pendingFragmentBoundary = false;
        }
        break;
      case _idSimpleBlock:
        _emitSimpleBlock(bodyAt, bodyEnd);
        break;
      case _idBlockGroup:
        _emitBlockGroup(bodyAt, bodyEnd);
        break;
      default:
        break; // Position/PrevSize/SilentTracks/Void/CRC32 -- not needed
    }
    _pos = bodyEnd;
    return true;
  }

  void _emitSimpleBlock(int start, int end) {
    var pos = start;
    final tn = _tryReadVint(pos)!;
    pos += tn.len;
    if (pos + 3 > end) return; // malformed; drop
    final relTimecode = (_buf[pos] << 8) | _buf[pos + 1];
    final signedRelTimecode = relTimecode >= 0x8000 ? relTimecode - 0x10000 : relTimecode;
    pos += 2;
    final flags = _buf[pos];
    pos += 1;
    final isKeyframe = (flags & 0x80) != 0;
    final data = Uint8List.fromList(_buf.sublist(pos, end));
    _controller.add(MkvSample(
      trackNumber: tn.value,
      timestampMs: _emitTimestampMs(_clusterBaseTimecode + signedRelTimecode),
      isKeyframe: isKeyframe,
      data: data,
    ));
  }

  /// Converts a raw Matroska timecode (in [_timecodeScaleNs]-sized units) to milliseconds.
  int _rawUnitsToMs(int rawUnits) => (rawUnits * _timecodeScaleNs) ~/ 1000000;

  /// [_rawUnitsToMs] plus [_fragmentTimeOffsetMs], and records the result as
  /// [_lastEmittedTimestampMs] so the *next* fragment boundary (if any) can compute its own
  /// offset relative to this one. Every sample emit site must go through this, never
  /// [_rawUnitsToMs] directly, or a fragment boundary's continuity fix silently stops applying
  /// to that site.
  int _emitTimestampMs(int rawUnits) {
    final ms = _rawUnitsToMs(rawUnits) + _fragmentTimeOffsetMs;
    _lastEmittedTimestampMs = ms;
    return ms;
  }

  /// `BlockGroup` -> `Block` (defensive fallback, see this class's own doc — not observed from
  /// this producer). `Block`'s own binary layout is identical to `SimpleBlock`'s except it has
  /// no flags byte with a keyframe bit; treated as non-keyframe, since `BlockGroup`'s own
  /// `ReferenceBlock` presence/absence isn't parsed here.
  void _emitBlockGroup(int start, int end) {
    var pos = start;
    while (pos < end) {
      final id = _tryReadId(pos);
      if (id == null) return;
      final size = _tryReadVint(pos + id.len);
      if (size == null || size.unknown) return;
      final bodyAt = pos + id.len + size.len;
      final bodyEnd = bodyAt + size.value;
      if (id.id == _idBlock) {
        var bp = bodyAt;
        final tn = _tryReadVint(bp)!;
        bp += tn.len;
        if (bp + 2 <= bodyEnd) {
          bp += 2; // relative timecode, ignored -- BlockGroup path unused in practice
          final data = Uint8List.fromList(_buf.sublist(bp, bodyEnd));
          _controller.add(MkvSample(
            trackNumber: tn.value,
            timestampMs: _emitTimestampMs(_clusterBaseTimecode),
            isKeyframe: false,
            data: data,
          ));
        }
      }
      pos = bodyEnd;
    }
  }

  Future<void> close() => _controller.close();
}

extension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
