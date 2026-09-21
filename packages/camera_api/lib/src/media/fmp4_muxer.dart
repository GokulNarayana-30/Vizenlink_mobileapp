import 'dart:typed_data';

/// Which video codec [RtspFmp4Muxer] is building the init segment's sample entry for --
/// H.264/`avc1`/`avcC` (the original, still-default case) or H.265/`hvc1`/`hvcC` (added
/// 2026-09-16, `FR-CF-012` mobile-app follow-up). [RtspLiveViewSession]/[RtspReplaySession]
/// detect this from the DESCRIBE SDP's `a=rtpmap` line and pass it straight through.
enum VideoCodec { h264, h265 }

/// Builds a minimal fragmented-MP4 (fMP4) byte stream from H.264/H.265 access units — the bridge
/// that lets `video_player`/ExoPlayer (no RTSP support at all) consume this camera's RTSPS
/// playback stream: [RtspRemuxProxy] serves [initSegment]'s bytes once, then one [fragment] per
/// decoded frame, over a local HTTP loopback, and ExoPlayer plays that exactly like any other
/// progressive/live fMP4 source.
///
/// One video track (H.264/`avc1`/`avcC`, or H.265/`hvc1`/`hvcC` -- selected via [videoCodec],
/// see [_buildHvcC]'s own doc for how that box differs from [_buildAvcC]'s; one NALU per sample,
/// 4-byte length-prefixed either way — **not** Annex-B start codes, a real and easy mistake this
/// comment exists to head off), one fragment per video frame (simplest correct mapping, not the
/// most efficient one — fine for this use case's frame rates, ~20fps). A second, optional audio
/// track (AAC/`mp4a`, `esds` box) was added 2026-09-02 (`FR-MOB-114` audio playback) — only built
/// when [audioSpecificConfig]/[audioSampleRate]/[audioChannelCount] are all given (i.e. the clip
/// actually has audio and `playback_demuxer_bind.c` populated it — see
/// `RtspReplaySession.hasAudio`'s own doc comment); `RtspRemuxProxy` omits them entirely for a
/// video-only clip, producing exactly the video-only file this muxer always built before.
///
/// Box-level format is hand-built per ISO/IEC 14496-12 ("ISOBMFF") — ftyp/moov/mvex/trak/mdia/
/// minf/stbl/stsd/avc1-or-hvc1/avcC-or-hvcC (+ mp4a/esds for the audio track) for the init
/// segment; moof/mfhd/traf/tfhd/tfdt/trun/mdat per fragment. No third-party muxing library used
/// (Dart has none suitable for fMP4 fragment-at-a-time streaming) — verified against the spec
/// directly, not copied from another codebase.
class RtspFmp4Muxer {
  RtspFmp4Muxer({
    required this.sps,
    required this.pps,
    required this.width,
    required this.height,
    this.videoCodec = VideoCodec.h264,
    this.vps,
    this.audioSpecificConfig,
    this.audioSampleRate,
    this.audioChannelCount,
    this.totalDurationSeconds,
  }) : assert(videoCodec != VideoCodec.h265 || vps != null,
            'vps is required when videoCodec is h265 -- hvcC needs all three parameter sets');

  /// 2026-09-02, `BUG-029` time-sync investigation — the clip's own known total duration
  /// (`clip.end - clip.start`, already known to the caller from `GetRecordings` before playback
  /// even starts), threaded through so `mvhd`/`tkhd`/`mdhd` can declare a real duration instead
  /// of `0`. Leaving duration `0` (this class's previous behavior) signals "unknown/growing" to
  /// ExoPlayer's extractor, which real-hardware testing found makes it treat the whole stream as
  /// unbounded live content rather than an ordinary bounded/seekable file -- `mvex`'s presence
  /// (needed for fragmentation) does NOT by itself imply "live" the way leaving duration
  /// unset/zero does; CMAF/fMP4 VOD content routinely has both. Under the "live" interpretation,
  /// `VideoPlayerController.value.position` was observed staying at a constant ~1ms for an
  /// entire multi-minute test regardless of how much real content had actually played --
  /// consistent with ExoPlayer reporting position relative to an always-advancing live edge
  /// rather than genuine elapsed playback time. A known, real duration should switch it back to
  /// ordinary VOD position semantics, which is what the app's on-screen clock needs to be able to
  /// rely on the player's own actual decode/render progress rather than purely how much data has
  /// been *received* over the network (see `recording_timeline_screen.dart`'s position-timer doc
  /// comment for that distinction and why it matters). `null` (e.g. a caller that hasn't looked
  /// up the clip's real end yet) preserves the exact previous behavior -- duration `0`.
  final int? totalDurationSeconds;

