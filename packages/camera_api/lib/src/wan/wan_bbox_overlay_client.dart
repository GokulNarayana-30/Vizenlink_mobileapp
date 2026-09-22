import 'package:camera_api/camera_api.dart';

/// WAN counterpart to `BboxOverlayClient` (`camera_api`'s LAN NuraEye client) —
/// `GetBboxOverlayEnabled`/`SetBboxOverlayEnabled` (`FR-NE-123`, commands `74`/`73`). Same wire
/// vocabulary as LAN.
class WanBboxOverlayClient {
  WanBboxOverlayClient(String thingName, {IotCommandClient? iotCommandClient})
    : _iot = iotCommandClient ?? IotCommandClient(thingName);

  final IotCommandClient _iot;

  Future<CameraResult<bool>> isBboxOverlayEnabled({
    Duration timeout = const Duration(seconds: 15),
    bool retryOnTimeout = true,
  }) async {
    try {
      final output = await _iot.sendCommandWithResponse(
        IotCommandClient.getBboxOverlayEnabled,
        timeoutSeconds: timeout.inMilliseconds / 1000,
        retryOnTimeout: retryOnTimeout,
      );
      if (output == null) return const CameraTimeout();
      final enabled = output['enabled'];
      if (enabled is! bool) {
        return CameraFailure(
          'GetBboxOverlayEnabled response missing "enabled": $output',
        );
      }
      return CameraSuccess(enabled);
    } catch (e) {
      return CameraFailure(e.toString());
    }
  }

  Future<CameraResult<void>> setBboxOverlayEnabled(
    bool enabled, {
    Duration timeout = const Duration(seconds: 15),
    bool retryOnTimeout = true,
  }) async {
    try {
      final output = await _iot.sendCommandWithResponse(
        IotCommandClient.setBboxOverlayEnabled,
        params: {'enabled': enabled},
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
