import 'package:http/http.dart' as http;

import '../../camera_connection.dart';
import '../../camera_result.dart';
import '../insecure_camera_http_client.dart';
import '../wsse_digest.dart';
import 'nuraeye_rest_client.dart' as rest;
import 'rest_identity_discovery_client.dart' as rest;
import 'rest_result.dart' as rest;

/// LAN client for the camera's `/nuraeye/*` REST API (`FR-NE-104`/`FR-NE-105`), superseding the
/// legacy single-endpoint `POST /nuraeye` JSON-RPC dispatch this class used to speak directly —
/// migrated 2026-08-10, see `kb/raw/2026-08-10-code-mobile-app-rest-migration.md`. Deliberately
/// keeps the old `call(action, params)`/`areYouNuraeyeDevice()` surface unchanged so every one
/// of this package's ~15 call sites (settings/audio/night-vision/mirror-flip/privacy-mode
/// clients, `LiveViewController`, `OnvifDeviceClient`, plus a few app-layer screens) needed zero
/// changes — only the wire protocol underneath did. [call]'s `action` string is translated to
/// the matching REST resource internally; see [_dispatch]. Field-name translations are kept to
/// the two spots where the REST shape genuinely diverges from the legacy one: `GetMicGain`
/// (legacy `gain` vs. REST's consolidated `audio/settings`' `mic_gain`) and `GetNightVisionType`
/// (legacy bundled `color_capable`/`smart_capable` in-line; REST moved them into
/// `GetCapabilities`, so this merges the two responses back into the legacy shape).
/// A cached bearer session: the token plus when we expect it to stop being valid.
/// [validUntil] starts at login time + [expiresInSec] (`FR-NE-105`'s idle timeout, 1800s) and is
/// pushed forward by [touched] on every successful authenticated call — the firmware's own
/// timeout is idle-based (resets on activity), so an actively-used session should never be
/// treated as stale just because it was logged into a while ago.
class _Session {
  const _Session({required this.token, required this.expiresInSec, required this.validUntil});

  final String token;
  final int expiresInSec;
  final DateTime validUntil;

  bool get isExpiredOrExpiringSoon =>
      DateTime.now().isAfter(validUntil.subtract(NuraeyeClient._expiryLeeway));

  _Session touched() =>
      _Session(token: token, expiresInSec: expiresInSec, validUntil: DateTime.now().add(Duration(seconds: expiresInSec)));
}

class NuraeyeClient {
  NuraeyeClient(this.connection, {http.Client? httpClient})
      : _http = httpClient ?? createCameraHttpClient();

  final CameraConnection connection;
  final http.Client _http;

  /// `FR-NE-105` documents a 30-minute (1800s) idle timeout as the default; used only if a
  /// login response omits `expires_in_sec` (the OpenAPI schema marks it optional), which
  /// shouldn't happen in practice but keeps [_Session.touched] well-defined either way.
  static const int _defaultExpiresInSec = 1800;

  /// Safety margin subtracted from a session's reported expiry before treating it as still
  /// valid — covers the round-trip time between this client's expiry check and the request
  /// actually landing on the camera, so a session doesn't expire mid-flight.
  static const Duration _expiryLeeway = Duration(seconds: 15);

  /// Bearer sessions, cached per camera host for the life of the app process — checked for
  /// expiry (see [_Session.isExpiredOrExpiringSoon]) before every use, not just reacted to
  /// reactively on a `401` (see [_authed]'s retry). The firmware holds only
  /// `NURAEYE_SESSION_MAX_CLIENTS = 6` concurrent sessions (LRU-evicted on overflow,
  /// `FR-NE-105`) — logging in fresh on every `NuraeyeClient(connection)` construction (common:
  /// most call sites build a short-lived instance per call) would churn through that table for
  /// no reason, so every instance for the same host shares one cached session instead.
  static final Map<String, _Session> _sessionByHost = {};