  /// Annex-B-start-code-stripped SPS/PPS, from [RtspReplaySession.sps]/`.pps`. For H.265 these
  /// still include their own 2-byte NAL header (vs. H.264's 1-byte) — see [_buildHvcC]'s doc.
  final Uint8List sps;
  final Uint8List pps;
  final int width;
  final int height;

  /// H.264 (default) or H.265 — selects `avc1`/`avcC` vs `hvc1`/`hvcC` sample entry construction
  /// in [initSegment]. See [VideoCodec]'s own doc.
  final VideoCodec videoCodec;

  /// Required when [videoCodec] is [VideoCodec.h265] (asserted in the constructor) — H.265's
  /// VPS, with its own 2-byte NAL header, same convention as [sps]/[pps]. `null` for H.264.
  final Uint8List? vps;

  /// 2026-09-02, `FR-MOB-114` audio playback — see this class's own doc comment for when these
  /// are/aren't given. [audioSampleRate] doubles as the audio track's own `mdhd` timescale (its
  /// natural unit — RTP's own audio clock already ticks at exactly this rate, so every
  /// [audioFragment] duration/`tfdt` value is a whole number with zero rounding error, same
  /// reasoning as [timescale] for video).
  final Uint8List? audioSpecificConfig;
  final int? audioSampleRate;
  final int? audioChannelCount;

  bool get hasAudioTrack => audioSpecificConfig != null && audioSampleRate != null && audioChannelCount != null;

  int _sequenceNumber = 0;

  /// `mdhd`/track timescale — 90000 (matches the RTP clock exactly, so every sample duration/
  /// `tfdt` value is a whole number with zero rounding error).
  static const int timescale = 90000;

