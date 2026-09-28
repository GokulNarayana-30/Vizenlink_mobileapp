// GENERATED CODE — DO NOT HAND-EDIT.
//
// Produced by tools/generate_dart_rest_client.py from design/Camera-REST-API.openapi.yaml.
// Fix the generator and re-run `python3 tools/generate_dart_rest_client.py` to regenerate.

import 'nuraeye_rest_client.dart';
import 'rest_result.dart';

class RestNetworkConnectivityClient {
  RestNetworkConnectivityClient(this._client);

  final NuraeyeRestClient _client;

  Future<RestResult<GetCloudParametersResponse>> getCloudParameters() {
    return _client.get('/nuraeye/cloud/parameters').then((result) => result.map((json) => GetCloudParametersResponse.fromJson(json)));
  }

  Future<RestResult<GetTimezonesResponse>> getTimezones() {
    return _client.get('/nuraeye/timezones').then((result) => result.map((json) => GetTimezonesResponse.fromJson(json)));
  }

  Future<RestResult<GetWifiResponse>> getWifi() {
    return _client.get('/nuraeye/wifi').then((result) => result.map((json) => GetWifiResponse.fromJson(json)));
  }

  Future<RestResult<GetWifiSignalResponse>> getWifiSignal() {
    return _client.get('/nuraeye/wifi/signal').then((result) => result.map((json) => GetWifiSignalResponse.fromJson(json)));
  }

  Future<RestResult<void>> setWifi({required String ssid, required String psk, bool verify = true}) {
    final body = <String, dynamic>{
      'ssid': ssid,
      'psk': psk,
      'verify': verify,
    };
    return _client.post('/nuraeye/wifi', body);
  }
}

class GetCloudParametersResponse {
  final String? iotBrokerEndpoint;
  final String? kvsStreamName;

  const GetCloudParametersResponse({this.iotBrokerEndpoint, this.kvsStreamName});

  factory GetCloudParametersResponse.fromJson(Map<String, dynamic> json) => GetCloudParametersResponse(
        iotBrokerEndpoint: json['iot_broker_endpoint'] as String?,
        kvsStreamName: json['kvs_stream_name'] as String?,
      );
}

class TimezoneEntry {
  final String? code;
  final String? name;

  const TimezoneEntry({this.code, this.name});

  factory TimezoneEntry.fromJson(Map<String, dynamic> json) => TimezoneEntry(
        code: json['code'] as String?,
        name: json['name'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'code': code,
        'name': name,
      };
}

class GetTimezonesResponse {
  final List<TimezoneEntry>? timezones;

  const GetTimezonesResponse({this.timezones});

  factory GetTimezonesResponse.fromJson(Map<String, dynamic> json) => GetTimezonesResponse(
        timezones: (json['timezones'] as List<dynamic>?)?.map((e) => TimezoneEntry.fromJson(e as Map<String, dynamic>)).toList(),
      );
}

class GetWifiResponse {
  final String? ssid;
  final String? psk;

  const GetWifiResponse({this.ssid, this.psk});

  factory GetWifiResponse.fromJson(Map<String, dynamic> json) => GetWifiResponse(
        ssid: json['ssid'] as String?,
        psk: json['psk'] as String?,
      );
}

class GetWifiSignalResponse {
  final String? rssi;
  final String? snr;

  const GetWifiSignalResponse({this.rssi, this.snr});

  factory GetWifiSignalResponse.fromJson(Map<String, dynamic> json) => GetWifiSignalResponse(
        rssi: json['rssi'] as String?,
        snr: json['snr'] as String?,
      );
}

