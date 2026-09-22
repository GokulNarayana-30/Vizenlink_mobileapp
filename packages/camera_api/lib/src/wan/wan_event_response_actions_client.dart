import 'package:camera_api/camera_api.dart';

/// WAN counterpart to `EventResponseActionsClient` (`camera_api`'s LAN NuraEye client) —
/// `GetEventResponseActions`/`SetEventResponseActions` (`FR-NE-112`, commands `60`/`61`). Same
/// wire vocabulary and partial-update semantics (each key's array fully replaces that event
/// type's action set) as LAN. No WAN "supported deterrence options" command — see
/// `CapabilitiesClient`'s `supportedEventDeterrenceOptions`, LAN-only.
class WanEventResponseActionsClient {
  WanEventResponseActionsClient(
    String thingName, {
    IotCommandClient? iotCommandClient,
  }) : _iot = iotCommandClient ?? IotCommandClient(thingName);

  final IotCommandClient _iot;

  Future<CameraResult<Map<String, List<String>>>> getEventResponseActions({
    Duration timeout = const Duration(seconds: 15),
    bool retryOnTimeout = true,
  }) async {
    try {
      final output = await _iot.sendCommandWithResponse(
        IotCommandClient.getEventResponseActions,
        timeoutSeconds: timeout.inMilliseconds / 1000,
        retryOnTimeout: retryOnTimeout,
      );
      if (output == null) return const CameraTimeout();
      return CameraSuccess(
        output.map(
          (key, dynamic v) => MapEntry(
            key,
            v is List ? v.whereType<String>().toList() : const <String>[],
          ),
        ),
      );
    } catch (e) {
      return CameraFailure(e.toString());
    }
  }

  /// Partial update — only the event types present in [changes] change; each key's array fully
  /// replaces that event type's selected action set, same as the LAN client.
  Future<CameraResult<void>> setEventResponseActions(
    Map<String, List<String>> changes, {
    Duration timeout = const Duration(seconds: 15),
    bool retryOnTimeout = true,
  }) async {
    try {
      final output = await _iot.sendCommandWithResponse(
        IotCommandClient.setEventResponseActions,
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