  /// `ftyp` + `moov` (with `mvex`, marking this as fragmented) — write once, before any
  /// [fragment]. ExoPlayer's default extractor detects a fragmented `moov` (via `mvex`'s
  /// presence and `stts`/`stsz`/`stco` all reporting zero samples) and switches to fMP4/live-
  /// append handling automatically, the same way it would for any CMAF/DASH fMP4 source.
  Uint8List initSegment() {
    final isHevc = videoCodec == VideoCodec.h265;
    final ftyp = _box('ftyp', [
      ..._fourcc('isom'),
      ..._u32(0), // minor_version
      ..._fourcc('isom'),
      ..._fourcc('iso2'),
      ..._fourcc(isHevc ? 'hvc1' : 'avc1'),
      ..._fourcc('mp41'),
    ]);

    // VisualSampleEntry's own fixed fields (reserved/data_reference_index/width/height/etc.) are
    // byte-identical between `avc1` (AVCSampleEntry) and `hvc1` (HEVCSampleEntry) -- only the box
    // fourcc and the codec-config box nested inside differ (avcC vs hvcC).
    final codecConfig = isHevc ? _buildHvcC() : _buildAvcC();
    final sampleEntry = _box(isHevc ? 'hvc1' : 'avc1', [
      ..._zeros(6), // reserved
      ..._u16(1), // data_reference_index
      ..._u16(0), // pre_defined
      ..._u16(0), // reserved
      ..._zeros(12), // pre_defined[3]
      ..._u16(width),
      ..._u16(height),
      ..._u32(0x00480000), // horizresolution 72dpi
      ..._u32(0x00480000), // vertresolution 72dpi
      ..._u32(0), // reserved
      ..._u16(1), // frame_count
      ..._zeros(32), // compressorname
      ..._u16(0x0018), // depth
      ..._u16(0xFFFF), // pre_defined (-1)
      ...codecConfig,
    ]);

    final stsd = _box('stsd', [..._u32(0), ..._u32(1), ...sampleEntry]); // version+flags, entry_count=1
    final stts = _box('stts', [..._u32(0), ..._u32(0)]); // entry_count=0 -- fragmented
    final stsc = _box('stsc', [..._u32(0), ..._u32(0)]);
    final stsz = _box('stsz', [..._u32(0), ..._u32(0), ..._u32(0)]); // sample_size=0, sample_count=0
    final stco = _box('stco', [..._u32(0), ..._u32(0)]);
    final stbl = _box('stbl', [...stsd, ...stts, ...stsc, ...stsz, ...stco]);

    final vmhd = _box('vmhd', [..._u32(1), ..._u16(0), ..._u16(0), ..._u16(0), ..._u16(0)]);
    final url = _box('url ', [..._u32(1)]); // flags=1 -- self-contained, no actual URL needed
    final dref = _box('dref', [..._u32(0), ..._u32(1), ...url]);
    final dinf = _box('dinf', dref);
    final minf = _box('minf', [...vmhd, ...dinf, ...stbl]);

    final hdlr = _box('hdlr', [
      ..._u32(0), // version+flags
      ..._u32(0), // pre_defined
      ..._fourcc('vide'),
      ..._zeros(12), // reserved[3]
      ...'VideoHandler'.codeUnits,
      0, // NUL terminator
    ]);

    final mdhd = _box('mdhd', [
      ..._u32(0), // version+flags
      ..._u32(0), // creation_time
      ..._u32(0), // modification_time
      ..._u32(timescale),
      ..._u32(totalDurationSeconds != null ? totalDurationSeconds! * timescale : 0), // BUG-029: real duration when known, in this track's own timescale
      ..._u16(0x55C4), // language 'und'
      ..._u16(0), // pre_defined
    ]);

    final mdia = _box('mdia', [...mdhd, ...hdlr, ...minf]);

    final tkhd = _box('tkhd', [
      ..._u32(0x00000007), // version+flags: enabled | in_movie | in_preview
      ..._u32(0), // creation_time
      ..._u32(0), // modification_time
      ..._u32(1), // track_ID
      ..._u32(0), // reserved
      ..._u32(totalDurationSeconds != null ? totalDurationSeconds! * 1000 : 0), // BUG-029: real duration when known, in the MOVIE timescale (1000, see mvhd), not this track's own
      ..._zeros(8), // reserved[2]
      ..._u16(0), // layer
      ..._u16(0), // alternate_group
      ..._u16(0), // volume (0 for video track)
      ..._u16(0), // reserved
      ..._matrixIdentity(),
      ..._u32(width << 16), // width, 16.16 fixed point
      ..._u32(height << 16), // height, 16.16 fixed point
    ]);

    final trak = _box('trak', [...tkhd, ...mdia]);

    final mvhd = _box('mvhd', [
      ..._u32(0), // version+flags
      ..._u32(0), // creation_time
      ..._u32(0), // modification_time
      ..._u32(1000), // movie timescale (arbitrary; fragment/track timing uses `timescale` above)
      ..._u32(totalDurationSeconds != null ? totalDurationSeconds! * 1000 : 0), // BUG-029: real duration when known, in the movie timescale above
      ..._u32(0x00010000), // rate 1.0
      ..._u16(0x0100), // volume 1.0
      ..._u16(0), // reserved
      ..._zeros(8), // reserved[2]
      ..._matrixIdentity(),
      ..._zeros(24), // pre_defined[6]
      ..._u32(hasAudioTrack ? 3 : 2), // next_track_ID
    ]);

    final trex = _box('trex', [
      ..._u32(0), // version+flags
      ..._u32(1), // track_ID
      ..._u32(1), // default_sample_description_index
      ..._u32(0), // default_sample_duration -- explicit per-sample in trun instead
      ..._u32(0), // default_sample_size
      ..._u32(0), // default_sample_flags
    ]);

    final moovChildren = BytesBuilder()..add(mvhd)..add(trak);

    if (hasAudioTrack) {
      moovChildren.add(_buildAudioTrak());
      moovChildren.add(_box('mvex', [...trex, ..._buildAudioTrex()]));
    } else {
      moovChildren.add(_box('mvex', trex));
    }

    final moov = _box('moov', moovChildren.toBytes());

    final out = BytesBuilder();
    out.add(ftyp);
    out.add(moov);
    return out.toBytes();
  }

