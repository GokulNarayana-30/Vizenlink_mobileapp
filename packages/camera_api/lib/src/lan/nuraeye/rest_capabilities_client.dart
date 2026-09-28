// GENERATED CODE — DO NOT HAND-EDIT.
//
// Produced by tools/generate_dart_rest_client.py from design/Camera-REST-API.openapi.yaml.
// Fix the generator and re-run `python3 tools/generate_dart_rest_client.py` to regenerate.

import 'nuraeye_rest_client.dart';
import 'rest_result.dart';

class RestCapabilitiesClient {
  RestCapabilitiesClient(this._client);

  final NuraeyeRestClient _client;

  /// Every "is X supported on this build/unit" boolean, in one response
  Future<RestResult<GetCapabilitiesResponse>> getCapabilities() {
    return _client.get('/nuraeye/capabilities').then((result) => result.map((json) => GetCapabilitiesResponse.fromJson(json)));
  }
}

class GetCapabilitiesResponse {
  final bool? wanCommandCapable;
  final bool? wanLiveViewCapable;
  final bool? sirenCapable;
  final bool? spotlightCapable;
  final bool? warningCapable;
  final bool? localStorageCapable;
  final int? recordingClipDurationMinSeconds;
  final int? recordingClipDurationMaxSeconds;
  final List<String>? supportedRecordingModes;
  final int? maxRecordingScheduleWindows;
  final int? loiteringDurationMinSeconds;
  final int? loiteringDurationMaxSeconds;
  final bool? bboxOverlayCapable;
  final bool? nightVisionColorCapable;
  final bool? nightVisionSmartCapable;
  final List<String>? supportedEventTypes;
  final dynamic supportedEventDeterrenceOptions;

  const GetCapabilitiesResponse({this.wanCommandCapable, this.wanLiveViewCapable, this.sirenCapable, this.spotlightCapable, this.warningCapable, this.localStorageCapable, this.recordingClipDurationMinSeconds, this.recordingClipDurationMaxSeconds, this.supportedRecordingModes, this.maxRecordingScheduleWindows, this.loiteringDurationMinSeconds, this.loiteringDurationMaxSeconds, this.bboxOverlayCapable, this.nightVisionColorCapable, this.nightVisionSmartCapable, this.supportedEventTypes, this.supportedEventDeterrenceOptions});

  factory GetCapabilitiesResponse.fromJson(Map<String, dynamic> json) => GetCapabilitiesResponse(
        wanCommandCapable: json['wan_command_capable'] as bool?,
        wanLiveViewCapable: json['wan_live_view_capable'] as bool?,
        sirenCapable: json['siren_capable'] as bool?,
        spotlightCapable: json['spotlight_capable'] as bool?,
        warningCapable: json['warning_capable'] as bool?,
        localStorageCapable: json['local_storage_capable'] as bool?,
        recordingClipDurationMinSeconds: json['recording_clip_duration_min_seconds'] as int?,
        recordingClipDurationMaxSeconds: json['recording_clip_duration_max_seconds'] as int?,
        supportedRecordingModes: json['supported_recording_modes'] as List<String>?,
        maxRecordingScheduleWindows: json['max_recording_schedule_windows'] as int?,
        loiteringDurationMinSeconds: json['loitering_duration_min_seconds'] as int?,
        loiteringDurationMaxSeconds: json['loitering_duration_max_seconds'] as int?,
        bboxOverlayCapable: json['bbox_overlay_capable'] as bool?,
        nightVisionColorCapable: json['night_vision_color_capable'] as bool?,
        nightVisionSmartCapable: json['night_vision_smart_capable'] as bool?,
        supportedEventTypes: json['supported_event_types'] as List<String>?,
        supportedEventDeterrenceOptions: json['supported_event_deterrence_options'] as dynamic,
      );
}

