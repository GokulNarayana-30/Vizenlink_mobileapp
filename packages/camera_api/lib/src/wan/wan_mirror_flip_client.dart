import 'package:camera_api/camera_api.dart';

/// WAN counterpart to `MirrorFlipClient` (`camera_api`'s LAN-only NuraEye client) —
/// `SetMirrorFlip`/`GetMirrorFlip` (`FR-NE-039`, commands `11`/`12`) have been `Implemented`
/// and hardware-verified on both LAN and WAN in firmware since 2026-07-27
/// (`MF-LAN-*`/`MF-MQTT-*` all PASS), but this app only ever wired the LAN side until now —
/// `FR-MOB-074` explicitly flagged "WAN path not implemented — no MQTT command channel exists
/// in this app yet." Same `mode` (`Off`/`Mirror`/`Flip`/`Both`) wire vocabulary as LAN, so this
/// reuses `MirrorFlipMode`/`MirrorFlipModeWire` rather than a separate WAN-only enum.
class WanMirrorFlipClient {
  WanMirrorFlipClient(String thingName, {IotCommandClient? iotCommandClient})
    : _iot = iotCommandClient ?? IotCommandClient(thingName);

  final IotCommandClient _iot;

  Future<CameraResult<MirrorFlipMode>> getMirrorFlip({
    Duration timeout = const Duration(seconds: 15),
    bool retryOnTimeout = true,
  }) async {
    try {
      final output = await _iot.sendCommandWithResponse(
        IotCommandClient.getMirrorFlip,
        timeoutSeconds: timeout.inMilliseconds / 1000,
        retryOnTimeout: retryOnTimeout,
      );
      if (output == null) return const CameraTimeout();
      final modeStr = output['mode'];
      if (modeStr is! String) {
        return CameraFailure('GetMirrorFlip response missing mode: $output');
      }
      final mode = MirrorFlipModeWire.fromWire(modeStr);
      if (mode == null) {
        return CameraFailure('Unrecognized mirror/flip mode: $modeStr');
      }
      return CameraSuccess(mode);
    } catch (e) {
      return CameraFailure(e.toString());
    }
  }

  Future<CameraResult<void>> setMirrorFlip(
    MirrorFlipMode mode, {
    Duration timeout = const Duration(seconds: 15),
    bool retryOnTimeout = true,
  }) async {
    try {
      final output = await _iot.sendCommandWithResponse(
        IotCommandClient.setMirrorFlip,
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
