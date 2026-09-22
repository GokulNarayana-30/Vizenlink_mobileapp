import 'package:camera_api/camera_api.dart';

/// WAN counterpart to `LocalStorageClient` (`camera_api`'s LAN-only NuraEye client) —
/// `GetLocalStorageStatus`/`SetLocalStorageEnabled` (`FR-NE-087`) have been `Implemented` in
/// firmware since `FR-CF-044`'s original LAN-only build, but no app-side WAN wiring existed at
/// all until `FR-MOB-083`. Same `LocalStorageStatus` wire vocabulary as LAN.
class WanLocalStorageClient {
  WanLocalStorageClient(String thingName, {IotCommandClient? iotCommandClient})
    : _iot = iotCommandClient ?? IotCommandClient(thingName);

  final IotCommandClient _iot;

  Future<CameraResult<LocalStorageStatus>> getStatus({
    Duration timeout = const Duration(seconds: 15),
    bool retryOnTimeout = true,
  }) async {
    try {
      final output = await _iot.sendCommandWithResponse(
        IotCommandClient.getLocalStorageStatus,
        timeoutSeconds: timeout.inMilliseconds / 1000,
        retryOnTimeout: retryOnTimeout,
      );
      if (output == null) return const CameraTimeout();
      final enabled = output['enabled'];
      final cardPresent = output['card_present'];
      final capacityBytes = output['capacity_bytes'];
      final freeBytes = output['free_bytes'];
      if (enabled is! bool ||
          cardPresent is! bool ||
          capacityBytes is! int ||
          freeBytes is! int) {
        return CameraFailure(
          'GetLocalStorageStatus response missing fields: $output',
        );
      }
      return CameraSuccess(
        LocalStorageStatus(
          enabled: enabled,
          cardPresent: cardPresent,
          capacityBytes: capacityBytes,
          freeBytes: freeBytes,
        ),
      );
    } catch (e) {
      return CameraFailure(e.toString());
    }
  }

  /// See `LocalStorageClient.setEnabled`'s doc — same camera-side rejection of `enabled: true`
  /// with no card present.
  Future<CameraResult<void>> setEnabled(
    bool enabled, {
    Duration timeout = const Duration(seconds: 15),
    bool retryOnTimeout = true,
  }) async {
    try {
      final output = await _iot.sendCommandWithResponse(
        IotCommandClient.setLocalStorageEnabled,
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