  /// Serializes login per host — [call]-ing code routinely fires several requests concurrently
  /// for the same camera (e.g. the live-view screen's own `GetVideoMode` alongside
  /// `LiveViewController`'s `GetLiveStreamUri`, or `camera_settings_cache.dart`'s
  /// `prefetchAndCache` firing ~9 clients at once), each built as a fresh, short-lived
  /// `NuraeyeClient`. Without
  /// this, every one of them sees an empty [_tokenCacheByHost] at the same instant and
  /// independently calls `POST /nuraeye/session/login` — confirmed on real hardware
  /// 2026-08-10 (`[W][NE:prvFindSlotForNewSession] Session table full, evicting...` immediately
  /// followed by a `401` on the very next request): with only
  /// `NURAEYE_SESSION_MAX_CLIENTS = 6` slots, two-plus concurrent logins for the *same* camera
  /// are enough to evict each other's just-created session before the request that needed it
  /// goes out. Concurrent callers now await one shared in-flight login [Future] instead.
  static final Map<String, Future<CameraResult<String>>> _loginInFlightByHost = {};

  static void debugClearCaches() {
    _sessionByHost.clear();
    _loginInFlightByHost.clear();
  }

  /// Drops any cached session for [host] — call this whenever that host's credentials could
  /// have changed underneath the cache: after a successful password change, and when a camera
  /// is removed from the app (so a stale session for that IP can't be silently reused to
  /// validate a different camera re-added at the same address later, per BUG report 2026-08-11
  /// — an old cached session masked a wrong re-entered password at add-camera time, since
  /// [_tokenFor] never re-checks credentials once a still-valid token is cached). Capabilities
  /// are left alone — they describe the firmware build, not the credentials, and stay correct
  /// across a credential change for the same physical camera.
  static void clearSessionFor(String host) {
    _sessionByHost.remove(host);
    _loginInFlightByHost.remove(host);
  }

  rest.NuraeyeRestClient _newRestClient(Duration timeout) => rest.NuraeyeRestClient(
        host: connection.host,
        port: connection.httpsPort,
        timeout: timeout,
        httpClient: _http,
      );

  /// Calls one legacy NuraEye `action` with optional `params`, routed to its REST equivalent.
  /// Returns the parsed `output` map on success (translated to match the legacy field names
  /// callers already expect), or a [CameraFailure]/[CameraTimeout].
  Future<CameraResult<Map<String, dynamic>>> call(
    String action, {
    Map<String, dynamic>? params,
    Duration timeout = const Duration(seconds: 10),
  }) => _dispatch(action, params ?? const <String, dynamic>{}, timeout);

