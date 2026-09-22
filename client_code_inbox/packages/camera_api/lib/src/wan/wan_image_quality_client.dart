import 'package:camera_api/camera_api.dart';

/// WAN counterpart to `OnvifImagingClient`'s ISP image-quality fields (brightness/contrast/
/// saturation/sharpness/white-balance/exposure) — `GetImageSettings`/`SetImageSettings`/
/// `GetImageSettingsOptions` (commands `13`/`14`/`15`, `NF10`/`FR-NE-074/075/077`), pre-existing
/// in firmware but never wired into the app until the 2026-08-05 options-parity audit
/// (`kb/raw/2026-08-05-code-options-parity-rule-audit.md`) found the gap.
class WanImageQualityClient {
  WanImageQualityClient(String thingName, {IotCommandClient? iotCommandClient})
    : _iot = iotCommandClient ?? IotCommandClient(thingName);

  final IotCommandClient _iot;

  Future<CameraResult<Map<String, dynamic>>> getImageSettings({
    Duration timeout = const Duration(seconds: 15),
    bool retryOnTimeout = true,
  }) async {
    try {
      final output = await _iot.sendCommandWithResponse(
        IotCommandClient.getImageSettings,
        timeoutSeconds: timeout.inMilliseconds / 1000,
        retryOnTimeout: retryOnTimeout,
      );
      if (output == null) return const CameraTimeout();
      return CameraSuccess(output);
    } catch (e) {
      return CameraFailure(e.toString());
    }
  }

  Future<CameraResult<Map<String, dynamic>>> setImageSettings(
    Map<String, dynamic> params, {
    Duration timeout = const Duration(seconds: 15),
    bool retryOnTimeout = true,
  }) async {
    try {
      final output = await _iot.sendCommandWithResponse(
        IotCommandClient.setImageSettings,
        params: params,
        timeoutSeconds: timeout.inMilliseconds / 1000,
        retryOnTimeout: retryOnTimeout,
      );
      if (output == null) return const CameraTimeout();
      return CameraSuccess(output);
    } catch (e) {
      return CameraFailure(e.toString());
    }
  }

  Future<CameraResult<Map<String, dynamic>>> getImageSettingsOptions({
    Duration timeout = const Duration(seconds: 15),
    bool retryOnTimeout = true,
  }) async {
    try {
      final output = await _iot.sendCommandWithResponse(
        IotCommandClient.getImageSettingsOptions,
        timeoutSeconds: timeout.inMilliseconds / 1000,
        retryOnTimeout: retryOnTimeout,
      );
      if (output == null) return const CameraTimeout();
      return CameraSuccess(output);
    } catch (e) {
      return CameraFailure(e.toString());
    }
  }

  /// `FR-MOB-075`'s "Reset to Default" source over WAN — `GetImageDefaults` (`FR-NE-076`,
  /// command `16`), read-only, distinct from [getImageSettings]. Same field shape
  /// (`nuraeye.c`'s WAN case emits identical keys to the LAN action `_resetToDefaults` already
  /// parses), so the caller can treat this and the LAN `NuraeyeClient.call('GetImageDefaults')`
  /// result identically.
  Future<CameraResult<Map<String, dynamic>>> getImageDefaults({
    Duration timeout = const Duration(seconds: 15),
    bool retryOnTimeout = true,
  }) async {
    try {
      final output = await _iot.sendCommandWithResponse(
        IotCommandClient.getImageDefaults,
        timeoutSeconds: timeout.inMilliseconds / 1000,
        retryOnTimeout: retryOnTimeout,
      );
      if (output == null) return const CameraTimeout();
      return CameraSuccess(output);
    } catch (e) {
      return CameraFailure(e.toString());
    }
  }
}
