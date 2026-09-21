import 'package:camera_api/camera_api.dart';

/// WAN counterpart of LAN `RecordingsClient.getRecordings` / `getRecordingDates` (commands
/// 80/81) — what the recording timeline needs to know which clips exist before WAN playback
/// (`WanClipPlaybackClient`) can start one. The camera replies in small pages
/// (MQTT payload limits); [getRecordings] follows them internally.
class WanRecordingsClient {
  WanRecordingsClient(String thingName, {IotCommandClient? iotCommandClient})
    : _iot = iotCommandClient ?? IotCommandClient(thingName);

  final IotCommandClient _iot;

  /// Local calendar dates (midnight-anchored, [tzOffsetMinutes] applied by the camera) that have
  /// at least one clip in `[start, end]` (UTC epoch seconds), newest last.
  Future<CameraResult<List<DateTime>>> getRecordingDates({
    required int start,
    required int end,
    required int tzOffsetMinutes,
  }) async {
    try {
      final output = await _iot.sendCommandWithResponse(
        IotCommandClient.getRecordingDates,
        params: {
          'start': start,
          'end': end,
          'tz_offset_minutes': tzOffsetMinutes,
        },
      );
      if (output == null) return const CameraTimeout();
      final dates = output['dates'];
      if (dates is! List) {
        return CameraFailure(
          'GetRecordingDates response missing dates: $output',
        );
      }
      final result = <DateTime>[];
      for (final e in dates) {
        final raw = e is Map ? e['date'] : null;
        final ymd = raw is String
            ? int.tryParse(raw)
            : (raw is int ? raw : null);
        if (ymd == null) {
          return CameraFailure('GetRecordingDates malformed entry: $e');
        }
        result.add(DateTime(ymd ~/ 10000, (ymd ~/ 100) % 100, ymd % 100));
      }
      return CameraSuccess(result);
    } catch (e) {
      return CameraFailure(e.toString());
    }
  }

  /// Every clip in `[start, end]` (UTC epoch seconds), oldest first. [maxPages] bounds the loop.
  Future<CameraResult<List<RecordingClip>>> getRecordings({
    required int start,
    required int end,
    int maxPages = 30,
  }) async {
    final clips = <RecordingClip>[];
    try {
      for (var page = 0; page < maxPages; page++) {
        final output = await _iot.sendCommandWithResponse(
          IotCommandClient.getRecordings,
          params: {'start': start, 'end': end, 'offset': clips.length},
        );
        if (output == null) return const CameraTimeout();
        final list = output['clips'];
        if (list is! List) {
          return CameraFailure('GetRecordings response missing clips: $output');
        }
        for (final e in list) {
          final id = e is Map ? e['id'] : null;
          final clipEnd = e is Map ? e['end'] : null;
          if (id is! int || clipEnd is! int) {
            return CameraFailure('GetRecordings malformed clip entry: $e');
          }
          clips.add(
            RecordingClip(
              id: id,
              start: id,
              end: clipEnd,
              sizeBytes: 0,
              active: false,
            ),
          );
        }
        if (output['more'] != true || list.isEmpty) return CameraSuccess(clips);
      }
      return CameraSuccess(clips);
    } catch (e) {
      return CameraFailure(e.toString());
    }
  }
}