  Future<CameraResult<Map<String, dynamic>>> _dispatch(
    String action,
    Map<String, dynamic> p,
    Duration timeout,
  ) {
    switch (action) {
      case 'GetWiFiInfo':
        return _get('/nuraeye/wifi', timeout);
      case 'SetupWiFi':
        return _post('/nuraeye/wifi', {
          'ssid': p['ssid'],
          'psk': p['psk'],
          if (p.containsKey('verify')) 'verify': p['verify'],
        }, timeout);
      case 'GetWiFiSignalStrength':
        return _get('/nuraeye/wifi/signal', timeout);
      case 'GetSupportedTimezones':
        return _get('/nuraeye/timezones', timeout);
      case 'GetCloudStreamingStatus':
        return _get('/nuraeye/cloud/streaming', timeout);
      case 'StopCloudStreaming':
        return _post('/nuraeye/cloud/streaming', const {'active': false}, timeout);
      case 'GetPrivacyMode':
        return _get('/nuraeye/privacy-mode', timeout);
      case 'SetPrivacyMode':
        return _post('/nuraeye/privacy-mode', {'mode': p['mode']}, timeout);
      case 'GetMicGain':
        return _getMicGain(timeout);
      case 'SetMicGain':
        return _post('/nuraeye/audio/settings', {'mic_gain': p['gain']}, timeout);
      case 'GetAudioRecording':
        return _get('/nuraeye/audio/recording', timeout);
      case 'SetAudioRecording':
        return _post('/nuraeye/audio/recording', {'enabled': p['enabled']}, timeout);
      case 'PlayTestSound':
        return _post('/nuraeye/audio/test-sound', const {'active': true}, timeout);
      case 'StopTestSound':
        return _post('/nuraeye/audio/test-sound', const {'active': false}, timeout);
      case 'GetTestSoundStatus':
        return _get('/nuraeye/audio/test-sound', timeout);
      case 'GetCapabilities':
        return _get('/nuraeye/capabilities', timeout);
      case 'GetLocalStorage':
        return _get('/nuraeye/local-storage', timeout);
      case 'SetLocalStorage':
        return _post('/nuraeye/local-storage', {'enabled': p['enabled']}, timeout);
      case 'GetRecordingMode':
        return _get('/nuraeye/recordings/mode', timeout);
      case 'SetRecordingMode':
        return _post('/nuraeye/recordings/mode', {
          'mode': p['mode'],
          if (p['schedule'] != null) 'schedule': p['schedule'],
        }, timeout);
      case 'GetDeviceHealth':
        return _get('/nuraeye/health', timeout);
      case 'GetRecordings':
        return _getRecordings(p, timeout);
      case 'GetRecordingClipDuration':
        return _get('/nuraeye/recordings/clip-duration', timeout);
      case 'SetRecordingClipDuration':
        return _post('/nuraeye/recordings/clip-duration', {'clip_duration_seconds': p['clipDurationSeconds']}, timeout);
      case 'DeleteRecordings':
        return _post('/nuraeye/recordings/delete', {
          if (p['ids'] != null) 'ids': p['ids'],
          if (p['deleteAll'] != null) 'delete_all': p['deleteAll'],
        }, timeout);
      case 'GetNightVisionType':
        return _getNightVisionType(timeout);
      case 'SetNightVisionType':
        return _post('/nuraeye/video/night-vision-type', {'type': p['type']}, timeout);
      case 'GetMirrorFlip':
        return _get('/nuraeye/video/mirror-flip', timeout);
      case 'SetMirrorFlip':
        return _post('/nuraeye/video/mirror-flip', {'mode': p['mode']}, timeout);
      case 'GetAntiFlickerMode':
        return _get('/nuraeye/video/anti-flicker', timeout);
      case 'SetAntiFlickerMode':
        return _post('/nuraeye/video/anti-flicker', {'mode': p['mode']}, timeout);
      case 'GetEventPreferences':
        return _get('/nuraeye/events/preferences', timeout);
      case 'SetEventPreferences':
        // Partial update — p is the caller's {event_string: bool, ...} map, passed straight
        // through as the POST body (unlike every other Set* case above, there's no fixed field
        // name to project it onto; the keys themselves are the camera's own alert type strings).
        return _post('/nuraeye/events/preferences', p, timeout);
      case 'GetEventResponseActions':
        return _get('/nuraeye/events/response-actions', timeout);
      case 'SetEventResponseActions':
        // Partial update — p is the caller's {event_string: [action, ...], ...} map, passed
        // straight through as the POST body, same shape convention as SetEventPreferences.
        return _post('/nuraeye/events/response-actions', p, timeout);
      case 'GetLiveStreamUri':
        // Picks the live-view transport (webrtc/rtsp) server-side. The old pre-2026-09-07
        // GetWebRtcUri/webrtc-uri fallback path (for cameras not yet upgraded to this endpoint)
        // was removed 2026-09-11 -- all cameras are expected upgraded.
        return _post('/nuraeye/live-stream-uri', {'profile_token': p['profile_token']}, timeout);
      case 'GetTalkUri':
        // Two-way-talk discovery -- POST /nuraeye/talk-uri (body ignored, one fixed audio-only
        // instance, no profile_token). Resolves the dedicated RTSPS talk module's connection
        // info (transport always "rtsps", port 560, rtsps://<ip>:560/talk). See TalkUriClient.
        return _post('/nuraeye/talk-uri', const {}, timeout);
      case 'GetImageDefaults':
        return _get('/nuraeye/video/image-defaults', timeout);
      case 'GetVideoMode':
        return _get('/nuraeye/video/mode', timeout);
      case 'GetPreviewKey':
        // FR-CF-141/FR-SECL-017/FR-NE-108: fetches the camera-generated shared key used to
        // encrypt WAN preview snapshots. LAN-only, called over the already-authenticated
        // pairing channel — redesigned 2026-08-21 from a Set (app pushes its own key) to this
        // Get (camera owns and hands out the key), so any number of apps can decrypt, not just
        // the last one to register.
        return _get('/nuraeye/preview-key', timeout);
      case 'GetDeterrenceStatus':
        return _get('/nuraeye/deterrence', timeout);
      case 'ActivateDeterrence':
        // FEAT-236: no duration_seconds -- the camera applies its own persisted, per-action
        // duration (GetDeterrenceDurations/SetDeterrenceDurations below) instead.
        return _post('/nuraeye/deterrence', {'action': p['action'], 'active': true}, timeout);
      case 'DeactivateDeterrence':
        return _post('/nuraeye/deterrence', {'action': p['action'], 'active': false}, timeout);
      case 'GetDeterrenceDurations':
        return _get('/nuraeye/deterrence/durations', timeout);
      case 'GetDeterrenceDurationOptions':
        // FEAT-236, 2026-08-15: camera-reported min/max range per key — never hardcode this
        // range client-side (real-hardware finding: an earlier version did, and let the UI set
        // a degenerate 0-second duration the camera hadn't actually validated).
        return _get('/nuraeye/deterrence/durations/options', timeout);
      case 'SetDeterrenceDurations':
        // Partial update -- p is the caller's {siren_seconds/spotlight_seconds/warning_seconds:
        // int, ...} map, passed straight through, same shape convention as SetEventPreferences.
        return _post('/nuraeye/deterrence/durations', p, timeout);
      case 'GetLoiteringDuration':
        return _get('/nuraeye/events/loitering-duration', timeout);
      case 'SetLoiteringDuration':
        return _post('/nuraeye/events/loitering-duration',
            {'loitering_duration_seconds': p['loitering_duration_seconds']}, timeout);
      case 'GetBboxOverlayEnabled':
        return _get('/nuraeye/events/bbox-overlay', timeout);
      case 'SetBboxOverlayEnabled':
        return _post('/nuraeye/events/bbox-overlay', {'enabled': p['enabled']}, timeout);
      default:
        return Future.value(CameraFailure('Unknown NuraEye REST action: $action'));
    }
  }

