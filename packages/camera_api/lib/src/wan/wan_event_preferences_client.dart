import 'package:camera_api/camera_api.dart';

/// WAN counterpart to `EventPreferencesClient` (`camera_api`'s LAN NuraEye client) —
/// `GetEventPreferences`/`SetEventPreferences` (`FR-NE-111`, commands `58`/`59`). Same wire
/// vocabulary as LAN (the camera's own alert event strings), same partial-update semantics for
/// [setEventPreferences]. No WAN "supported types" command — see `CapabilitiesClient`'s
/// `supportedEventTypes`, LAN-only.
class WanEventPreferencesClient {
  WanEventPreferencesClient(
    String thingName, {
    IotCommandClient? iotCommandClient,
  }) : _iot = iotCommandClient ?? IotCommandClient(thingName);

  final IotCommandClient _iot;

  Future<CameraResult<Map<String, bool>>> getEventPreferences({
    Duration timeout = const Duration(seconds: 15),
    bool retryOnTimeout = true,
  }) async {
    try {
      final output = await _iot.sendCommandWithResponse(
        IotCommandClient.getEventPreferences,
        timeoutSeconds: timeout.inMilliseconds / 1000,
        retryOnTimeout: retryOnTimeout,
      );
      if (output == null) return const CameraTimeout();
      return CameraSuccess(
        output.map((key, dynamic v) => MapEntry(key, v == true)),
      );
    } catch (e) {
      return CameraFailure(e.toString());
    }
  }

  /// Partial update — only the keys present in [changes] change; every other alert type's
  /// current state is left untouched, same as the LAN client.
  Future<CameraResult<void>> setEventPreferences(
    Map<String, bool> changes, {
    Duration timeout = const Duration(seconds: 15),
    bool retryOnTimeout = true,
  }) async {
    try {
      final output = await _iot.sendCommandWithResponse(
        IotCommandClient.setEventPreferences,
        params: changes,
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
