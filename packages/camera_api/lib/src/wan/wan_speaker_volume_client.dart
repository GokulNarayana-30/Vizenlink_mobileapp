import '../camera_result.dart';
import 'iot_command_client.dart';

/// WAN counterpart to `lan/onvif/speaker_volume_client.dart`'s `SpeakerVolumeClient` —
/// `SetSpeakerVolume`/`GetSpeakerVolume` (`FR-NE-085`) have been `Implemented` and
/// hardware-verified on both LAN and WAN in firmware since 2026-07-28, but `AudioSettingsScreen`
/// never wired the WAN side until now.
///
/// Deliberately doesn't return `SpeakerVolumeClient`'s `SpeakerVolume` struct — that shape
/// (`token`/`name`/`outputToken`) exists only because ONVIF `SetAudioOutputConfiguration`
/// requires echoing those sibling fields back; the WAN command takes/reports a plain `volume`
/// percentage with none of that, so this client returns a bare `int` and lets the screen bridge
/// the two shapes (same pattern `_DayNightCard` already uses to bridge `ImagingSettings` (LAN)
/// against `wan.getDayNightMode()`'s plain string).
///
/// **Split out of the former combined `WanAudioVolumeClient` 2026-08-11** — mic gain, the
/// recording toggle, and test-sound are a separate, unrelated command group that happened to
/// live in the same class as this one; see `wan_audio_volume_client.dart` for those.
class WanSpeakerVolumeClient {
  WanSpeakerVolumeClient(String thingName, {IotCommandClient? iotCommandClient})
    : _iot = iotCommandClient ?? IotCommandClient(thingName);

  final IotCommandClient _iot;

  Future<CameraResult<int>> getSpeakerVolume({
    Duration timeout = const Duration(seconds: 15),
    bool retryOnTimeout = true,
  }) async {
    try {
      final output = await _iot.sendCommandWithResponse(
        IotCommandClient.getSpeakerVolume,
        timeoutSeconds: timeout.inMilliseconds / 1000,
        retryOnTimeout: retryOnTimeout,
      );
      if (output == null) return const CameraTimeout();
      final volume = output['volume'];
      if (volume is! num) {
        return CameraFailure(
          'GetSpeakerVolume response missing volume: $output',
        );
      }
      return CameraSuccess(volume.toInt());
    } catch (e) {
      return CameraFailure(e.toString());
    }
  }

  Future<CameraResult<void>> setSpeakerVolume(
    int volume, {
    Duration timeout = const Duration(seconds: 15),
    bool retryOnTimeout = true,
  }) async {
    try {
      final output = await _iot.sendCommandWithResponse(
        IotCommandClient.setSpeakerVolume,
        params: {'volume': volume},
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