  /// 2026-09-02, `FR-MOB-114` audio playback — the audio track's own `trak` (track_ID=2),
  /// mirroring the video `trak` built above but with `smhd` (sound) instead of `vmhd` (video),
  /// `mp4a`/`esds` instead of `avc1`/`avcC`, and this track's own timescale ([audioSampleRate]).
  Uint8List _buildAudioTrak() {
    final mp4a = _buildMp4a();
    final audioStsd = _box('stsd', [..._u32(0), ..._u32(1), ...mp4a]);
    final audioStts = _box('stts', [..._u32(0), ..._u32(0)]);
    final audioStsc = _box('stsc', [..._u32(0), ..._u32(0)]);
    final audioStsz = _box('stsz', [..._u32(0), ..._u32(0), ..._u32(0)]);
    final audioStco = _box('stco', [..._u32(0), ..._u32(0)]);
    final audioStbl = _box('stbl', [...audioStsd, ...audioStts, ...audioStsc, ...audioStsz, ...audioStco]);

    final smhd = _box('smhd', [..._u32(0), ..._u16(0), ..._u16(0)]); // version+flags, balance, reserved
    final url = _box('url ', [..._u32(1)]);
    final dref = _box('dref', [..._u32(0), ..._u32(1), ...url]);
    final dinf = _box('dinf', dref);
    final audioMinf = _box('minf', [...smhd, ...dinf, ...audioStbl]);

    final audioHdlr = _box('hdlr', [
      ..._u32(0), ..._u32(0), ..._fourcc('soun'), ..._zeros(12),
      ...'SoundHandler'.codeUnits, 0,
    ]);
    final audioMdhd = _box('mdhd', [
      ..._u32(0), ..._u32(0), ..._u32(0),
      ..._u32(audioSampleRate!),
      ..._u32(totalDurationSeconds != null ? totalDurationSeconds! * audioSampleRate! : 0), // BUG-029: real duration when known, in this track's own timescale
      ..._u16(0x55C4), ..._u16(0), // language 'und'
    ]);
    final audioMdia = _box('mdia', [...audioMdhd, ...audioHdlr, ...audioMinf]);

    final audioTkhd = _box('tkhd', [
      ..._u32(0x00000007), // enabled | in_movie | in_preview
      ..._u32(0), ..._u32(0),
      ..._u32(2), // track_ID
      ..._u32(0), // reserved
      ..._u32(totalDurationSeconds != null ? totalDurationSeconds! * 1000 : 0), // BUG-029: real duration when known, in the MOVIE timescale (1000, see mvhd)
      ..._zeros(8), // reserved[2]
      ..._u16(0), ..._u16(0),
      ..._u16(0x0100), // volume 1.0 -- audio track, unlike video's 0
      ..._u16(0),
      ..._matrixIdentity(),
      ..._u32(0), ..._u32(0), // width/height -- 0 for a non-visual track
    ]);

    return _box('trak', [...audioTkhd, ...audioMdia]);
  }

  Uint8List _buildAudioTrex() {
    return _box('trex', [
      ..._u32(0),
      ..._u32(2), // track_ID
      ..._u32(1),
      ..._u32(0),
      ..._u32(0),
      ..._u32(0),
    ]);
  }

  /// `AudioSampleEntry` (ISO/IEC 14496-12 §12.2.3) wrapping [_buildEsds]'s `esds` box.
  Uint8List _buildMp4a() {
    final esds = _buildEsds();
    return _box('mp4a', [
      ..._zeros(6), // SampleEntry's own reserved
      ..._u16(1), // data_reference_index
      ..._zeros(8), // AudioSampleEntry's own reserved[2]
      ..._u16(audioChannelCount!),
      ..._u16(16), // samplesize -- 16-bit PCM equivalent, standard for AAC regardless of real bit depth
      ..._u16(0), // pre_defined
      ..._u16(0), // reserved
      ..._u32(audioSampleRate! << 16), // samplerate, 16.16 fixed-point
      ...esds,
    ]);
  }

