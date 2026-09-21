import 'dart:convert';

import 'package:http/http.dart' as http;

import '../wan_auth.dart';

/// Short-lived, stream-scoped AWS credentials for calling `kinesisvideo:GetMedia` directly —
/// vended by `cloud_backend/kvs_playback_lambda`'s `GET ?streamName=...&mode=media` action
/// (2026-09-17), not usable beyond [expiration].
///
/// **Why this exists, and why it's not just [WanAwsCredentials]**: AWS rejects Cognito Identity
/// Pool-federated credentials for `kinesisvideo:GetDataEndpoint`/`GetMedia` regardless of IAM
/// policy — independently re-confirmed live before this was built (the role's own policy grants
/// `GetDataEndpoint`; a real Cognito-federated session using that exact role still gets
/// `AccessDeniedException` calling it). The Lambda mints these via `sts:AssumeRole` under its
/// own plain (non-federated) execution role instead — no media bytes ever flow through the
/// Lambda itself, unlike a continuous relay.
class KvsMediaViewerCredentials {
  const KvsMediaViewerCredentials({
    required this.accessKeyId,
    required this.secretAccessKey,
    required this.sessionToken,
    required this.expiration,
    required this.region,
    required this.dataEndpoint,
  });

  final String accessKeyId;
  final String secretAccessKey;
  final String sessionToken;
  final DateTime expiration;
  final String region;

  /// The `GetMedia` data-plane endpoint (e.g. `https://s-xxxxxxxx.kinesisvideo.REGION
  /// .amazonaws.com`) — resolved by the Lambda using these same credentials, so the caller
  /// never needs a separate `GetDataEndpoint` round trip.
  final String dataEndpoint;

  /// True once within [margin] of [expiration] (default 60s) — callers should refresh before
  /// this, not wait for an actual `AccessDenied`/expired-token error from AWS.
  bool isExpiringSoon({Duration margin = const Duration(seconds: 60)}) =>
      DateTime.now().toUtc().isAfter(expiration.subtract(margin));

  WanAwsCredentials toWanAwsCredentials() => WanAwsCredentials(
        accessKeyId: accessKeyId,
        secretKey: secretAccessKey,
        sessionToken: sessionToken,
      );
}

/// Fetches [KvsMediaViewerCredentials] from `cloud_backend/kvs_playback_lambda`'s `mode=media`
/// action — the credential-vending counterpart to the old `KvsPlaybackClient`'s HLS URL lookup,
/// which this class's callers replace entirely (see `KvsMediaLiveViewSession`'s own doc for why:
/// AWS rejects an H.265-configured stream for `GetHLSStreamingSessionURL`/
/// `GetDASHStreamingSessionURL` outright, and unifying both codecs onto one WAN playback path is
/// simpler than maintaining two).
class KvsMediaViewerCredentialsClient {
  /// [idTokenProvider]/[client] are overridable for tests — default to [WanAuth.idTokenProvider]
  /// / `http.Client()`, matching every other WAN client in this package.
  KvsMediaViewerCredentialsClient({http.Client? client, String? Function()? idTokenProvider})
    : _client = client ?? http.Client(),
      _idTokenProvider = idTokenProvider ?? WanAuth.idTokenProvider ?? (() => null);

  final http.Client _client;
  final String? Function() _idTokenProvider;

  /// [streamName] is the full per-quality KVS stream name (`"<thingName>-<quality>"`, e.g.
  /// `VZL-CAM-000001-high`) — same naming convention the camera firmware's own
  /// `prvBuildKvsStreamName()` already uses.
  Future<KvsMediaViewerCredentials> getCredentials(String streamName) async {
    final idToken = _idTokenProvider();
    if (idToken == null) {
      throw StateError('getCredentials() called while unauthenticated');
    }
    final uri = Uri.parse(WanAuth.kvsPlaybackLambdaUrl ?? '').replace(
      queryParameters: {'streamName': streamName, 'mode': 'media'},
    );
    final response = await _client.get(uri, headers: {'Authorization': 'Bearer $idToken'});
    final decoded = jsonDecode(response.body) as Map<String, dynamic>;
    if (response.statusCode != 200) {
      throw Exception(
        decoded['error'] as String? ?? 'KVS media-viewer credential vending failed (${response.statusCode})',
      );
    }
    return KvsMediaViewerCredentials(
      accessKeyId: decoded['accessKeyId'] as String,
      secretAccessKey: decoded['secretAccessKey'] as String,
      sessionToken: decoded['sessionToken'] as String,
      expiration: DateTime.parse(decoded['expiration'] as String),
      region: decoded['region'] as String,
      dataEndpoint: decoded['dataEndpoint'] as String,
    );
  }
}
