import 'package:camera_api/camera_api.dart';

/// WAN counterpart to `HealthClient` (`camera_api`'s LAN-only NuraEye client) — `GetDeviceHealth`
/// (`FR-HLT-009`, Stage 3, extended 2026-08-26), command `70`. Same `HealthStatus` wire
/// vocabulary as LAN. Read-only, no matching Set command.
class WanHealthClient {
  WanHealthClient(String thingName, {IotCommandClient? iotCommandClient})
    : _iot = iotCommandClient ?? IotCommandClient(thingName);

  final IotCommandClient _iot;

  Future<CameraResult<HealthStatus>> getHealth({
    Duration timeout = const Duration(seconds: 15),
    bool retryOnTimeout = true,
  }) async {
    try {
      final output = await _iot.sendCommandWithResponse(
        IotCommandClient.getDeviceHealth,
        timeoutSeconds: timeout.inMilliseconds / 1000,
        retryOnTimeout: retryOnTimeout,
      );
      if (output == null) return const CameraTimeout();
      final rebootCount = output['reboot_count'];
      final lastRebootUtc = output['last_reboot_utc'];
      final uptimeSeconds = output['uptime_seconds'];
      final clockSyncStateWire = output['clock_sync_state'];
      final uncertainSince = output['uncertain_since'];
      final firmwareVersion = output['firmware_version'];
      if (rebootCount is! int ||
          lastRebootUtc is! int ||
          uptimeSeconds is! int ||
          clockSyncStateWire is! String ||
          uncertainSince is! int ||
          firmwareVersion is! String) {
        return CameraFailure(
          'GetDeviceHealth response missing fields: $output',
        );
      }
      final clockSyncState = clockSyncStateWire == 'uncertain'
          ? ClockSyncState.uncertain
          : ClockSyncState.synced;
      return CameraSuccess(
        HealthStatus(
          rebootCount: rebootCount,
          lastRebootUtc: lastRebootUtc,
          // BUG-048 follow-up: not required, unlike the other fields above -- older firmware
          // simply won't have it, and that's a normal case, not a malformed response.
          rebootReason: output['reboot_reason'] is String ? output['reboot_reason'] as String : '',
          uptimeSeconds: uptimeSeconds,
          clockSyncState: clockSyncState,
          uncertainSince: uncertainSince,
          firmwareVersion: firmwareVersion,
        ),
      );
    } catch (e) {
      return CameraFailure(e.toString());
    }
  }
}