  /// `esds` (ISO/IEC 14496-1 "ES_Descriptor", wrapped in the MP4 box per 14496-14 §5.6) --
  /// carries [audioSpecificConfig] (this camera's own AAC config, parsed from the SDP's
  /// `a=fmtp` by `RtspReplaySession`) so the decoder knows the sample rate/channel config/object
  /// type without needing an ADTS header on every sample (raw AAC access units, matching what
  /// `RtspReplaySession.audioAccessUnits` emits).
  Uint8List _buildEsds() {
    final decoderSpecificInfo = _mp4Descriptor(0x05, audioSpecificConfig!);
    final decoderConfig = _mp4Descriptor(0x04, [
      0x40, // objectTypeIndication: MPEG-4 AAC
      0x15, // streamType=5 (audio) << 2 | upStream=0 << 1 | reserved=1
      0x00, 0x00, 0x00, // bufferSizeDB (24-bit)
      0x00, 0x01, 0xF4, 0x00, // maxBitrate (128kbps -- a generous placeholder, not read by decoders for playback)
      0x00, 0x01, 0xF4, 0x00, // avgBitrate (same placeholder)
      ...decoderSpecificInfo,
    ]);
    final slConfig = _mp4Descriptor(0x06, [0x02]); // predefined = MP4 file format
    final esDescriptor = _mp4Descriptor(0x03, [
      0x00, 0x01, // ES_ID = 1
      0x00, // flags: no stream dependence/URL/OCR
      ...decoderConfig,
      ...slConfig,
    ]);
    return _box('esds', [..._u32(0), ...esDescriptor]); // version+flags(4) + the descriptor tree
  }

  /// MPEG-4 descriptor framing (ISO/IEC 14496-1 §8.3.3) -- a 1-byte tag, then a "expandable"
  /// length (7 bits per byte, high bit = more bytes follow, big-endian byte order), then the
  /// body. Every descriptor `esds` nests ([_buildEsds]) uses this exact framing.
  static List<int> _mp4Descriptor(int tag, List<int> body) {
    final sizeBytes = <int>[];
    var size = body.length;
    do {
      sizeBytes.insert(0, size & 0x7F);
      size >>= 7;
    } while (size > 0);
    final out = BytesBuilder()..addByte(tag);
    for (var i = 0; i < sizeBytes.length; i++) {
      out.addByte(sizeBytes[i] | (i < sizeBytes.length - 1 ? 0x80 : 0));
    }
    out.add(body);
    return out.toBytes();
  }

  /// One `moof`+`mdat` audio fragment for a single AAC access unit ([aac], raw bytes, no ADTS
  /// header, no length prefix -- unlike [fragment]'s `avc1` samples, an `mp4a` sample entry
  /// expects the raw AAC access unit directly). [baseMediaDecodeTimeAudioTicks]/[durationTicks]
  /// are in this track's OWN timescale ([audioSampleRate]), not video's 90kHz -- the caller
  /// (`RtspRemuxProxy`) derives both from [AacAccessUnit.rtpTimestamp], RTP audio's own clock
  /// already ticking at exactly the sample rate. Shares [fragment]'s `_sequenceNumber` counter
  /// (ISO/IEC 14496-12 §8.8.5 `mfhd` -- monotonically increasing across the whole fragment
  /// sequence, not per-track, when each track gets its own `moof`/`mdat` pair the way both
  /// [fragment] and this method do).
  Uint8List audioFragment({
    required Uint8List aac,
    required int baseMediaDecodeTimeAudioTicks,
    required int durationTicks,
  }) {
    _sequenceNumber++;

    final mfhd = _box('mfhd', [..._u32(0), ..._u32(_sequenceNumber)]);
    final tfhd = _box('tfhd', [..._u32(0x00020000), ..._u32(2)]); // default-base-is-moof, track_ID=2
    final tfdt = _box('tfdt', [..._u32(0x01000000), ..._u64(baseMediaDecodeTimeAudioTicks)]);

    // Every AAC access unit is independently decodable -- always a "sync sample", unlike video's
    // inter-predicted frames (sample_depends_on=2, sample_is_non_sync_sample=0).
    const sampleFlags = 0x02000000;
    const trunFlags = 0x000001 | 0x000100 | 0x000200 | 0x000400;
    final trunBodyWithoutDataOffset = BytesBuilder()
      ..add(_u32(trunFlags))
      ..add(_u32(1))
      ..add(_u32(0)) // data_offset placeholder, patched below
      ..add(_u32(durationTicks))
      ..add(_u32(aac.length)) // no AVCC-style length prefix for mp4a samples
      ..add(_u32(sampleFlags));
    final trun = _box('trun', trunBodyWithoutDataOffset.toBytes());

    final traf = _box('traf', [...tfhd, ...tfdt, ...trun]);
    final moof = _box('moof', [...mfhd, ...traf]);

    final dataOffset = moof.length + 8;
    final moofBytes = Uint8List.fromList(moof);
    final trunBoxOffsetInMoof = moof.length - trun.length;
    final dataOffsetFieldOffset = trunBoxOffsetInMoof + 8 + 4 + 4;
    moofBytes.buffer.asByteData().setUint32(dataOffsetFieldOffset, dataOffset, Endian.big);

    final mdat = _box('mdat', aac);

    final out = BytesBuilder();
    out.add(moofBytes);
    out.add(mdat);
    return out.toBytes();
  }

