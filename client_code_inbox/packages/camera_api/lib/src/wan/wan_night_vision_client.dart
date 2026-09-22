import 'package:camera_api/camera_api.dart';

/// WAN counterpart to `camera_api`'s `NightVisionClient` — `FR-MOB-068`. Same
/// `GetNightVisionType`/`SetNightVisionType` NuraEye actions as LAN (`FR-NE-037`/`038`), routed
/// through [IotCommandClient]'s generic `sendCommandWithResponse` instead of the direct-HTTP
/// `NuraeyeClient`. Response shape is identical on both transports (`nuraeye.c` builds the same
/// `type`/`color_capable`/`smart_capable` fields for both the LAN JSON reply and the WAN MQTT
/// reply) so the parsing here mirrors `NightVisionClient.getNightVisionType` exactly.
class WanNightVisionClient implements NightVisionSource {
  /// [iotCommandClient] is overridable for tests — defaults to a real [IotCommandClient] for
  /// [thingName].
  WanNightVisionClient(String thingName, {IotCommandClient? iotCommandClient})
    : _iot = iotCommandClient ?? IotCommandClient(thingName);

  final IotCommandClient _iot;

  @override
  Future<CameraResult<NightVisionStatus>> getNightVisionType({
    Duration timeout = const Duration(seconds: 15),
    bool retryOnTimeout = true,
  }) async {
    try {
      final output = await _iot.sendCommandWithResponse(
        IotCommandClient.getNightVisionType,
        timeoutSeconds: timeout.inMilliseconds / 1000,
        retryOnTimeout: retryOnTimeout,
      );
      if (output == null) return const CameraTimeout();

      final typeStr = output['type'];
      final colorCapable = output['color_capable'];
      final smartCapable = output['smart_capable'];
      if (typeStr is! String ||
          colorCapable is! bool ||
          smartCapable is! bool) {
        return CameraFailure(
          'GetNightVisionType response missing fields: $output',
        );
      }
      final type =
          NightVisionTypeWire.fromWire(typeStr) ?? NightVisionType.grey;
      final subStateStr = output['sub_state'];
      final subState = type == NightVisionType.smart && subStateStr is String
          ? NightVisionTypeWire.fromWire(subStateStr)
          : null;
      return CameraSuccess(
        NightVisionStatus(
          type: type,
          colorCapable: colorCapable,
          smartCapable: smartCapable,
          subState: subState,
        ),
      );
    } catch (e) {
      return CameraFailure(e.toString());
    }
  }

  @override
  Future<CameraResult<void>> setNightVisionType(
    NightVisionType type, {
    Duration timeout = const Duration(seconds: 15),
    bool retryOnTimeout = true,
  }) async {
    try {
      final output = await _iot.sendCommandWithResponse(
        IotCommandClient.setNightVisionType,
        params: {'type': type.wireValue},
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
