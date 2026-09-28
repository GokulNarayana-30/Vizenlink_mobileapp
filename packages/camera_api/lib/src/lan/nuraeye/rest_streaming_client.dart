// GENERATED CODE — DO NOT HAND-EDIT.
//
// Produced by tools/generate_dart_rest_client.py from design/Camera-REST-API.openapi.yaml.
// Fix the generator and re-run `python3 tools/generate_dart_rest_client.py` to regenerate.

import 'nuraeye_rest_client.dart';
import 'rest_result.dart';

class RestStreamingClient {
  RestStreamingClient(this._client);

  final NuraeyeRestClient _client;

  Future<RestResult<GetCloudStreamingStatusResponse>> getCloudStreamingStatus() {
    return _client.get('/nuraeye/cloud/streaming').then((result) => result.map((json) => GetCloudStreamingStatusResponse.fromJson(json)));
  }

  /// Resolve the live-view connection URI for a stream profile (transport chosen by the camera)
  Future<RestResult<GetLiveStreamUriResponse>> getLiveStreamUri({required String profileToken}) {
    final body = <String, dynamic>{
      'profile_token': profileToken,
    };
    return _client.post('/nuraeye/live-stream-uri', body).then((result) => result.map((json) => GetLiveStreamUriResponse.fromJson(json)));
  }

  /// Fetch the camera-generated shared key for end-to-end-encrypted WAN preview snapshots
  Future<RestResult<GetPreviewKeyResponse>> getPreviewKey() {
    return _client.get('/nuraeye/preview-key').then((result) => result.map((json) => GetPreviewKeyResponse.fromJson(json)));
  }

  /// Resolve the two-way-talk connection URI (dedicated audio-only RTSPS module)
  Future<RestResult<GetTalkUriResponse>> getTalkUri() {
    return _client.post('/nuraeye/talk-uri', const <String, dynamic>{}).then((result) => result.map((json) => GetTalkUriResponse.fromJson(json)));
  }

  Future<RestResult<void>> stopCloudStreaming() {
    final body = <String, dynamic>{'active': false};
    return _client.post('/nuraeye/cloud/streaming', body);
  }
}

class GetCloudStreamingStatusResponse {
  final String? streamStatus;

  const GetCloudStreamingStatusResponse({this.streamStatus});

  factory GetCloudStreamingStatusResponse.fromJson(Map<String, dynamic> json) => GetCloudStreamingStatusResponse(
        streamStatus: json['stream_status'] as String?,
      );
}

class GetLiveStreamUriResponse {
  final String? transport;
  final int? port;
  final String? path;
  final String? url;

  const GetLiveStreamUriResponse({this.transport, this.port, this.path, this.url});

  factory GetLiveStreamUriResponse.fromJson(Map<String, dynamic> json) => GetLiveStreamUriResponse(
        transport: json['transport'] as String?,
        port: json['port'] as int?,
        path: json['path'] as String?,
        url: json['url'] as String?,
      );
}

class GetPreviewKeyResponse {
  final String? key;

  const GetPreviewKeyResponse({this.key});

  factory GetPreviewKeyResponse.fromJson(Map<String, dynamic> json) => GetPreviewKeyResponse(
        key: json['key'] as String?,
      );
}

class GetTalkUriResponse {
  final String? transport;
  final int? port;
  final String? path;
  final String? url;

  const GetTalkUriResponse({this.transport, this.port, this.path, this.url});

  factory GetTalkUriResponse.fromJson(Map<String, dynamic> json) => GetTalkUriResponse(
        transport: json['transport'] as String?,
        port: json['port'] as int?,
        path: json['path'] as String?,
        url: json['url'] as String?,
      );
}