  Uint8List _buildAvcC() {
    final profileIdc = sps.length > 1 ? sps[1] : 0;
    final profileCompat = sps.length > 2 ? sps[2] : 0;
    final levelIdc = sps.length > 3 ? sps[3] : 0;
    final out = BytesBuilder();
    out.addByte(1); // configurationVersion
    out.addByte(profileIdc);
    out.addByte(profileCompat);
    out.addByte(levelIdc);
    out.addByte(0xFF); // reserved(6)=111111 + lengthSizeMinusOne=11 -> 4-byte length field
    out.addByte(0xE1); // reserved(3)=111 + numOfSequenceParameterSets=00001
    out.add(_u16(sps.length));
    out.add(sps);
    out.addByte(1); // numOfPictureParameterSets
    out.add(_u16(pps.length));
    out.add(pps);
    return _box('avcC', out.toBytes());
  }

  /// `hvcC` (`HEVCDecoderConfigurationRecord`, ISO/IEC 14496-15 §8.3.3.1) -- the H.265
  /// counterpart of [_buildAvcC]. [sps]/[pps]/[vps] all include their own 2-byte NAL header (as
  /// captured from the camera's DESCRIBE SDP / in-band VPS NALU — see `RtspLiveViewSession`'s
  /// own doc on why VPS specifically comes from the RTP stream, not the SDP, on this camera).
  ///
  /// `profile_tier_level()` (ISO/IEC 23008-2 §7.3.3) is byte-aligned and fixed-width all the way
  /// through `general_level_idc` in principle — but NOT safely readable at fixed byte offsets
  /// directly out of the raw SPS bytes the way this comment used to claim: H.26x RBSP data
  /// carries emulation-prevention bytes (a `0x03` inserted after any `00 00` byte pair, so a
  /// start-code-like sequence never appears mid-NALU by accident) that must be stripped before
  /// any fixed-position field can be trusted, and this SPS's own `profile_compatibility_flags`/
  /// `constraint_indicator_flags` region is mostly zero bits -- exactly the pattern that
  /// triggers emulation-prevention stuffing. **Real bug, hardware-confirmed 2026-09-16**: an
  /// actual recorded clip's SPS hit `00 00 03` three times within the first 15 bytes, and the
  /// naive byte-offset read this comment used to describe landed on a stuffing byte for
  /// `general_level_idc`, producing `0` -- not a valid HEVC level, which made playback fail
  /// (`ExoPlayer`/`MediaCodec` capability negotiation rejecting the track). Fixed by using fixed,
  /// safe, always-valid defaults for these fields instead of parsing them from the SPS at all --
  /// same "real values where cheap and direct, reasonable fixed defaults elsewhere" trade-off
  /// [_buildAvcC] already makes (whose own 1-byte-offset profile/compat/level read happens to
  /// dodge this problem in practice, since H.264's SPS starts with profile_idc, rarely `0x00`,
  /// before any compatibility-flags region prone to stuffing) and [_parseSpsDimensions] makes for
  /// width/height. These defaults (Main profile, 4:2:0, 8-bit, 1 temporal layer, a generously
  /// high level) cost nothing at decode time: a real HEVC decoder re-derives its actual working
  /// parameters from the SPS's own (correctly, verbatim, stuffing-bytes-included) bits once it
  /// starts decoding -- hvcC's copies of these fields are capability-negotiation-only, and only
  /// need to be *valid*, not exactly true, for that negotiation to succeed.
  Uint8List _buildHvcC() {
    const generalProfileSpace = 0;
    const generalTierFlag = 0; // Main tier
    const generalProfileIdc = 1; // Main profile -- matches this camera's only exposed H.265 ONVIF encoder profile
    const compatFlags = 0x60000000; // compatible with profile 1 (Main) and 2 (Main10)
    final constraintFlags = List<int>.filled(6, 0); // no constraints imposed -- maximally decoder-compatible
    const generalLevelIdc = 150; // level 5.0 -- comfortably covers this camera's resolutions; over-declaring costs nothing

    final out = BytesBuilder();
    out.addByte(1); // configurationVersion
    out.addByte((generalProfileSpace << 6) | (generalTierFlag << 5) | generalProfileIdc);
    out.add(_u32(compatFlags));
    out.add(constraintFlags); // 48-bit general_constraint_indicator_flags
    out.addByte(generalLevelIdc);
    out.add(_u16(0xF000)); // reserved(4)=1111 + min_spatial_segmentation_idc(12)=0
    out.addByte(0xFC); // reserved(6)=111111 + parallelismType(2)=00 (unknown)
    out.addByte(0xFD); // reserved(6)=111111 + chromaFormat(2)=01 (4:2:0)
    out.addByte(0xF8); // reserved(5)=11111 + bitDepthLumaMinus8(3)=000
    out.addByte(0xF8); // reserved(5)=11111 + bitDepthChromaMinus8(3)=000
    out.add(_u16(0)); // avgFrameRate=0 (unspecified)
    // constantFrameRate(2)=00 | numTemporalLayers(3)=001 | temporalIdNested(1)=0 |
    // lengthSizeMinusOne(2)=11 (4-byte length, matches fragment()'s length-prefix convention).
    out.addByte(0x0B);

    final arrays = [
      _hvcParamSetArray(32, vps!), // VPS
      _hvcParamSetArray(33, sps), // SPS
      _hvcParamSetArray(34, pps), // PPS
    ];
    out.addByte(arrays.length); // numOfArrays
    for (final a in arrays) {
      out.add(a);
    }
    return _box('hvcC', out.toBytes());
  }

