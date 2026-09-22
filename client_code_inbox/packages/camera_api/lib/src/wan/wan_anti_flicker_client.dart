import 'package:camera_api/camera_api.dart';

/// WAN counterpart to `AntiFlickerClient` (`camera_api`'s LAN-only NuraEye client) —
/// `SetAntiFlickerMode`/`GetAntiFlickerMode` (`FR-NE-109`, commands `55`/`54`). No ONVIF-standard
/// element exists for this setting (checked against the live `ImagingSettings20` schema — see
/// `kb/raw/2026-08-12-feature-antiflicker-mode.md`), so this is NuraEye-only on both transports
/// from the start, same shape as `WanMirrorFlipClient`. Same `mode` (`50Hz`/`60Hz`/`Auto`) wire
/// vocabulary as LAN, so this reuses `AntiFlickerMode`/`AntiFlickerModeWire` rather than a
/// separate WAN-only enum.
class WanAntiFlickerClient {
  WanAntiFlickerClient(String thingName, {IotCommandClient? iotCommandClient})
    : _iot = iotCommandClient ?? IotCommandClient(thingName);

  final IotCommandClient _iot;

  Future<CameraResult<AntiFlickerMode>> getAntiFlickerMode({
    Duration timeout = const Duration(seconds: 15),
    bool retryOnTimeout = true,
  }) async {
    try {
      final output = await _iot.sendCommandWithResponse(
        IotCommandClient.getAntiFlickerMode,
        timeoutSeconds: timeout.inMilliseconds / 1000,
        retryOnTimeout: retryOnTimeout,
      );
      if (output == null) return const CameraTimeout();
      final modeStr = output['mode'];
      if (modeStr is! String) {
        return CameraFailure(
          'GetAntiFlickerMode response missing mode: $output',
        );
      }
      final mode = AntiFlickerModeWire.fromWire(modeStr);
      if (mode == null) {
        return CameraFailure('Unrecognized anti-flicker mode: $modeStr');
      }
      return CameraSuccess(mode);
    } catch (e) {
      return CameraFailure(e.toString());
    }
  }

  Future<CameraResult<void>> setAntiFlickerMode(
    AntiFlickerMode mode, {
    Duration timeout = const Duration(seconds: 15),
    bool retryOnTimeout = true,
  }) async {
    try {
      final output = await _iot.sendCommandWithResponse(
        IotCommandClient.setAntiFlickerMode,
        params: {'mode': mode.wireValue},
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
