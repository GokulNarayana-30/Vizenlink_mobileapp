import '../../camera_result.dart';
import '../../recording_mode_types.dart';
import 'nuraeye_client.dart';

/// `GetRecordingMode`/`SetRecordingMode` (`FR-CF-046`, `FR-NE-088`, `FR-MOB-084`) — LAN
/// transport. See `wan/wan_recording_mode_client.dart`'s `WanRecordingModeClient` for the WAN
/// counterpart (same `RecordingModeStatus` wire vocabulary). Which modes this SKU supports at
/// all is not this client's concern — see `CapabilitiesClient.getCapabilities()`'s
/// `supportedRecordingModes` (`FR-CF-048`/`FR-NE-089`/`FR-MOB-088`).
class RecordingModeClient {
  RecordingModeClient(this._nuraeye);

  final NuraeyeClient _nuraeye;

  Future<CameraResult<RecordingModeStatus>> getMode({
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final result = await _nuraeye.call('GetRecordingMode', timeout: timeout);
    return switch (result) {
      CameraSuccess(:final value) => _parse(value),
      CameraFailure(:final reason) => CameraFailure<RecordingModeStatus>(reason),
      CameraTimeout() => const CameraTimeout<RecordingModeStatus>(),
    };
  }

  /// [schedule] is required (and sent) only when [mode] is [RecordingMode.scheduled] — ignored
  /// by the camera otherwise. The camera rejects a [mode] not in this SKU's
  /// `supportedRecordingModes`, or an invalid schedule, with a `500` — callers should pre-check
  /// against `CameraCapabilities.supportedRecordingModes` before calling, per
  /// `SETTINGS_API_GUIDE.md`'s "Recording Mode" entry, rather than relying on the rejection
  /// alone.
  Future<CameraResult<void>> setMode(
    RecordingMode mode, {
    List<RecordingScheduleWindow> schedule = const [],
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final result = await _nuraeye.call(
      'SetRecordingMode',
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
      timeout: timeout,
    );
    return switch (result) {
      CameraSuccess() => const CameraSuccess<void>(null),
      CameraFailure(:final reason) => CameraFailure<void>(reason),
      CameraTimeout() => const CameraTimeout<void>(),
    };
  }

  CameraResult<RecordingModeStatus> _parse(Map<String, dynamic> value) {
    final mode = RecordingMode.fromWireValue(value['mode'] as String?);
    final eventTriggerSourceConfigured = value['event_trigger_source_configured'];
    final rawSchedule = value['schedule'];
    if (mode == null || eventTriggerSourceConfigured is! bool || rawSchedule is! List) {
      return CameraFailure('GetRecordingMode response missing/malformed fields: $value');
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
