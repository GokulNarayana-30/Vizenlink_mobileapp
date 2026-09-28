import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';

import '../../camera_connection.dart';
import '../../camera_result.dart';
import '../insecure_camera_http_client.dart';
import 'onvif_device_client.dart';
import 'soap_fault.dart';
import '../wsse_digest.dart';

const _media2Namespace = 'http://www.onvif.org/ver20/media/wsdl';

/// The subset of ONVIF Media2's `GetServiceCapabilities` this app needs — whether this camera
/// advertises OSD and (privacy) Mask support, per the real ONVIF ver20 Media2 schema's
/// `tr2:Capabilities` element (`OSD`/`Mask` boolean attributes), not a NuraEye-specific flag.
/// Confirmed against `onvif_media_capabilities.c`/`onvif_media2_get_service_capabilities.xml` —
/// both attributes are already implemented and wired to real values in this firmware, so this is
/// a genuine capability check, not a guess.
class Media2Capabilities {
  const Media2Capabilities({required this.osdSupported, required this.maskSupported});
  final bool osdSupported;
  final bool maskSupported;
}

/// LAN-only client for Media2 `GetServiceCapabilities`. **Does not hardcode the Media2 service
/// path** — every call first resolves the real endpoint via `OnvifDeviceClient.getServices()`
/// (the standard ONVIF service-discovery mechanism), per direct user direction: the app must
/// use whatever URL the camera's own `GetServices` response reports, not assume a fixed path.
/// If `GetServices` doesn't list a Media2 entry at all, this camera doesn't offer the service —
/// reported as a normal "not supported" result, not a failure, since that's a legitimate,
/// expected outcome for some builds, not an error condition.
class Media2CapabilitiesClient {
  Media2CapabilitiesClient(this.connection, {http.Client? httpClient})
    : _http = httpClient ?? createCameraHttpClient(),
      _device = OnvifDeviceClient(connection, httpClient: httpClient);

  final CameraConnection connection;
  final http.Client _http;
  final OnvifDeviceClient _device;

  Future<CameraResult<Media2Capabilities>> getServiceCapabilities({
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final servicesResult = await _device.getServices(timeout: timeout);
    final Uri media2XAddr;
    switch (servicesResult) {
      case CameraSuccess<List<OnvifServiceEntry>>(:final value):
        final entry = value.where((e) => e.namespace == _media2Namespace).firstOrNull;
        if (entry == null) {
          // Media2 isn't offered by this device at all — not an error, just unsupported.
          return const CameraSuccess(
            Media2Capabilities(osdSupported: false, maskSupported: false),
          );
        }
        media2XAddr = entry.xAddr;
      case CameraFailure(:final reason):
        return CameraFailure(reason);
      case CameraTimeout():
        return const CameraTimeout();
    }

    final digest = WsseDigest.generate(connection.password);
    final envelope =
        '<?xml version="1.0" encoding="UTF-8"?>'
        '<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope">'
        '<s:Header>'
        '<wsse:Security xmlns:wsse="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd">'
        '<wsse:UsernameToken>'
        '<wsse:Username>${connection.username}</wsse:Username>'
        '<wsse:Password Type="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-username-token-profile-1.0#PasswordDigest">'
        '${digest.digestBase64}</wsse:Password>'
        '<wsse:Nonce EncodingType="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-soap-message-security-1.0#Base64Binary">'
        '${digest.nonceBase64}</wsse:Nonce>'
        '<wsu:Created xmlns:wsu="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd">'
        '${digest.createdIso}</wsu:Created>'
        '</wsse:UsernameToken>'
        '</wsse:Security>'
        '</s:Header>'
        '<s:Body>'
        '<tr2:GetServiceCapabilities xmlns:tr2="$_media2Namespace"/>'
        '</s:Body>'
        '</s:Envelope>';

    try {
      final response = await _http
          .post(
            media2XAddr,
            headers: const {'Content-Type': 'application/soap+xml; charset=utf-8'},
            body: envelope,
          )
          .timeout(timeout);

      // [AI Fix] 2026-09-24: SOAP-fault check moved before the status-code check -- real bug
      // found via RecordingTimelineScreen's single-playback-session rejection (module_rtsps.c
      // via OperationProhibited/409): this firmware returns a real <Fault> body on a non-200
      // status for some rejections (unlike the Media2-validation-error case soapFaultReason's
      // own doc describes, which is HTTP 200), and the old ordering returned the raw XML fault
      // body as the error string before soapFaultReason() ever got a chance to parse it --
      // exactly the "SOAP response dumped in the UI" symptom this fixes. A fault is checked for
      // on every response regardless of status; the raw "HTTP <code>: <body>" fallback now only
      // fires for a genuinely non-SOAP failure (e.g. a proxy's own 502/503 HTML page).
      final faultReason = soapFaultReason(response.body);
      if (faultReason != null) return CameraFailure(faultReason);

      if (response.statusCode != 200) {
        return CameraFailure('HTTP ${response.statusCode}: ${response.body}');
      }

      final doc = XmlDocument.parse(response.body);
      final el = doc.findAllElements('Capabilities', namespace: '*');
      if (el.isEmpty) {
        return const CameraFailure('GetServiceCapabilitiesResponse missing Capabilities element');
      }
      final attrs = el.first.attributes;
      final osd = attrs.where((a) => a.localName == 'OSD').firstOrNull?.value;
      final mask = attrs.where((a) => a.localName == 'Mask').firstOrNull?.value;
      return CameraSuccess(
        Media2Capabilities(osdSupported: osd == 'true', maskSupported: mask == 'true'),
      );
    } on Exception catch (e) {
      return CameraFailure(e.toString());
    }
  }

  void close() {
    _http.close();
    _device.close();
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