  Future<CameraResult<Map<String, dynamic>>> _getMicGain(Duration timeout) async {
    final result = await _get('/nuraeye/audio/settings', timeout);
    return switch (result) {
      CameraSuccess(:final value) => () {
          final gain = value['mic_gain'];
          if (gain == null) return CameraSuccess<Map<String, dynamic>>(value);
          return CameraSuccess<Map<String, dynamic>>({...value, 'gain': gain});
        }(),
      CameraFailure(:final reason) => CameraFailure<Map<String, dynamic>>(reason),
      CameraTimeout() => const CameraTimeout<Map<String, dynamic>>(),
    };
  }

  Future<CameraResult<Map<String, dynamic>>> _getNightVisionType(Duration timeout) async {
    final statusResult = await _get('/nuraeye/video/night-vision-type', timeout);
    if (statusResult is! CameraSuccess<Map<String, dynamic>>) return statusResult;

    final capsResult = await _get('/nuraeye/capabilities', timeout);
    final caps = capsResult is CameraSuccess<Map<String, dynamic>>
        ? capsResult.value
        : const <String, dynamic>{};
    return CameraSuccess<Map<String, dynamic>>({
      ...statusResult.value,
      'color_capable': caps['night_vision_color_capable'] ?? false,
      'smart_capable': caps['night_vision_smart_capable'] ?? false,
    });
  }

  Future<CameraResult<Map<String, dynamic>>> _get(String path, Duration timeout) =>
      _authed(timeout, (client) => client.get(path));

