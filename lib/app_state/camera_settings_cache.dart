import 'package:camera_api/camera_api.dart';

import 'camera_network.dart';

/// Process-lifetime, host-keyed cache for `Get*Options`-style capability
/// responses — the "cache these at process lifetime, keyed by
/// `CameraConnection.host`" convention (`.claude/rules/
/// mobile-app-screen-conventions.md`) used to live *inside* each
/// `camera_api` client class as a `static` map (e.g. `MaskClient`'s old
/// `_optionsCacheByHost`). As of the 2026-09-07 `camera_api` update, every
/// such client now makes an always-live call with no internal caching of
/// its own (see e.g. `MaskClient.getMaskOptions`'s doc comment) — the
/// package deliberately pushed that responsibility up to the app layer
/// ("camera api should be clean... just network client only", per that
/// update's own `SETTINGS_API_GUIDE.md`). This class is that app-layer
/// cache, restoring the old fast-repeat-visit behavior for Imaging, OSD,
/// Video Encoder, Mask/Privacy, and Network Info's supported-timezones
/// call — the five call sites [prefetchAndCache] warms below.
class NetworkAnswerCache {
  NetworkAnswerCache._();

  static final Map<String, dynamic> _values = {};

  /// Returns the cached value for `<host>::<key>` unless [forceRefresh] is
  /// true or nothing's cached yet, in which case it calls [fetch] and
  /// caches a successful result. A failure/timeout is never cached, so the
  /// next call (even without `forceRefresh`) retries the network fresh
  /// instead of getting stuck repeating a stale failure.
  static Future<CameraResult<T>> getOrFetch<T>(
    String host,
    String key, {
    required Future<CameraResult<T>> Function() fetch,
    bool forceRefresh = false,
  }) async {
    final cacheKey = '$host::$key';
    if (!forceRefresh && _values.containsKey(cacheKey)) {
      return CameraSuccess<T>(_values[cacheKey] as T);
    }
    final result = await fetch();
    if (result is CameraSuccess<T>) {
      _values[cacheKey] = result.value;
    }
    return result;
  }

  /// Drops every cached answer for [host] — call when a camera is removed
  /// (a stale answer for a host that might be re-added, possibly with
  /// different firmware/capabilities, must not leak forward).
  static void clearForHost(String host) {
    _values.removeWhere((cacheKey, _) => cacheKey.startsWith('$host::'));
  }

  /// Test-only reset hook — a process-lifetime static cache otherwise leaks
  /// state between test cases that reuse a fixed mock host.
  static void debugClearAll() => _values.clear();
}

