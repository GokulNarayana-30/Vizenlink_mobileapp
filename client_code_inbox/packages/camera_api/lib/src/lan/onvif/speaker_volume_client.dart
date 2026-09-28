import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';

import '../../camera_connection.dart';
import '../../camera_result.dart';
import '../insecure_camera_http_client.dart';
import '../wsse_digest.dart';
import 'soap_fault.dart';
import 'onvif_device_client.dart';

const _kMedia2Namespace = 'http://www.onvif.org/ver20/media/wsdl';

/// This build's one fixed `AudioOutputConfiguration` token (`onvif_user_config.c`'s
/// `AUDIO_OUTPUT_CFG_TOKEN`). Unlike Media v1's parameterless `GetAudioOutputConfigurations`,
/// Media2's version takes an optional `ConfigurationToken`/`ProfileToken` filter and — per
/// `onvif_media2.c`'s dispatch — returns an empty response when neither is given, so this must
/// be passed explicitly (mirroring `OsdClient`/`MaskClient`'s own `_kVideoSourceConfigToken`
/// convention for their own `ConfigurationToken` filters).
const _kAudioOutputConfigToken = 'AudioOutputCfg_1';

/// One `AudioOutputConfiguration` as read from the camera — `token`/`name`/`outputToken` are
/// round-tripped verbatim on [SpeakerVolumeClient.setSpeakerVolume] (the camera only actually
/// applies `token` + `outputLevel`, per `testing_utilities/onvif_client.py`'s
/// `set_audio_output_configuration()` doc comment, but the SOAP schema requires the sibling
/// elements present) rather than reconstructed from scratch.
class SpeakerVolume {
  const SpeakerVolume({
    required this.token,
    required this.name,
    required this.outputToken,
    required this.outputLevel,
  });

  final String token;
  final String name;
  final String outputToken;

  /// `0`-`100` (`FR-OV-046`'s advertised range).
  final int outputLevel;

  SpeakerVolume withLevel(int level) =>
      SpeakerVolume(token: token, name: name, outputToken: outputToken, outputLevel: level);

  /// Value equality — lets UI code (`_SettingCard<SpeakerVolume>`'s pending-vs-applied dirty
  /// check, mirroring `NightVisionStatus`'s own convention) compare by content instead of
  /// identity.
  @override
  bool operator ==(Object other) =>
      other is SpeakerVolume &&
      other.token == token &&
      other.name == name &&
      other.outputToken == outputToken &&
      other.outputLevel == outputLevel;

  @override
  int get hashCode => Object.hash(token, name, outputToken, outputLevel);
}

/// Camera-side speaker output volume (`FR-MOB-081`, ONVIF Media2
/// `GetAudioOutputConfigurations`/`SetAudioOutputConfiguration`, `FR-OV-044`/`101`) — distinct
/// from the phone's own local volume/mute. Hardware-verified 2026-07-28
/// (`reports/speaker_mic_volume_test_20260728T114217Z.md`) — that run was against Media v1;
/// **migrated to Media2 2026-08-11** (`FR-OV-101` closed the gap — Media2 previously had only
/// `GetAudioOutputConfigurations`, `FR-OV-044`; `SetAudioOutputConfiguration`/
/// `GetAudioOutputConfigurationOptions` existed only in Media v1 until now, confirmed against
/// the real `ver20/media/wsdl/media.wsdl`, not just this repo's own code — an earlier claim that
/// Media2 has no audio operations at all was wrong), not yet hardware-re-verified against this
/// namespace.
///
/// **Split out of the former combined `AudioVolumeClient` 2026-08-11** — mic gain, the
/// recording toggle, and test-sound are unrelated NuraeyeClient (`/nuraeye` JSON) actions that
/// happened to live in the same class as this ONVIF one; see
/// `lan/nuraeye/audio_volume_client.dart` for those, and `kb/raw/2026-08-11-code-camera-api-lan-
/// wan-restructure.md` for why a single class speaking two protocols didn't belong in a
/// `lan/onvif/` vs `lan/nuraeye/` folder split.
class SpeakerVolumeClient {
  SpeakerVolumeClient(this.connection, {http.Client? httpClient, Uri? endpoint})
    : _http = httpClient ?? createCameraHttpClient(),
      _device = OnvifDeviceClient(connection, httpClient: httpClient),
      _resolvedEndpoint = endpoint;

  final CameraConnection connection;
  final http.Client _http;
  final OnvifDeviceClient _device;

