// GENERATED CODE — DO NOT HAND-EDIT.
//
// Produced by tools/generate_dart_rest_client.py from design/Camera-REST-API.openapi.yaml.
// Fix the generator and re-run `python3 tools/generate_dart_rest_client.py` to regenerate.

import 'nuraeye_rest_client.dart';
import 'rest_result.dart';

class RestHealthClient {
  RestHealthClient(this._client);

  final NuraeyeRestClient _client;

  /// Reboot/uptime/clock-sync vitals and firmware version
  Future<RestResult<GetDeviceHealthResponse>> getDeviceHealth() {
    return _client.get('/nuraeye/health').then((result) => result.map((json) => GetDeviceHealthResponse.fromJson(json)));
  }
}

class GetDeviceHealthResponse {
  final int? rebootCount;
  final int? lastRebootUtc;
  final String? rebootReason;
  final int? uptimeSeconds;
  final String? clockSyncState;
  final int? uncertainSince;
  final String? firmwareVersion;

  const GetDeviceHealthResponse({this.rebootCount, this.lastRebootUtc, this.rebootReason, this.uptimeSeconds, this.clockSyncState, this.uncertainSince, this.firmwareVersion});

  factory GetDeviceHealthResponse.fromJson(Map<String, dynamic> json) => GetDeviceHealthResponse(
        rebootCount: json['reboot_count'] as int?,
        lastRebootUtc: json['last_reboot_utc'] as int?,
        rebootReason: json['reboot_reason'] as String?,
        uptimeSeconds: json['uptime_seconds'] as int?,
        clockSyncState: json['clock_sync_state'] as String?,
        uncertainSince: json['uncertain_since'] as int?,
        firmwareVersion: json['firmware_version'] as String?,
      );
}

