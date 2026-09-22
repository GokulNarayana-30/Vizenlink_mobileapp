import '../camera_result.dart';
import 'iot_command_client.dart';

/// WAN counterpart to `lan/nuraeye/audio_volume_client.dart`'s `AudioVolumeClient` mic-gain/
/// recording-toggle/test-sound half — `SetMicGain`/`GetMicGain` (`FR-NE-086`) have been
/// `Implemented` and hardware-verified on both LAN and WAN in firmware since 2026-07-28, but
/// `AudioSettingsScreen` never wired the WAN side until now.
///
/// **Recording on/off (`SetAudioRecording`/`GetAudioRecording`, `FR-NE-078`) was previously
/// documented here as "no WAN mirror — stays LAN-only," which was wrong** — the firmware
/// command has been `Implemented` and hardware-verified (`AUD-MQTT-01/02/03`,
/// `TEST.md` §5.44) since 2026-07-28; the app simply never called it. Wired 2026-08-11. The
/// test-tone commands (`playTestSound`/`stopTestSound`/`isTestSoundPlaying` below) similarly
/// stayed LAN-only until `FR-NE-107` (2026-08-11) — reversed by direct user instruction, since
/// a WAN user needs to confirm the speaker works just as much as a LAN one does.
///
/// **Split out of the former combined `WanAudioVolumeClient` 2026-08-11** — speaker volume is a
/// separate, unrelated command group that happened to live in the same class as these; see
/// `wan_speaker_volume_client.dart` for that one. This class kept its original name since it's
/// the majority-share half of the original.
class WanAudioVolumeClient {
  WanAudioVolumeClient(String thingName, {IotCommandClient? iotCommandClient})
    : _iot = iotCommandClient ?? IotCommandClient(thingName);

  final IotCommandClient _iot;

  Future<CameraResult<int>> getMicGain({
    Duration timeout = const Duration(seconds: 15),
    bool retryOnTimeout = true,
  }) async {
    try {
      final output = await _iot.sendCommandWithResponse(
        IotCommandClient.getMicGain,
        timeoutSeconds: timeout.inMilliseconds / 1000,
        retryOnTimeout: retryOnTimeout,
      );
      if (output == null) return const CameraTimeout();
      final gain = output['gain'];
      if (gain is! num) {
        return CameraFailure('GetMicGain response missing gain: $output');
      }
      return CameraSuccess(gain.toInt());
    } catch (e) {
      return CameraFailure(e.toString());
    }
  }

  Future<CameraResult<void>> setMicGain(
    int gain, {
    Duration timeout = const Duration(seconds: 15),
    bool retryOnTimeout = true,
  }) => _send(
    IotCommandClient.setMicGain,
    {'gain': gain},
    timeout,
    retryOnTimeout,
  );

  Future<CameraResult<bool>> isAudioRecordingEnabled({
    Duration timeout = const Duration(seconds: 15),
    bool retryOnTimeout = true,
  }) async {
    try {
      final output = await _iot.sendCommandWithResponse(
        IotCommandClient.getAudioRecording,
        timeoutSeconds: timeout.inMilliseconds / 1000,
        retryOnTimeout: retryOnTimeout,
      );
      if (output == null) return const CameraTimeout();
      final enabled = output['enabled'];
      if (enabled is! bool) {
        return CameraFailure(
          'GetAudioRecording response missing enabled: $output',
        );
      }
      return CameraSuccess(enabled);
    } catch (e) {
      return CameraFailure(e.toString());
    }
  }

  Future<CameraResult<void>> setAudioRecordingEnabled(
    bool enabled, {
    Duration timeout = const Duration(seconds: 15),
    bool retryOnTimeout = true,
  }) => _send(
    IotCommandClient.setAudioRecording,
    {'enabled': enabled},
    timeout,
    retryOnTimeout,
  );

  Future<CameraResult<void>> playTestSound({
    Duration timeout = const Duration(seconds: 15),
    bool retryOnTimeout = true,
  }) => _sendNoParams(IotCommandClient.playTestSound, timeout, retryOnTimeout);

  Future<CameraResult<void>> stopTestSound({
    Duration timeout = const Duration(seconds: 15),
    bool retryOnTimeout = true,
  }) => _sendNoParams(IotCommandClient.stopTestSound, timeout, retryOnTimeout);

  Future<CameraResult<bool>> isTestSoundPlaying({
    Duration timeout = const Duration(seconds: 15),
    bool retryOnTimeout = true,
  }) async {
    try {
      final output = await _iot.sendCommandWithResponse(
        IotCommandClient.getTestSoundStatus,
        timeoutSeconds: timeout.inMilliseconds / 1000,
        retryOnTimeout: retryOnTimeout,
      );
      if (output == null) return const CameraTimeout();
      final playing = output['playing'];
      if (playing is! bool) {
        return CameraFailure(
          'GetTestSoundStatus response missing playing: $output',
        );
      }
      return CameraSuccess(playing);
    } catch (e) {
      return CameraFailure(e.toString());
    }
  }

  Future<CameraResult<void>> _sendNoParams(
    int command,
    Duration timeout,
    bool retryOnTimeout,
  ) async {
    try {
      final output = await _iot.sendCommandWithResponse(
        command,
        timeoutSeconds: timeout.inMilliseconds / 1000,
        retryOnTimeout: retryOnTimeout,
      );
      if (output == null) return const CameraTimeout();
      return const CameraSuccess(null);
    } catch (e) {
      return CameraFailure(e.toString());
    }
  }

  Future<CameraResult<void>> _send(
    int command,
    Map<String, dynamic> params,
    Duration timeout,
    bool retryOnTimeout,
  ) async {
    try {
      final output = await _iot.sendCommandWithResponse(
        command,
        params: params,
        timeoutSeconds: timeout.inMilliseconds / 1000,
        retryOnTimeout: retryOnTimeout,
      );
      if (output == null) return const CameraTimeout();
      return const CameraSuccess(null);
    } catch (e) {
      return CameraFailure(e.toString());
    }
  }
}