  /// `FR-NE-117`: optional `start`/`end` (UTC epoch seconds) query params, appended only when
  /// present — [RecordingsClient.getRecordings] passes `null` for "no bound" as the camera's
  /// own REST handler expects (an absent param, not a literal `0`).
  Future<CameraResult<Map<String, dynamic>>> _getRecordings(
    Map<String, dynamic> p,
    Duration timeout,
  ) {
    final query = <String, String>{
      if (p['start'] != null) 'start': '${p['start']}',
      if (p['end'] != null) 'end': '${p['end']}',
    };
    final path = query.isEmpty
        ? '/nuraeye/recordings'
        : '/nuraeye/recordings?${query.entries.map((e) => '${e.key}=${e.value}').join('&')}';
    return _get(path, timeout);
  }

  Future<CameraResult<Map<String, dynamic>>> _post(
    String path,
    Map<String, dynamic> body,
    Duration timeout,
  ) => _authed(timeout, (client) => client.post(path, body));

  /// Ensures a valid, **not-yet-expired** bearer token before issuing [op] — checked proactively
  /// against [_Session.isExpiredOrExpiringSoon], not just reacted to after the fact — and still
  /// retries [op] once (after a fresh login) on a `401` as a backstop for anything the proactive
  /// check can't see: a session evicted by the firmware's LRU policy from *another* client's
  /// login, clock skew between this device and the camera, or the leeway window itself proving
  /// too short under real network latency.
  Future<CameraResult<Map<String, dynamic>>> _authed(
    Duration timeout,
    Future<rest.RestResult<Map<String, dynamic>>> Function(rest.NuraeyeRestClient) op,
  ) async {
    final String token;
    switch (await _tokenFor(timeout)) {
      case CameraSuccess<String>(:final value):
        token = value;
      case CameraFailure<String>(:final reason):
        return CameraFailure(reason);
      case CameraTimeout<String>():
        return const CameraTimeout();
    }

    final client = _newRestClient(timeout)..setToken(token);
    var result = await op(client);

    if (result case rest.RestFailure(statusCode: 401)) {
      _sessionByHost.remove(connection.host);
      final String retryToken;
      switch (await _tokenFor(timeout)) {
        case CameraSuccess<String>(:final value):
          retryToken = value;
        case CameraFailure<String>(:final reason):
          return CameraFailure(reason);
        case CameraTimeout<String>():
          return const CameraTimeout();
      }
      final retryClient = _newRestClient(timeout)..setToken(retryToken);
      result = await op(retryClient);
      if (result is rest.RestSuccess) {
        _touchSession(retryToken);
      }
    } else if (result is rest.RestSuccess) {
      _touchSession(token);
    }

    return switch (result) {
      rest.RestSuccess(:final value) => CameraSuccess(value),
      // Prefix with "HTTP <code>: " when a status is known — mirrors the legacy JSON-RPC
      // client's failure text ('HTTP ${response.statusCode}: ${response.body}'), which at least
      // one caller (add_camera_credentials_screen.dart's reason.contains('401') check, to show
      // "Incorrect username or password" instead of a generic unreachable message) depends on
      // finding the numeric status code as text in the reason string — `RestFailure.reason`
      // alone only carries the firmware's `error_msg` (e.g. "Invalid credentials"), which never
      // contains the digits "401" on its own. Found 2026-08-10 after a user report of every
      // REST auth failure showing the wrong error message post-migration. `_login` below now
      // applies this same convention to a *login* failure, not just an authenticated call's own
      // failure — see its doc comment for the follow-up bug this alone didn't fix.
      rest.RestFailure(:final reason, :final statusCode) => CameraFailure(
          statusCode != null ? 'HTTP $statusCode: $reason' : reason,
        ),
      rest.RestTimeout() => const CameraTimeout(),
    };
  }

  /// Pushes a still-in-use session's expiry forward, mirroring the firmware's idle timeout
  /// (resets on activity, not a fixed instant from login) — an actively-polled session (e.g.
  /// live view's periodic calls) should never be proactively relogged-into just because the
  /// original login happened a while ago. Only touches the entry if it still holds [token] —
  /// if a concurrent call already replaced it with a newer session, that one wins instead.
  void _touchSession(String token) {
    final current = _sessionByHost[connection.host];
    if (current != null && current.token == token) {
      _sessionByHost[connection.host] = current.touched();
    }
  }

