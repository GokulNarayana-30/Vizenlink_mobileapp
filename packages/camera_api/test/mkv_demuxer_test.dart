import 'dart:io';
import 'dart:typed_data';

import 'package:camera_api/src/wan/kvs_media/mkv_demuxer.dart';
import 'package:test/test.dart';

/// Validates [MkvDemuxer] against **real bytes captured from AWS KVS's own `GetMedia` API**
/// (`kvs_media_viewer_credentials_test.py`'s live-verified credential-vending path, 2026-09-17 —
/// see `kb/raw/2026-09-17-code-kvs-media-viewer-credential-vending.md`), not synthetic/hand-built
/// MKV data — the same "verify against what the real wire format actually is" standard this
/// repo's `mobile-app.md` rule already requires for LAN protocol clients.
void main() {
  final h265Bytes = File('test/fixtures/kvs_h265_fragment.mkv').readAsBytesSync();
  final h264Bytes = File('test/fixtures/kvs_h264_fragment.mkv').readAsBytesSync();

  /// Feeds [bytes] to a fresh [MkvDemuxer] in small chunks (not all at once) — the whole point
  /// of this class is incremental parsing across network chunk boundaries that don't align with
  /// element boundaries; a test that only ever calls `addChunk` once wouldn't exercise that.
  Future<List<MkvEvent>> demux(Uint8List bytes, {int chunkSize = 4096}) async {
    final demuxer = MkvDemuxer();
    final events = <MkvEvent>[];
    final sub = demuxer.events.listen(events.add);
    for (var i = 0; i < bytes.length; i += chunkSize) {
      demuxer.addChunk(bytes.sublist(i, (i + chunkSize).clamp(0, bytes.length)));
      await Future<void>.delayed(Duration.zero); // let the stream controller deliver
    }
    await sub.cancel();
    await demuxer.close();
    return events;
  }

  group('H.265 fixture (real GetMedia bytes, VZL-CAM-000001-high)', () {
    test('emits MkvTracksReady with correct video track info', () async {
      final events = await demux(h265Bytes);
      final tracksReady = events.whereType<MkvTracksReady>().single;
      final video = tracksReady.video!;
      expect(video.codecId, 'V_MPEG/ISO/HEVC');
      expect(video.isHevc, isTrue);
      expect(video.trackNumber, 1);
      // Real HEVCDecoderConfigurationRecord from this camera's actual firmware fix
      // (module_kvs_producer.c's prvGenerateH265CodecPrivateDataFromParams) -- starts with
      // configurationVersion=1.
      expect(video.codecPrivate.first, 1);
      expect(video.codecPrivate.length, greaterThan(20)); // real record, not a stub
    });

    test('emits MkvTracksReady with correct audio track info', () async {
      final events = await demux(h265Bytes);
      final tracksReady = events.whereType<MkvTracksReady>().single;
      final audio = tracksReady.audio!;
      expect(audio.codecId, 'A_AAC');
      expect(audio.isAudio, isTrue);
      expect(audio.trackNumber, 2);
    });

    test('first sample is a video keyframe with a real 4-byte-length-prefixed HEVC NALU', () async {
      final events = await demux(h265Bytes);
      final firstSample = events.whereType<MkvSample>().first;
      expect(firstSample.trackNumber, 1);
      expect(firstSample.isKeyframe, isTrue);
      // Verified by hand against the raw fixture bytes: first 4 bytes are a big-endian NALU
      // length (23), followed by a 2-byte HEVC NAL header (0x40 0x01 -- type 32 = VPS,
      // (0x40 >> 1) & 0x3F == 32).
      final data = firstSample.data;
      final naluLen = ByteData.sublistView(data, 0, 4).getUint32(0, Endian.big);
      expect(naluLen, 23);
      final nalType = (data[4] >> 1) & 0x3F;
      expect(nalType, 32); // VPS
    });

    test('emits many samples across both tracks, in wire order', () async {
      final events = await demux(h265Bytes);
      final samples = events.whereType<MkvSample>().toList();
      expect(samples.length, greaterThan(10));
      expect(samples.map((s) => s.trackNumber).toSet(), {1, 2});
    });
  });

  group('H.264 fixture (real GetMedia bytes, VZL-CAM-000001-medium)', () {
    test('emits MkvTracksReady with correct video track info', () async {
      final events = await demux(h264Bytes);
      final tracksReady = events.whereType<MkvTracksReady>().single;
      final video = tracksReady.video!;
      expect(video.codecId, 'V_MPEG4/ISO/AVC');
      expect(video.isAvc, isTrue);
    });

    test('first sample is a keyframe', () async {
      final events = await demux(h264Bytes);
      final firstSample = events.whereType<MkvSample>().first;
      expect(firstSample.isKeyframe, isTrue);
    });
  });

  test('chunk boundary position does not change the parsed result (H.265 fixture)', () async {
    // Odd/awkward sizes deliberately misalign against element boundaries without being slow
    // (a byte-at-a-time test over 550K+ bytes would be needlessly slow, not more correct).
    final a = await demux(h265Bytes, chunkSize: 7);
    final b = await demux(h265Bytes, chunkSize: 999983);
    final aSamples = a.whereType<MkvSample>().length;
    final bSamples = b.whereType<MkvSample>().length;
    expect(aSamples, bSamples);
    expect(aSamples, greaterThan(0));
  }, timeout: const Timeout(Duration(seconds: 60)));

  group('multi-fragment GetMedia stream (BUG-031)', () {
    // Real captured AWS KVS `GetMedia` responses turned out to NOT be one continuous Segment for
    // the whole live session -- they're a sequence of self-contained Matroska "fragments", each
    // with its own fresh EBML header + Segment + Info + Tracks. Each fixture file here is exactly
    // one such fragment (confirmed via `kvs_media_viewer_credentials_test.py`'s live capture), so
    // concatenating two of them and feeding that to one `MkvDemuxer` instance reproduces the real
    // wire shape that hit the bug on real hardware: the demuxer got permanently stuck the moment
    // it saw the second fragment's Segment ID, silently producing zero further samples forever
    // (the reported symptom: WAN playback connects, decodes the first fragment, then never
    // renders another frame). No error should reach [MkvDemuxer.events], and samples from BOTH
    // fragments must be emitted, not just the first.
    test('second fragment (same codec) parses with no demuxer error, samples from both fragments', () async {
      final twoFragments = Uint8List.fromList([...h265Bytes, ...h265Bytes]);
      final demuxer = MkvDemuxer();
      final events = <MkvEvent>[];
      final errors = <Object>[];
      final sub = demuxer.events.listen(events.add, onError: errors.add);
      const chunkSize = 4096;
      for (var i = 0; i < twoFragments.length; i += chunkSize) {
        demuxer.addChunk(twoFragments.sublist(i, (i + chunkSize).clamp(0, twoFragments.length)));
        await Future<void>.delayed(Duration.zero);
      }
      await sub.cancel();
      await demuxer.close();

      expect(errors, isEmpty);
      // Exactly one MkvTracksReady -- re-parsing/re-emitting on the second fragment's own Tracks
      // would make the caller (KvsMediaLiveViewSession) inject a second init segment mid-stream,
      // which an already-playing player does not expect.
      expect(events.whereType<MkvTracksReady>().length, 1);
      final singleFragmentSampleCount = (await demux(h265Bytes)).whereType<MkvSample>().length;
      final twoFragmentSampleCount = events.whereType<MkvSample>().length;
      expect(twoFragmentSampleCount, 2 * singleFragmentSampleCount);
    }, timeout: const Timeout(Duration(seconds: 60)));
  });
}
