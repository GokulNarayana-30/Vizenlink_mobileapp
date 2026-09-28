import '../../camera_result.dart';
import '../../health_types.dart';
import 'nuraeye_client.dart';

/// `GetDeviceHealth` (`FR-HLT-009`, Stage 3, extended 2026-08-26) — LAN transport. Read-only, no
/// matching Set — every field is camera-derived, not user-configurable. See
/// `wan/wan_health_client.dart`'s `WanHealthClient` for the WAN counterpart (same `HealthStatus`
/// wire vocabulary).
class HealthClient {
  HealthClient(this._nuraeye);

  final NuraeyeClient _nuraeye;

  Future<CameraResult<HealthStatus>> getHealth({
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final result = await _nuraeye.call('GetDeviceHealth', timeout: timeout);
    return switch (result) {
      CameraSuccess(:final value) => _parse(value),
      CameraFailure(:final reason) => CameraFailure<HealthStatus>(reason),
      CameraTimeout() => const CameraTimeout<HealthStatus>(),
    };
  }

  CameraResult<HealthStatus> _parse(Map<String, dynamic> value) {
    final rebootCount = value['reboot_count'];
    final lastRebootUtc = value['last_reboot_utc'];
    final uptimeSeconds = value['uptime_seconds'];
    final clockSyncStateWire = value['clock_sync_state'];
    final uncertainSince = value['uncertain_since'];
    final firmwareVersion = value['firmware_version'];
    if (rebootCount is! int ||
        lastRebootUtc is! int ||
        uptimeSeconds is! int ||
        clockSyncStateWire is! String ||
        uncertainSince is! int ||
        firmwareVersion is! String) {
      return CameraFailure('GetDeviceHealth response missing fields: $value');
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
        rebootReason: value['reboot_reason'] is String ? value['reboot_reason'] as String : '',
        uptimeSeconds: uptimeSeconds,
        clockSyncState: clockSyncState,
        uncertainSince: uncertainSince,
        firmwareVersion: firmwareVersion,
      ),
    );
  }
}