  /// `FR-NE-118`: exposes a valid `Authorization` header for a caller that needs to build a raw
  /// request itself, outside [call]'s JSON dispatch — currently only `GET
  /// /nuraeye/recordings/{id}/clip` (`RecordingsClient.clipHeaders`), whose response is binary
  /// (a video file passed straight to a video-player widget), not something [call]'s
  /// `Map<String, dynamic>`-returning path can serve. Reuses the exact same [_tokenFor] session
  /// cache/dedup/expiry logic every other request already goes through — never logs in
  /// separately for this purpose.
  Future<CameraResult<Map<String, String>>> authHeadersFor({
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final result = await _tokenFor(timeout);
    return switch (result) {
      CameraSuccess(:final value) =>
        CameraSuccess<Map<String, String>>({'Authorization': 'Bearer $value'}),
      CameraFailure(:final reason) => CameraFailure<Map<String, String>>(reason),
      CameraTimeout() => const CameraTimeout<Map<String, String>>(),
    };
  }

  Future<CameraResult<String>> _tokenFor(Duration timeout) async {
    final cached = _sessionByHost[connection.host];
    if (cached != null && !cached.isExpiredOrExpiringSoon) return CameraSuccess(cached.token);

    final host = connection.host;
    final inFlight = _loginInFlightByHost[host];
    if (inFlight != null) return inFlight;

    final loginFuture = _login(timeout);
    _loginInFlightByHost[host] = loginFuture;
    try {
      return await loginFuture;
    } finally {
      // Only clear if we're still the in-flight entry — a slow login that finished after a
      // newer one already replaced it (e.g. this login failed and a retry from another call
      // started its own) must not clobber that newer entry.
      if (identical(_loginInFlightByHost[host], loginFuture)) {
        _loginInFlightByHost.remove(host);
      }
    }
  }

  /// Returns [CameraFailure]/[CameraTimeout] (not a bare `null`) on a login rejection — real bug
  /// found 2026-08-11: entering a wrong password during add-camera always showed "Could not
  /// reach the camera — check the connection" instead of "Incorrect username or password".
  /// `session/login` itself rejects a bad password with a real `401` (`digest mismatch`,
  /// confirmed via camera serial log), but this method previously discarded that status code and
  /// returned a bare `null` on any login failure — so `_authed` always fell back to a generic,
  /// status-code-less `'NuraEye REST session login failed'` string, which
  /// `add_camera_credentials_screen.dart`'s `reason.contains('401')` check could never match.
  /// The `_authed`-level fix (2026-08-10, HTTP-status-prefixed `CameraFailure`) only covered a
  /// failure on the *authenticated* call itself — this camera's very first authenticated call
  /// during add-camera (`GetWiFiInfo`) never even gets that far when the password is wrong,
  /// since login fails first. Same `HTTP <code>: <reason>` convention as `_authed`'s own
  /// `RestFailure` handling below, so callers see one consistent failure-text shape regardless
  /// of which of the two requests actually failed.
  Future<CameraResult<String>> _login(Duration timeout) async {
    final digest = WsseDigest.generate(connection.password);
    final client = rest.RestIdentityDiscoveryClient(_newRestClient(timeout));
    final result = await client.sessionLogin(
      username: connection.username,
      passwordDigest: digest.digestBase64,
      nonce: digest.nonceBase64,
      created: digest.createdIso,
    );
    return switch (result) {
      rest.RestSuccess(:final value) => () {
          final token = value.token;
          if (token == null) {
            return const CameraFailure<String>('session/login succeeded but returned no token');
          }
          final expiresInSec = value.expiresInSec ?? _defaultExpiresInSec;
          _sessionByHost[connection.host] = _Session(
            token: token,
            expiresInSec: expiresInSec,
            validUntil: DateTime.now().add(Duration(seconds: expiresInSec)),
          );
          return CameraSuccess<String>(token);
        }(),
      rest.RestFailure(:final reason, :final statusCode) => CameraFailure<String>(
          statusCode != null ? 'HTTP $statusCode: $reason' : reason,
        ),
      rest.RestTimeout() => const CameraTimeout<String>(),
    };
  }

  /// Verifies the camera at [connection]'s host is a genuine NuraEye device via the
  /// `POST /nuraeye/identity` challenge-response handshake (`FR-MOB-011`, `FR-NE-001`) — a
  /// **fixed** challenge password, not [connection]'s real credentials, since this runs
  /// before/independent of knowing (or caring about) the camera's actual account credentials.
  /// Locally recomputes the expected reply digest and compares it, rather than trusting a bare
  /// success — mirrors the archived `android_app`'s `NuraeyeService.areYouNuraeyeDevice()`
  /// verification exactly, per
  /// `design/stages/mobile-app-android-2-camera-onboarding/DESIGN.md` §4.2. Unauthenticated
  /// (`security: []` in the OpenAPI spec) — no session/bearer token involved.
  Future<CameraResult<bool>> areYouNuraeyeDevice({
    Duration timeout = const Duration(seconds: 5),
  }) async {
    const challengePassword = 'are-you-onchip-nuraeye';
    const expectedReplyPlaintext = 'yes-i-am-onchip-nuraeye';

    final digest = WsseDigest.generate(challengePassword);
    final client = rest.RestIdentityDiscoveryClient(_newRestClient(timeout));
    final result = await client.identityChallenge(
      nonce: digest.nonceBase64,
      created: digest.createdIso,
      digest: digest.digestBase64,
    );

    return switch (result) {
      rest.RestSuccess(:final value) => () {
          final reply = value.reply;
          if (reply == null) {
            return const CameraFailure<bool>('missing reply digest in response');
          }
          final expectedDigest = WsseDigest.computeDigest(
            expectedReplyPlaintext,
            nonceBase64: digest.nonceBase64,
            createdIso: digest.createdIso,
          );
          return CameraSuccess<bool>(reply == expectedDigest);
        }(),
      rest.RestFailure(:final reason) => CameraFailure<bool>(reason),
      rest.RestTimeout() => const CameraTimeout<bool>(),
    };
  }

  /// Retrying variant of [areYouNuraeyeDevice] for **first-contact discovery/onboarding only**
  /// — added 2026-08-15 per direct user report and a live Python check confirming the root
  /// cause: a phone's *first* HTTPS request over a given WiFi connection can be slow (WiFi radio
  /// waking from power-save, cold TLS handshake against the camera's self-signed cert), which
  /// [areYouNuraeyeDevice]'s single-attempt default was intermittently losing to even for a
  /// genuine camera — confirmed to answer in ~0.4s, 10/10, once the connection isn't cold.
  /// Mirrors `probeCloudSnapshotsSupported`'s existing retry shape (`camera_settings_cache.dart`).
  ///
  /// **Deliberately not folded into [areYouNuraeyeDevice] itself** — `LiveStreamUriClient
  /// .checkReachable()` relies on that method staying a fast, single-shot probe (it only runs
  /// *after* live-view's own retries are already exhausted, specifically to fail over to WAN
  /// quickly, not to keep retrying over LAN).
  Future<CameraResult<bool>> areYouNuraeyeDeviceWithRetry({
    int attempts = 3,
    Duration attemptTimeout = const Duration(seconds: 8),
    Duration retryDelay = const Duration(seconds: 1),
  }) async {
    CameraResult<bool> last = const CameraTimeout<bool>();
    for (var attempt = 0; attempt < attempts; attempt++) {
      last = await areYouNuraeyeDevice(timeout: attemptTimeout);
      if (last is CameraSuccess<bool> && last.value) return last;
      if (attempt < attempts - 1) {
        await Future<void>.delayed(retryDelay);
      }
    }
    return last;
  }

  void close() => _http.close();
}