  /// Instance-lifetime only — see `OnvifVideoEncoderClient._resolvedEndpoint`'s doc for why this
  /// is no longer a `static`/process-lifetime cache (that moved to the app layer,
  /// `camera_settings_cache.dart`'s `NetworkAnswerCache`). Seed via the [endpoint] constructor
  /// parameter to skip the `GetServices` round trip; read back via [resolvedEndpoint].
  Uri? _resolvedEndpoint;

  Uri? get resolvedEndpoint => _resolvedEndpoint;

  Future<CameraResult<Uri>> resolveMedia2Endpoint({
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final cached = _resolvedEndpoint;
    if (cached != null) return CameraSuccess(cached);

    final servicesResult = await _device.getServices(timeout: timeout);
    switch (servicesResult) {
      case CameraSuccess<List<OnvifServiceEntry>>(:final value):
        final entry = value.where((e) => e.namespace == _kMedia2Namespace).firstOrNull;
        if (entry == null) {
          return const CameraFailure('Media2 service not offered by this camera');
        }
        _resolvedEndpoint = entry.xAddr;
        return CameraSuccess(entry.xAddr);
      case CameraFailure(:final reason):
        return CameraFailure(reason);
      case CameraTimeout():
        return const CameraTimeout();
    }
  }

  Future<CameraResult<SpeakerVolume>> getSpeakerVolume({
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final bodyResult = await _post(
      '<tr2:GetAudioOutputConfigurations xmlns:tr2="http://www.onvif.org/ver20/media/wsdl">'
      '<tr2:ConfigurationToken>$_kAudioOutputConfigToken</tr2:ConfigurationToken>'
      '</tr2:GetAudioOutputConfigurations>',
      timeout,
    );
    if (bodyResult is CameraFailure<String>) return CameraFailure(bodyResult.reason);
    if (bodyResult is CameraTimeout<String>) return const CameraTimeout();
    final body = (bodyResult as CameraSuccess<String>).value;

    final cfgEl = XmlDocument.parse(body).findAllElements('Configurations', namespace: '*');
    if (cfgEl.isEmpty) {
      // Empty list means no speaker on this build (FR-OV-037) — the UI is expected to have
      // already gated this control on `AudioCapabilityClient.hasSpeaker` and never call here.
      return const CameraFailure('camera has no AudioOutputConfiguration (no speaker)');
    }
    final el = cfgEl.first;
    final token = el.getAttribute('token') ?? '';
    String text(String tag) {
      final found = el.findAllElements(tag, namespace: '*');
      return found.isEmpty ? '' : found.first.innerText.trim();
    }

    final level = int.tryParse(text('OutputLevel')) ?? 0;
    return CameraSuccess(
      SpeakerVolume(token: token, name: text('Name'), outputToken: text('OutputToken'), outputLevel: level),
    );
  }

  Future<CameraResult<void>> setSpeakerVolume(
    SpeakerVolume current, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final bodyResult = await _post(
      '<tr2:SetAudioOutputConfiguration xmlns:tr2="http://www.onvif.org/ver20/media/wsdl" '
      'xmlns:tt="http://www.onvif.org/ver10/schema">'
      '<tr2:Configuration token="${current.token}">'
      '<tt:Name>${current.name}</tt:Name>'
      '<tt:UseCount>0</tt:UseCount>'
      '<tt:OutputToken>${current.outputToken}</tt:OutputToken>'
      '<tt:OutputLevel>${current.outputLevel}</tt:OutputLevel>'
      '</tr2:Configuration>'
      '</tr2:SetAudioOutputConfiguration>',
      timeout,
    );
    if (bodyResult is CameraFailure<String>) return CameraFailure(bodyResult.reason);
    if (bodyResult is CameraTimeout<String>) return const CameraTimeout();
    return const CameraSuccess(null);
  }

  Future<CameraResult<String>> _post(String bodyXml, Duration timeout) async {
    final endpointResult = await resolveMedia2Endpoint(timeout: timeout);
    final Uri endpoint;
    switch (endpointResult) {
      case CameraSuccess<Uri>(:final value):
        endpoint = value;
      case CameraFailure(:final reason):
        return CameraFailure(reason);
      case CameraTimeout():
        return const CameraTimeout();
    }

    final digest = WsseDigest.generate(connection.password);
    final envelope = '<?xml version="1.0" encoding="UTF-8"?>'
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
        '<s:Body>$bodyXml</s:Body>'
        '</s:Envelope>';

    try {
      final response = await _http
          .post(
            endpoint,
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

      return CameraSuccess(response.body);
    } on TimeoutException {
      return const CameraTimeout();
    } on Exception catch (e) {
      return CameraFailure(e.toString());
    }
  }

  void close() {
    _http.close();
    _device.close();
  }
}
