import 'package:camera_api/camera_api.dart';

/// WAN counterpart to `RecordingModeClient` (`camera_api`'s LAN-only NuraEye client) —
/// `GetRecordingMode`/`SetRecordingMode` (`FR-NE-088`) and `GetSupportedRecordingModes`
/// (`FR-NE-089`). Same `RecordingModeStatus` wire vocabulary as LAN.
class WanRecordingModeClient {
  WanRecordingModeClient(String thingName, {IotCommandClient? iotCommandClient})
    : _iot = iotCommandClient ?? IotCommandClient(thingName);

  final IotCommandClient _iot;

  Future<CameraResult<RecordingModeStatus>> getMode({
    Duration timeout = const Duration(seconds: 15),
    bool retryOnTimeout = true,
  }) async {
    try {
      final output = await _iot.sendCommandWithResponse(
        IotCommandClient.getRecordingMode,
        timeoutSeconds: timeout.inMilliseconds / 1000,
        retryOnTimeout: retryOnTimeout,
      );
      if (output == null) return const CameraTimeout();
      return _parse(output);
    } catch (e) {
      return CameraFailure(e.toString());
    }
  }

  /// See `RecordingModeClient.setMode`'s doc — same camera-side rejection of an unsupported
  /// mode or an invalid schedule.
  Future<CameraResult<void>> setMode(
    RecordingMode mode, {
    List<RecordingScheduleWindow> schedule = const [],
    Duration timeout = const Duration(seconds: 15),
    bool retryOnTimeout = true,
  }) async {
    try {
      final output = await _iot.sendCommandWithResponse(
        IotCommandClient.setRecordingMode,
        params: {
          'mode': mode.wireValue,
          if (mode == RecordingMode.scheduled)
            'schedule': schedule
                .map(
                  (w) => {
                    'day_of_week': w.dayOfWeek,
                    'start_minute': w.startMinute,
                    'end_minute': w.endMinute,
                  },
                )
                .toList(),
        },
        timeoutSeconds: timeout.inMilliseconds / 1000,
        retryOnTimeout: retryOnTimeout,
      );
      if (output == null) return const CameraTimeout();
      return const CameraSuccess(null);
    } catch (e) {
      return CameraFailure(e.toString());
    }
  }

  /// `FR-NE-089`/`FR-MOB-088`: this SKU's recording-mode capability set. Per this app's standing
  /// "Options/bounds queries are LAN-only, with exactly one exception" convention (see
  /// `.claude/rules/mobile-app-screen-conventions.md`), callers should reach for this only as
  /// WAN Set-failure recovery, never as a normal load path — a normal load should already have
  /// this cached from onboarding (`CapabilitiesClient.getCapabilities()`, LAN-only).
  Future<CameraResult<List<RecordingMode>>> getSupportedModes({
    Duration timeout = const Duration(seconds: 15),
    bool retryOnTimeout = true,
  }) async {
    try {
      final output = await _iot.sendCommandWithResponse(
        IotCommandClient.getSupportedRecordingModes,
        timeoutSeconds: timeout.inMilliseconds / 1000,
        retryOnTimeout: retryOnTimeout,
      );
      if (output == null) return const CameraTimeout();
      final raw = output['supported_modes'];
      if (raw is! List) {
        return CameraFailure(
          'GetSupportedRecordingModes response missing supported_modes: $output',
        );
      }
      final modes = raw
          .whereType<String>()
          .map(RecordingMode.fromWireValue)
          .whereType<RecordingMode>()
          .toList();
      return CameraSuccess(modes);
    } catch (e) {
      return CameraFailure(e.toString());
    }
  }

  CameraResult<RecordingModeStatus> _parse(Map<String, dynamic> output) {
    final mode = RecordingMode.fromWireValue(output['mode'] as String?);
    final eventTriggerSourceConfigured = output['event_trigger_source_configured'];
    final rawSchedule = output['schedule'];
    if (mode == null || eventTriggerSourceConfigured is! bool || rawSchedule is! List) {
      return CameraFailure('GetRecordingMode response missing/malformed fields: $output');
    }
    final schedule = <RecordingScheduleWindow>[];
    for (final entry in rawSchedule) {
      if (entry is! Map) {
        return CameraFailure('GetRecordingMode response has a malformed schedule entry: $entry');
      }
      final dayOfWeek = entry['day_of_week'];
      final startMinute = entry['start_minute'];
      final endMinute = entry['end_minute'];
      if (dayOfWeek is! int || startMinute is! int || endMinute is! int) {
        return CameraFailure('GetRecordingMode response has a malformed schedule entry: $entry');
      }
      schedule.add(
        RecordingScheduleWindow(
          dayOfWeek: dayOfWeek,
          startMinute: startMinute,
          endMinute: endMinute,
        ),
      );
    }
    return CameraSuccess(
      RecordingModeStatus(
        mode: mode,
        schedule: schedule,
        eventTriggerSourceConfigured: eventTriggerSourceConfigured,
      ),
    );
  }
}