/// Fires off every settings screen's `Get*Options`-style capability call for
/// [connection] in parallel, right after a camera is added, so
/// [NetworkAnswerCache] is already warm by the time the user opens Imaging,
/// OSD, Video Encoder, Privacy/Intrusion/Line-Crossing/Person-Detection
/// (mask-backed), or Camera Info's timezone picker, instead of paying a cold
/// LAN round trip on each screen's first visit. (Before the 2026-09-07
/// `camera_api` update, each client cached this internally as its own
/// process-lifetime `static` map; that responsibility now lives here — see
/// [NetworkAnswerCache]'s doc comment.)
///
/// Also warms `AudioCapabilityClient`/`SpeakerVolumeClient` for
/// `AudioScreen` — unlike the five above, these two are *not* routed
/// through [NetworkAnswerCache]: only the resolved ONVIF service endpoint
/// used to be cached for them (never the capability/volume value itself,
/// which is genuinely live/mutable and always re-fetched live on screen
/// open per the caching convention's "never cache live state" rule), and
/// that endpoint-level caching was internal to those two clients — calling
/// them here still warms whatever internal state they have and costs
/// nothing extra either way.
///
/// Best-effort and silent: a call that fails here simply leaves that
/// client's cache empty, and the owning screen falls back to its own normal
/// live fetch on first visit exactly as it did before this existed. Meant to
/// be called `unawaited()`, mirroring `syncCameraFromDevice`'s fire-and-forget
/// use in the add-camera flow — this never blocks add or reports failures of
/// its own.
///
/// **Run one call at a time, not concurrently** — an earlier version fired
/// all of these via `Future.wait`, which floods the camera's embedded HTTP
/// server and can turn a single screen open into a many-seconds-to-tens-of-
/// seconds stall (the sibling `nuraeye-rt` app hit and documented this exact
/// failure mode before rewriting its own equivalent prefetch to be
/// sequential).
Future<void> prefetchAndCache(CameraConnection connection) async {
  final imaging = OnvifImagingClient(
    connection,
    httpClient: CameraNetwork.clientFor(connection.host),
  );
  final osd = OsdClient(
    connection,
    httpClient: CameraNetwork.clientFor(connection.host),
    endpoint: CameraNetwork.media2EndpointFor(connection.host),
  );
  final videoEncoder = OnvifVideoEncoderClient(
    connection,
    httpClient: CameraNetwork.clientFor(connection.host),
    endpoint: CameraNetwork.media2EndpointFor(connection.host),
  );
  final mask = MaskClient(
    connection,
    httpClient: CameraNetwork.clientFor(connection.host),
    endpoint: CameraNetwork.media2EndpointFor(connection.host),
  );
  final networkInfo = NetworkInfoClient(connection);
  final audioCapability = AudioCapabilityClient(
    connection,
    httpClient: CameraNetwork.clientFor(connection.host),
    endpoint: CameraNetwork.media2EndpointFor(connection.host),
  );
  final speakerVolume = SpeakerVolumeClient(
    connection,
    httpClient: CameraNetwork.clientFor(connection.host),
    endpoint: CameraNetwork.media2EndpointFor(connection.host),
  );
  try {
    await NetworkAnswerCache.getOrFetch(
      connection.host,
      'imagingOptions',
      fetch: imaging.getImagingOptions,
    );
    await NetworkAnswerCache.getOrFetch(
      connection.host,
      'osdOptions',
      fetch: osd.getOsdOptions,
    );
    // Warms all three stream configs, not just High — `videoEncoderOptions`
    // used to mean "High only" before `OnvifVideoEncoderClient` was
    // generalized to take a `configToken` (2026-09-11); this now must match
    // `VideoStreamEncoderScreen`'s own per-token cache key
    // (`videoEncoderOptions:$configToken`) or the warm cache is silently a
    // no-op — every screen visit pays a live round trip regardless.
    for (final token in const [
      kHighResVideoEncoderToken,
      kMediumResVideoEncoderToken,
      kLowResVideoEncoderToken,
    ]) {
      await NetworkAnswerCache.getOrFetch(
        connection.host,
        'videoEncoderOptions:$token',
        fetch: () =>
            videoEncoder.getVideoEncoderSettingsOptions(configToken: token),
      );
    }
    await NetworkAnswerCache.getOrFetch(
      connection.host,
      'maskOptions',
      fetch: mask.getMaskOptions,
    );
    await NetworkAnswerCache.getOrFetch(
      connection.host,
      'supportedTimezones',
      fetch: networkInfo.getSupportedTimezones,
    );
    await audioCapability.getAudioCapability();
    await speakerVolume.getSpeakerVolume();
  } finally {
    imaging.close();
    CameraNetwork.rememberMedia2Endpoint(connection.host, osd.resolvedEndpoint);
    osd.close();
    CameraNetwork.rememberMedia2Endpoint(
      connection.host,
      videoEncoder.resolvedEndpoint,
    );
    videoEncoder.close();
    CameraNetwork.rememberMedia2Endpoint(
      connection.host,
      mask.resolvedEndpoint,
    );
    mask.close();
    networkInfo.close();
    CameraNetwork.rememberMedia2Endpoint(
      connection.host,
      audioCapability.resolvedEndpoint,
    );
    audioCapability.close();
    CameraNetwork.rememberMedia2Endpoint(
      connection.host,
      speakerVolume.resolvedEndpoint,
    );
    speakerVolume.close();
  }
}
