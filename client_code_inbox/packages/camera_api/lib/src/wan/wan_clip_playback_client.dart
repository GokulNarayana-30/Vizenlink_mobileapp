import 'package:camera_api/camera_api.dart';

/// WAN recorded-clip playback control (`FR-CF-152`, commands 75–79): the camera streams the
/// chosen clip into a dedicated KVS stream, [streamName], which the app plays with
/// `KvsMediaLiveViewSession` — the WAN counterpart of LAN `OnvifReplayControlClient` +
/// `RtspRemuxProxy`. One playback session camera-wide; starting a new one replaces the old.
class WanClipPlaybackClient {
  WanClipPlaybackClient(String thingName, {IotCommandClient? iotCommandClient})
    : streamName = wanClipPlaybackStreamName(thingName),
      _iot = iotCommandClient ?? IotCommandClient(thingName);

  /// The KVS stream the camera writes playback into (`"<thingName>-playback"`).
  final String streamName;
  final IotCommandClient _iot;

  /// Start can take several seconds (the camera opens a KVS PutMedia session) — no automatic
  /// retry, since a second Start would restart a session that may already be coming up.
  Future<CameraResult<void>> startClip(int clipId, {int startMs = 0}) => _send(
    IotCommandClient.startClipPlayback,
    params: {'clip_epoch_start': clipId, 'start_time_ms': startMs},
    timeoutSeconds: 30,
    retryOnTimeout: false,
  );

  Future<CameraResult<void>> seekClip(int clipId, int startMs) => _send(
    IotCommandClient.seekClipPlayback,
    params: {'clip_epoch_start': clipId, 'start_time_ms': startMs},
    timeoutSeconds: 20,
    retryOnTimeout: false,
  );

  Future<CameraResult<void>> pause() =>
      _send(IotCommandClient.pauseClipPlayback);

  Future<CameraResult<void>> resume({int startMs = 0}) => _send(
    IotCommandClient.resumeClipPlayback,
    params: startMs > 0 ? {'start_time_ms': startMs} : null,
  );

  /// Safe when nothing is playing.
  Future<CameraResult<void>> stop() =>
      _send(IotCommandClient.stopClipPlayback, timeoutSeconds: 20);

  /// Refreshes the camera's idle-lease clock for the active session and reports whether one is
  /// still active. The camera stops an unattended session after 30s with no heartbeat (mirrors
  /// live view's own `GetCloudStreamingStatus` lease pattern) to avoid unbounded KVS PutMedia
  /// billing from a vanished client -- callers must call this periodically (every ~10s) for as
  /// long as a session is meant to stay open, the same cadence `LiveViewController` already uses
  /// for its own WAN health poll.
  Future<CameraResult<bool>> heartbeat() async {
    try {
      final output = await _iot.sendCommandWithResponse(
        IotCommandClient.getClipPlaybackStatus,
      );
      if (output == null) return const CameraTimeout();
      final active = output['active'];
      if (active is! bool) {
        return CameraFailure(
          'GetClipPlaybackStatus response missing active: $output',
        );
      }
      return CameraSuccess(active);
    } catch (e) {
      return CameraFailure(e.toString());
    }
  }

  Future<CameraResult<void>> _send(
    int command, {
    Map<String, dynamic>? params,
    double? timeoutSeconds,
    bool retryOnTimeout = true,
  }) async {
    try {
      final output = await _iot.sendCommandWithResponse(
        command,
        params: params,
        timeoutSeconds: timeoutSeconds,
        retryOnTimeout: retryOnTimeout,
      );
      if (output == null) return const CameraTimeout();
      return const CameraSuccess(null);
    } catch (e) {
      return CameraFailure(e.toString());
    }
  }
}

/// The KVS stream name the camera's clip-playback producer publishes to.
String wanClipPlaybackStreamName(String thingName) => '$thingName-playback';