  /// One `HEVCParameterSetArray` (ISO/IEC 14496-15 §8.3.3.1) holding exactly one NAL unit --
  /// [_buildHvcC]'s own VPS/SPS/PPS entries never repeat/vary within one session on this camera.
  static List<int> _hvcParamSetArray(int nalUnitType, Uint8List nalUnit) {
    final out = BytesBuilder();
    out.addByte(0x80 | (nalUnitType & 0x3F)); // array_completeness=1, reserved=0, NAL_unit_type
    out.add(_u16(1)); // numNalus
    out.add(_u16(nalUnit.length));
    out.add(nalUnit);
    return out.toBytes();
  }

  /// One `moof`+`mdat` fragment for a single access unit ([nalu], no start code/length prefix --
  /// [RtspReplaySession.accessUnits] emits raw NALU bytes). [rtpTimestamp90k] is this camera's
  /// own RTP clock value for the frame (see [H264AccessUnit]); [durationTicks] is how long this
  /// frame occupies the timeline, in the same 90kHz units — the caller derives it from the gap to
  /// the *next* access unit (or a fallback default for the last frame before a pause/stream end).
  Uint8List fragment({
    required Uint8List nalu,
    required int baseMediaDecodeTime90k,
    required int durationTicks,
    required bool isKeyframe,
  }) {
    _sequenceNumber++;

    final mfhd = _box('mfhd', [..._u32(0), ..._u32(_sequenceNumber)]);

    final tfhd = _box('tfhd', [
      ..._u32(0x00020000), // flags: default-base-is-moof
      ..._u32(1), // track_ID
    ]);

    final tfdt = _box('tfdt', [
      ..._u32(0x01000000), // version=1, flags=0 -- 64-bit baseMediaDecodeTime
      ..._u64(baseMediaDecodeTime90k),
    ]);

    // sample_flags: sample_depends_on (bits 25-24) + sample_is_non_sync_sample (bit 16), per
    // ISO/IEC 14496-12 §8.8.3.1 -- keyframe: depends_on=2 (does not depend on others),
    // non-sync=0. Non-keyframe: depends_on=1 (depends on others), non-sync=1.
    final sampleFlags = isKeyframe ? 0x02000000 : 0x01010000;

    // trun flags: data-offset-present(0x000001) | sample-duration-present(0x000100) |
    // sample-size-present(0x000200) | sample-flags-present(0x000400).
    const trunFlags = 0x000001 | 0x000100 | 0x000200 | 0x000400;
    final trunBodyWithoutDataOffset = BytesBuilder()
      ..add(_u32(trunFlags))
      ..add(_u32(1)) // sample_count
      ..add(_u32(0)) // data_offset placeholder, patched below
      ..add(_u32(durationTicks))
      ..add(_u32(nalu.length + 4)) // sample_size -- includes the 4-byte AVCC length prefix
      ..add(_u32(sampleFlags));
    final trun = _box('trun', trunBodyWithoutDataOffset.toBytes());

    final traf = _box('traf', [...tfhd, ...tfdt, ...trun]);
    final moof = _box('moof', [...mfhd, ...traf]);

    // data_offset = bytes from the start of moof to the first byte of this sample's data, which
    // sits right after mdat's own 8-byte header (4-byte size + 'mdat' fourcc).
    final dataOffset = moof.length + 8;
    final moofBytes = Uint8List.fromList(moof);
    // trun's data_offset field is the 3rd u32 in its body, itself 8 bytes into the trun box
    // (4-byte size + 4-byte 'trun' fourcc) after the box header, i.e. at
    // trunBoxStart + 8 (box header) + 4 (flags) + 4 (sample_count) = +16.
    final trunBoxOffsetInMoof = moof.length - trun.length;
    final dataOffsetFieldOffset = trunBoxOffsetInMoof + 8 + 4 + 4;
    moofBytes.buffer.asByteData().setUint32(dataOffsetFieldOffset, dataOffset, Endian.big);

    final sampleData = BytesBuilder()
      ..add(_u32(nalu.length))
      ..add(nalu);
    final mdat = _box('mdat', sampleData.toBytes());

    final out = BytesBuilder();
    out.add(moofBytes);
    out.add(mdat);
    return out.toBytes();
  }

  // ---- box-building helpers -------------------------------------------------------------

  static Uint8List _box(String fourcc, List<int> body) {
    final out = BytesBuilder();
    out.add(_u32(body.length + 8));
    out.add(_fourcc(fourcc));
    out.add(body);
    return out.toBytes();
  }

  static List<int> _fourcc(String s) => s.codeUnits;
  static List<int> _u16(int v) => [(v >> 8) & 0xFF, v & 0xFF];
  static List<int> _u32(int v) =>
      [(v >> 24) & 0xFF, (v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF];
  static List<int> _u64(int v) {
    final hi = (v >> 32) & 0xFFFFFFFF;
    final lo = v & 0xFFFFFFFF;
    return [..._u32(hi), ..._u32(lo)];
  }
  static List<int> _zeros(int n) => List.filled(n, 0);
  static List<int> _matrixIdentity() => [
        ..._u32(0x00010000), ..._u32(0), ..._u32(0),
        ..._u32(0), ..._u32(0x00010000), ..._u32(0),
        ..._u32(0), ..._u32(0), ..._u32(0x40000000),
      ];
}
