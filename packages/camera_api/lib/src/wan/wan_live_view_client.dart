import '../camera_result.dart';
import 'kvs_media/kvs_media_live_view_session.dart';

enum StreamStatus { active, idle, degraded, notCompiled }

/// The three KVS quality tiers `FR-CF-154` streams, matching the LAN RTSPS `/high`/`/medium`/
/// `/low` naming (`FR-CF-153`) — one AWS Kinesis Video Streams stream per tier, named
/// `<thing_name>-high`/`-medium`/`-low`.
enum StreamQuality { high, medium, low }

extension StreamQualityWire on StreamQuality {
  /// The exact string `params.quality` expects (`StartCloudStreaming`) and the exact KVS stream
  /// name suffix (`resolvePlaybackUri`) — same word, two uses, kept as one extension so they can
  /// never drift apart.
  String get wireValue => switch (this) {
    StreamQuality.high => 'high',
    StreamQuality.medium => 'medium',
    StreamQuality.low => 'low',
  };
}

/// WAN transport for the mobile live-view substream (FR-MOB-031/036): AWS IoT Core MQTT
/// command channel (`StartCloudStreaming`/`StopCloudStreaming`, renamed 2026-08-06 from
/// `StartLiveStream`/`StopLiveStream`, numeric MQTT values unchanged) plus
/// `GetCloudStreamingStatus` (FR-NE-068) and AWS KVS playback-session retrieval.
///
/// **FR-CF-154 (2026-09-14): quality-selective, reference-counted.** Every camera-side KVS
/// stream is a real, independently-billed AWS resource, so the app must start only the quality
/// the user actually picked, and multiple viewers of the same quality share one stream via a
/// camera-side reference count. [startCloudStreaming] now takes the requested [StreamQuality]
/// and returns a per-viewer lease [int] token; [stopCloudStreaming] and
/// [getCloudStreamingStatus] take that token back — passing it to `GetCloudStreamingStatus` *is*
/// the heartbeat that keeps the camera-side lease alive (it expires, and the camera tears the
/// stream down, after 30s with no refresh) — see `bsp_camera_pollKvsViewerLeases()` firmware-side.
abstract interface class WanLiveViewClient {
  /// Returns the viewer's lease token on success — pass it to every subsequent
  /// [stopCloudStreaming]/[getCloudStreamingStatus] call for this session.
  Future<CameraResult<int>> startCloudStreaming(StreamQuality quality);

  Future<CameraResult<void>> stopCloudStreaming(int token);

  /// Also refreshes the camera-side lease for [token] — call at least once every 30s while the
  /// session is meant to stay up, or the camera will drop the reference and, once the last viewer
  /// does, tear the stream down.
  Future<CameraResult<StreamStatus>> getCloudStreamingStatus(int token);

  /// Starts a [KvsMediaLiveViewSession] for the KVS-backed stream once [startCloudStreaming] +
  /// [getCloudStreamingStatus] report `active` — the caller reads [KvsMediaLiveViewSession.url]
  /// (a local loopback URL) to hand to `VideoPlayerController.networkUrl()`, and **must call
  /// [KvsMediaLiveViewSession.stop]** when tearing this playback attempt down (on transport
  /// switch, reconnect, or screen dispose) — unlike the old HLS-based `resolvePlaybackUri` this
  /// replaced (2026-09-17), the returned value is a live resource with its own background
  /// GetMedia connection and local HTTP server, not a static signed URL.
  ///
  /// **Replaces `resolvePlaybackUri`/`GetHLSStreamingSessionURL` entirely**, for both H.264 and
  /// H.265 — not just because AWS rejects an H.265 stream at that API outright
  /// (`UnsupportedStreamMediaTypeException`; `GetDASHStreamingSessionURL` has the identical
  /// restriction despite more permissive-sounding prose), but because unifying both codecs onto
  /// one WAN playback path (one health-check/reconnect/error-handling implementation) is simpler
  /// than maintaining two. See `KvsMediaLiveViewSession`'s own doc and
  /// `kb/raw/2026-09-17-code-kvs-media-viewer-credential-vending.md` for the full reasoning and
  /// live end-to-end verification this is based on.
  Future<CameraResult<KvsMediaLiveViewSession>> startMediaSession(StreamQuality quality);
}
