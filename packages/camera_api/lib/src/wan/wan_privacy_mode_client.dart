import 'package:camera_api/camera_api.dart';

/// WAN counterpart to `PrivacyModeClient` (`camera_api`'s LAN-only NuraEye client) —
/// `SetPrivacyMode`/`GetPrivacyMode` (`FR-NE-093`, `FR-CF-138`) have been `Implemented` in
/// firmware since `FEAT-024`'s wider deterrence work, but `_PrivacyModeCard`
/// (`privacy_mode_settings_screen.dart`) never wired the WAN side — it hardcoded
/// `PrivacyModeClient(NuraeyeClient(widget.connection))` with no `isWan` awareness at all, unlike
/// its sibling `MaskEditorCard` on the same screen. Same `mode` (`None`/`Zone`/`Full`) wire
/// vocabulary as LAN, so this reuses `PrivacyMode`/`PrivacyModeWire` rather than a separate
/// WAN-only enum.
class WanPrivacyModeClient {
  WanPrivacyModeClient(String thingName, {IotCommandClient? iotCommandClient})
    : _iot = iotCommandClient ?? IotCommandClient(thingName);

  final IotCommandClient _iot;

  Future<CameraResult<PrivacyMode>> getPrivacyMode({
    Duration timeout = const Duration(seconds: 15),
    bool retryOnTimeout = true,
  }) async {
    try {
      final output = await _iot.sendCommandWithResponse(
        IotCommandClient.getPrivacyMode,
        timeoutSeconds: timeout.inMilliseconds / 1000,
        retryOnTimeout: retryOnTimeout,
      );
      if (output == null) return const CameraTimeout();
      final modeStr = output['mode'];
      if (modeStr is! String) {
        return CameraFailure('GetPrivacyMode response missing mode: $output');
      }
      final mode = PrivacyModeWire.fromWire(modeStr);
      if (mode == null) {
        return CameraFailure('Unrecognized privacy mode: $modeStr');
      }
      return CameraSuccess(mode);
    } catch (e) {
      return CameraFailure(e.toString());
    }
  }

  Future<CameraResult<void>> setPrivacyMode(
    PrivacyMode mode, {
    Duration timeout = const Duration(seconds: 15),
    bool retryOnTimeout = true,
  }) async {
    try {
      final output = await _iot.sendCommandWithResponse(
        IotCommandClient.setPrivacyMode,
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
