// GENERATED CODE — DO NOT HAND-EDIT.
//
// Produced by tools/generate_dart_rest_client.py from design/Camera-REST-API.openapi.yaml.
// Fix the generator and re-run `python3 tools/generate_dart_rest_client.py` to regenerate.

import 'nuraeye_rest_client.dart';
import 'rest_result.dart';

class RestAlertsClient {
  RestAlertsClient(this._client);

  final NuraeyeRestClient _client;

  Future<RestResult<GetBboxOverlayResponse>> getBboxOverlay() {
    return _client.get('/nuraeye/events/bbox-overlay').then((result) => result.map((json) => GetBboxOverlayResponse.fromJson(json)));
  }

  /// Per-event-type enable/disable state
  Future<RestResult<void>> getEventPreferences() {
    return _client.get('/nuraeye/events/preferences');
  }

  /// Selected automatic response actions per detection event type
  Future<RestResult<void>> getEventResponseActions() {
    return _client.get('/nuraeye/events/response-actions');
  }

  Future<RestResult<GetLoiteringDurationResponse>> getLoiteringDuration() {
    return _client.get('/nuraeye/events/loitering-duration').then((result) => result.map((json) => GetLoiteringDurationResponse.fromJson(json)));
  }

  /// Read one detection rule's alert choices (read counterpart to POST /nuraeye/alert-rules)
  Future<RestResult<QueryAlertRuleResponse>> queryAlertRule({required String rule}) {
    final body = <String, dynamic>{
      'rule': rule,
    };
    return _client.post('/nuraeye/alert-rules/query', body).then((result) => result.map((json) => QueryAlertRuleResponse.fromJson(json)));
  }

  Future<RestResult<void>> setAlertRule({required String rule, required bool mobileNotifications, required bool buzzerActivation}) {
    final body = <String, dynamic>{
      'rule': rule,
      'mobile_notifications': mobileNotifications,
      'buzzer_activation': buzzerActivation,
    };
    return _client.post('/nuraeye/alert-rules', body);
  }

  /// Sets the detection bounding-box overlay on/off (FR-CF-151/FR-NE-123)
  Future<RestResult<void>> setBboxOverlay({required bool enabled}) {
    final body = <String, dynamic>{
      'enabled': enabled,
    };
    return _client.post('/nuraeye/events/bbox-overlay', body);
  }

  /// Partial update — only keys present in the body change
  Future<RestResult<void>> setEventPreferences() {
    return _client.post('/nuraeye/events/preferences', const <String, dynamic>{});
  }

  /// Partial update — each key's array fully replaces that event type's action set
  Future<RestResult<void>> setEventResponseActions() {
    return _client.post('/nuraeye/events/response-actions', const <String, dynamic>{});
  }

  /// Sets the loitering-detection dwell duration (FR-CF-150/FR-NE-121)
  Future<RestResult<void>> setLoiteringDuration({required int loiteringDurationSeconds}) {
    final body = <String, dynamic>{
      'loitering_duration_seconds': loiteringDurationSeconds,
    };
    return _client.post('/nuraeye/events/loitering-duration', body);
  }
}

class GetBboxOverlayResponse {
  final bool? enabled;

  const GetBboxOverlayResponse({this.enabled});

  factory GetBboxOverlayResponse.fromJson(Map<String, dynamic> json) => GetBboxOverlayResponse(
        enabled: json['enabled'] as bool?,
      );
}

class GetLoiteringDurationResponse {
  final int? loiteringDurationSeconds;

  const GetLoiteringDurationResponse({this.loiteringDurationSeconds});

  factory GetLoiteringDurationResponse.fromJson(Map<String, dynamic> json) => GetLoiteringDurationResponse(
        loiteringDurationSeconds: json['loitering_duration_seconds'] as int?,
      );
}

class QueryAlertRuleResponse {
  final bool? mobileNotifications;
  final bool? buzzerActivation;

  const QueryAlertRuleResponse({this.mobileNotifications, this.buzzerActivation});

  factory QueryAlertRuleResponse.fromJson(Map<String, dynamic> json) => QueryAlertRuleResponse(
        mobileNotifications: json['mobile_notifications'] as bool?,
        buzzerActivation: json['buzzer_activation'] as bool?,
      );
}

