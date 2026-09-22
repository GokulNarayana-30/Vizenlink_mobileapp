import 'package:camera_api/camera_api.dart';

/// WAN counterpart to `DeterrenceClient` (`camera_api`'s LAN NuraEye client) —
/// `ActivateDeterrence`/`DeactivateDeterrence`/`GetDeterrenceStatus` (`FR-NE-082`/`083`,
/// commands `20`/`21`/`22`) plus `GetDeterrenceDurations`/`SetDeterrenceDurations` (`FR-NE-113`,
/// commands `62`/`63`). Same wire vocabulary as LAN, same "no duration parameter on activate —
/// the camera applies its own persisted duration" behavior (`FEAT-236`).
class WanDeterrenceClient {
  WanDeterrenceClient(String thingName, {IotCommandClient? iotCommandClient})
    : _iot = iotCommandClient ?? IotCommandClient(thingName);

  final IotCommandClient _iot;

  Future<CameraResult<DeterrenceStatus>> getDeterrenceStatus({
    Duration timeout = const Duration(seconds: 15),
    bool retryOnTimeout = true,
  }) async {
    try {
      final output = await _iot.sendCommandWithResponse(
        IotCommandClient.getDeterrenceStatus,
        timeoutSeconds: timeout.inMilliseconds / 1000,
        retryOnTimeout: retryOnTimeout,
      );
      if (output == null) return const CameraTimeout();
      return CameraSuccess(DeterrenceStatus.fromJson(output));
    } catch (e) {
      return CameraFailure(e.toString());
    }
  }

  Future<CameraResult<void>> activateDeterrence(
    String action, {
    Duration timeout = const Duration(seconds: 15),
    bool retryOnTimeout = true,
  }) async {
    try {
      final output = await _iot.sendCommandWithResponse(
        IotCommandClient.activateDeterrence,
        params: {'action': action},
        timeoutSeconds: timeout.inMilliseconds / 1000,
        retryOnTimeout: retryOnTimeout,
      );
      if (output == null) return const CameraTimeout();
      return const CameraSuccess(null);
    } catch (e) {
      return CameraFailure(e.toString());
    }
  }

  Future<CameraResult<void>> deactivateDeterrence(
    String action, {
    Duration timeout = const Duration(seconds: 15),
    bool retryOnTimeout = true,
  }) async {
    try {
      final output = await _iot.sendCommandWithResponse(
        IotCommandClient.deactivateDeterrence,
        params: {'action': action},
        timeoutSeconds: timeout.inMilliseconds / 1000,
        retryOnTimeout: retryOnTimeout,
      );
      if (output == null) return const CameraTimeout();
      return const CameraSuccess(null);
    } catch (e) {
      return CameraFailure(e.toString());
    }
  }

  Future<CameraResult<Map<String, int>>> getDeterrenceDurations({
    Duration timeout = const Duration(seconds: 15),
    bool retryOnTimeout = true,
  }) async {
    try {
      final output = await _iot.sendCommandWithResponse(
        IotCommandClient.getDeterrenceDurations,
        timeoutSeconds: timeout.inMilliseconds / 1000,
        retryOnTimeout: retryOnTimeout,
      );
      if (output == null) return const CameraTimeout();
      return CameraSuccess<Map<String, int>>(
        output.map((key, dynamic v) => MapEntry(key, (v as num).toInt())),
      );
    } catch (e) {
      return CameraFailure(e.toString());
    }
  }

  /// Partial update — same semantics as the LAN client.
  Future<CameraResult<void>> setDeterrenceDurations(
    Map<String, int> changes, {
    Duration timeout = const Duration(seconds: 15),
    bool retryOnTimeout = true,
  }) async {
    try {
      final output = await _iot.sendCommandWithResponse(
        IotCommandClient.setDeterrenceDurations,
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

  /// Camera-reported valid range for each duration/count key — same semantics as the LAN client.
  Future<CameraResult<DeterrenceDurationOptions>> getDeterrenceDurationOptions({
    Duration timeout = const Duration(seconds: 15),
    bool retryOnTimeout = true,
  }) async {
    try {
      final output = await _iot.sendCommandWithResponse(
        IotCommandClient.getDeterrenceDurationOptions,
        timeoutSeconds: timeout.inMilliseconds / 1000,
        retryOnTimeout: retryOnTimeout,
      );
      if (output == null) return const CameraTimeout();
      return CameraSuccess(DeterrenceDurationOptions.fromJson(output));
    } catch (e) {
      return CameraFailure(e.toString());
    }
  }
}
