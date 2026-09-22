import 'package:camera_api/camera_api.dart';
import 'package:http/http.dart' as http;

/// One pooled HTTPS connection per camera host, plus the ONVIF Media2 service
/// endpoint resolved on it.
///
/// Every ONVIF client in `camera_api` builds its own `HttpClient` when none is
/// passed **and** nests an `OnvifDeviceClient` that builds another, so a screen
/// constructing a client per load and per Apply pays two fresh TLS handshakes
/// to the camera every time. Those clients also cache their resolved service
/// endpoint for their own instance lifetime only, and their doc comments say
/// the app should seed it — without that, each operation spends an extra
/// `GetServices` round trip before the call it actually wanted.
///
/// This holds both, keyed by `CameraConnection.host`, for the life of the
/// process — the same lifetime [NetworkAnswerCache] uses for option values.
/// Together they are the app-layer half of the 2026-09-07 `camera_api` change
/// that moved caching out of the package: `NetworkAnswerCache` covers option
/// *values*, this covers the connection and endpoint underneath them.
///
/// Deliberately not used by the scan/add-camera flows — those probe hosts that
/// may never become saved cameras, and pooling a connection per scanned
/// address would leak one entry per host on the network.
class CameraNetwork {
  CameraNetwork._();

  static final Map<String, http.Client> _clientByHost = {};
  static final Map<String, Uri> _media2EndpointByHost = {};

  /// The shared client for [host].
  ///
  /// Its `close()` is a no-op: call sites routinely close the client they were
  /// handed, and one screen closing a connection other screens are still using
  /// would be a real bug. [evictHost] is the only thing that truly closes it.
  static http.Client clientFor(String host) =>
      _NonClosingClient(_clientByHost[host] ??= createCameraHttpClient());

  /// The ONVIF Media2 endpoint last resolved for [host], to pass as a client's
  /// `endpoint:` so it can skip `GetServices`. Safe to share across
  /// `MaskClient`, `OsdClient`, `OnvifVideoEncoderClient`,
  /// `AudioCapabilityClient` and `SpeakerVolumeClient` — all five resolve the
  /// same `ver20/media/wsdl` service through an identical lookup.
  static Uri? media2EndpointFor(String host) => _media2EndpointByHost[host];

  /// Records whatever endpoint a client resolved so the next one can skip
  /// resolving it. A null (never resolved, e.g. the call failed) is ignored.
  static void rememberMedia2Endpoint(String host, Uri? endpoint) {
    if (endpoint != null) _media2EndpointByHost[host] = endpoint;
  }

  /// Drops and really closes everything held for [host] — call on camera
  /// removal, alongside `NetworkAnswerCache.clearForHost`, so a stale endpoint
  /// can't survive a remove-and-re-add at the same address.
  static void evictHost(String host) {
    _clientByHost.remove(host)?.close();
    _media2EndpointByHost.remove(host);
  }

  /// Test-only reset hook — a process-lifetime static cache otherwise leaks
  /// state between test cases that reuse a fixed mock host.
  static void debugClearAll() {
    for (final client in _clientByHost.values) {
      client.close();
    }
    _clientByHost.clear();
    _media2EndpointByHost.clear();
  }
}

class _NonClosingClient extends http.BaseClient {
  _NonClosingClient(this._inner);

  final http.Client _inner;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      _inner.send(request);

  @override
  void close() {}
}
