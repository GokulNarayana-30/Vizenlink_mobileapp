import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';

import '../../camera_connection.dart';
import '../../camera_result.dart';
import '../insecure_camera_http_client.dart';
import '../wsse_digest.dart';
import 'soap_fault.dart';

const _kVideoSourceToken = 'VideoSource_1';

/// One video source's full imaging settings — covers Day/Night (`FR-MOB-064/065`), WDR
/// (`FR-MOB-066`), and ISP image-quality controls (`FR-MOB-075`) in a single struct, matching
/// the real ONVIF wire shape: all three ride the same `GetImagingSettings`/`SetImagingSettings`
/// SOAP call (`FR-OV-050`), not separate actions. `null` on any field means "not reported /
/// leave unchanged" — mirrors the firmware's own optional-field semantics
/// (`ONVIF_PARSER_OPTIONAL_*_VAL` sentinels in `onvif_imaging.c`).
class ImagingSettings {
  const ImagingSettings({
    this.brightness,
    this.colorSaturation,
    this.contrast,
    this.sharpness,
    this.irCutFilterMode,
    this.wdrMode,
    this.wdrLevel,
    this.exposureMode,
    this.exposureTime,
    this.exposureGain,
    this.whiteBalanceMode,
  });

  final double? brightness;
  final double? colorSaturation;
  final double? contrast;
  final double? sharpness;

  /// `"ON"` (day), `"OFF"` (night), `"AUTO"` — the Day/Night mode control (`FR-MOB-064/065`).
  final String? irCutFilterMode;

  /// `"OFF"` / `"ON"` — the WDR toggle (`FR-MOB-066`). `wdrLevel` (0-100) only applies when `ON`,
  /// and only on IMX662 SKUs (`FR-OV-050`'s sensor-conditional note); absent entirely on other
  /// sensors, so a `null` here after a `getImagingOptions()` call with no WDR range means "not
  /// supported on this SKU", not "not yet read".
  final String? wdrMode;
  final double? wdrLevel;

  /// `"AUTO"` / `"MANUAL"`.
  final String? exposureMode;
  final double? exposureTime;
  final double? exposureGain;

  /// `"AUTO"` / `"MANUAL"`.
  final String? whiteBalanceMode;

  ImagingSettings copyWith({
    double? brightness,
    double? colorSaturation,
    double? contrast,
    double? sharpness,
    String? irCutFilterMode,
    String? wdrMode,
    double? wdrLevel,
    String? exposureMode,
    double? exposureTime,
    double? exposureGain,
    String? whiteBalanceMode,
  }) {
    return ImagingSettings(
      brightness: brightness ?? this.brightness,
      colorSaturation: colorSaturation ?? this.colorSaturation,
      contrast: contrast ?? this.contrast,
      sharpness: sharpness ?? this.sharpness,
      irCutFilterMode: irCutFilterMode ?? this.irCutFilterMode,
      wdrMode: wdrMode ?? this.wdrMode,
      wdrLevel: wdrLevel ?? this.wdrLevel,
      exposureMode: exposureMode ?? this.exposureMode,
      exposureTime: exposureTime ?? this.exposureTime,
      exposureGain: exposureGain ?? this.exposureGain,
      whiteBalanceMode: whiteBalanceMode ?? this.whiteBalanceMode,
    );
  }
}

/// Supported value range for one float-valued imaging setting. Value equality (not the default
/// identity equality) matters here: `_ImageQualityState`-style records carrying a `FloatRange`
/// field rely on `==` to compare `pending` vs. `applied` for the settings screen's dirty-check —
/// see `.claude/rules/mobile-app-screen-conventions.md`'s "Settings/control screen UX conventions" point 5.
class FloatRange {
  const FloatRange(this.min, this.max);
  final double min;
  final double max;

  @override
  bool operator ==(Object other) =>
      other is FloatRange && other.min == min && other.max == max;

  @override
  int get hashCode => Object.hash(min, max);
}

/// `GetOptions` response — the bounds the app should constrain its controls to (`FR-OV-051`).
class ImagingOptions {
  const ImagingOptions({
    this.brightness,
    this.colorSaturation,
    this.contrast,
    this.sharpness,
    this.wdrLevel,
    required this.wdrSupported,
    this.whiteBalanceModes = const [],
    this.exposureModes = const [],
    this.exposureTime,
    this.exposureGain,
    this.irCutFilterModes = const [],
  });

  final FloatRange? brightness;
  final FloatRange? colorSaturation;
  final FloatRange? contrast;
  final FloatRange? sharpness;
  final FloatRange? wdrLevel;

  /// `false` when the `tt:WideDynamicRange` options element is entirely absent from the
  /// response — non-HDR sensors (GC4653, F37) per `FR-OV-051`'s sensor-conditional note. The UI
  /// must hide the WDR control outright in this case, not just disable it.
  final bool wdrSupported;

  /// `tt:IrCutFilterModes` values the camera actually supports (typically `['AUTO', 'ON',
  /// 'OFF']`) — the Day/Night mode control's choice list (`FR-MOB-064/065`). The UI must build
  /// its choice chips from this list, never a hardcoded `['AUTO', 'ON', 'OFF']` — see
  /// `.claude/rules/mobile-app-screen-conventions.md` § "LAN/WAN transport selection for settings screens" item 6.
  final List<String> irCutFilterModes;

  /// `tt:WhiteBalance/tt:Mode` values the camera actually supports (typically `['AUTO',
  /// 'MANUAL']`) — `FR-MOB-062`'s white-balance-mode control.
  final List<String> whiteBalanceModes;

  /// `tt:Exposure/tt:Mode` values (`['AUTO', 'MANUAL']`) plus the manual-mode `ExposureTime`/
  /// `Gain` bounds — `FR-MOB-062`'s exposure-mode control.
  final List<String> exposureModes;
  final FloatRange? exposureTime;
  final FloatRange? exposureGain;
}

/// LAN-only ONVIF Imaging client (`/onvif/imaging_service`, SOAP, WS-UsernameToken digest auth)
/// — used by Day/Night, WDR, and ISP Image Quality controls (`FR-MOB-064/065/066/075`), since
/// all three settings are exposed by the camera exclusively through ONVIF `GetImagingSettings`/
/// `SetImagingSettings`/`GetOptions`, not the NuraEye JSON API. No WAN counterpart exists yet in
/// this app (`FR-NE-056/057/074/075/076/077` are the camera-firmware side, hardware-verified,
/// but the app has no MQTT command channel built — see `WanLiveViewClient`'s own "interface
/// only" note; the same gap applies here).
class OnvifImagingClient {
  OnvifImagingClient(this.connection, {http.Client? httpClient})
      : _http = httpClient ?? createCameraHttpClient();

  final CameraConnection connection;
  final http.Client _http;

  Future<CameraResult<ImagingSettings>> getImagingSettings({
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final bodyResult = await _post(
      '<timg:GetImagingSettings xmlns:timg="http://www.onvif.org/ver20/imaging/wsdl">'
      '<timg:VideoSourceToken>$_kVideoSourceToken</timg:VideoSourceToken>'
      '</timg:GetImagingSettings>',
      timeout,
    );
    return bodyResult.map((body) {
      final doc = XmlDocument.parse(body);
      double? f(String tag) => _findDouble(doc, tag);
      String? s(String tag) => _findText(doc, tag);
      final wdrEl = doc.findAllElements('WideDynamicRange', namespace: '*');
      String? wdrMode;
      double? wdrLevel;
      if (wdrEl.isNotEmpty) {
        wdrMode = _findTextIn(wdrEl.first, 'Mode');
        wdrLevel = _findDoubleIn(wdrEl.first, 'Level');
      }
      final exposureEl = doc.findAllElements('Exposure', namespace: '*');
      String? exposureMode;
      double? exposureTime;
      double? exposureGain;
      if (exposureEl.isNotEmpty) {
        exposureMode = _findTextIn(exposureEl.first, 'Mode');
        exposureTime = _findDoubleIn(exposureEl.first, 'ExposureTime');
        exposureGain = _findDoubleIn(exposureEl.first, 'Gain');
      }
      final wbEl = doc.findAllElements('WhiteBalance', namespace: '*');
      final whiteBalanceMode = wbEl.isNotEmpty ? _findTextIn(wbEl.first, 'Mode') : null;

      return ImagingSettings(
        brightness: f('Brightness'),
        colorSaturation: f('ColorSaturation'),
        contrast: f('Contrast'),
        sharpness: f('Sharpness'),
        irCutFilterMode: s('IrCutFilter'),
        wdrMode: wdrMode,
        wdrLevel: wdrLevel,
        exposureMode: exposureMode,
        exposureTime: exposureTime,
        exposureGain: exposureGain,
        whiteBalanceMode: whiteBalanceMode,
      );
    });
  }

  /// Always a live network call — no caching in this package (see
  /// `.claude/rules/mobile-app-screen-conventions.md`'s "Caching capability/service-discovery
  /// responses" convention; the app layer caches this in `camera_settings_cache.dart`'s
  /// `NetworkAnswerCache`).
  Future<CameraResult<ImagingOptions>> getImagingOptions({
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final bodyResult = await _post(
      '<timg:GetOptions xmlns:timg="http://www.onvif.org/ver20/imaging/wsdl">'
      '<timg:VideoSourceToken>$_kVideoSourceToken</timg:VideoSourceToken>'
      '</timg:GetOptions>',
      timeout,
    );
    final result = bodyResult.map((body) {
      final doc = XmlDocument.parse(body);
      FloatRange? range(String tag) {
        final el = doc.findAllElements(tag, namespace: '*');
        if (el.isEmpty) return null;
        final min = _findDoubleIn(el.first, 'Min');
        final max = _findDoubleIn(el.first, 'Max');
        if (min == null || max == null) return null;
        return FloatRange(min, max);
      }

      final wdrEl = doc.findAllElements('WideDynamicRange', namespace: '*');
      FloatRange? wdrLevel;
      if (wdrEl.isNotEmpty) {
        final levelEl = wdrEl.first.findAllElements('Level', namespace: '*');
        if (levelEl.isNotEmpty) {
          final min = _findDoubleIn(levelEl.first, 'Min');
          final max = _findDoubleIn(levelEl.first, 'Max');
          if (min != null && max != null) wdrLevel = FloatRange(min, max);
        }
      }

      final wbEl = doc.findAllElements('WhiteBalance', namespace: '*');
      final whiteBalanceModes = wbEl.isEmpty
          ? const <String>[]
          : wbEl.first
              .findAllElements('Mode', namespace: '*')
              .map((e) => e.innerText.trim())
              .toList();

      final exposureEl = doc.findAllElements('Exposure', namespace: '*');
      var exposureModes = const <String>[];
      FloatRange? exposureTime;
      FloatRange? exposureGain;
      if (exposureEl.isNotEmpty) {
        exposureModes = exposureEl.first
            .findAllElements('Mode', namespace: '*')
            .map((e) => e.innerText.trim())
            .toList();
        final timeEl = exposureEl.first.findAllElements('ExposureTime', namespace: '*');
        if (timeEl.isNotEmpty) {
          final min = _findDoubleIn(timeEl.first, 'Min');
          final max = _findDoubleIn(timeEl.first, 'Max');
          if (min != null && max != null) exposureTime = FloatRange(min, max);
        }
        final gainEl = exposureEl.first.findAllElements('Gain', namespace: '*');
        if (gainEl.isNotEmpty) {
          final min = _findDoubleIn(gainEl.first, 'Min');
          final max = _findDoubleIn(gainEl.first, 'Max');
          if (min != null && max != null) exposureGain = FloatRange(min, max);
        }
      }

      final irCutFilterModes = doc
          .findAllElements('IrCutFilterModes', namespace: '*')
          .map((e) => e.innerText.trim())
          .toList();

      return ImagingOptions(
        brightness: range('Brightness'),
        colorSaturation: range('ColorSaturation'),
        contrast: range('Contrast'),
        sharpness: range('Sharpness'),
        wdrLevel: wdrLevel,
        wdrSupported: wdrEl.isNotEmpty,
        whiteBalanceModes: whiteBalanceModes,
        exposureModes: exposureModes,
        exposureTime: exposureTime,
        exposureGain: exposureGain,
        irCutFilterModes: irCutFilterModes,
      );
    });
    return result;
  }

  /// Applies only the non-null fields in [settings] — matches the firmware's own
  /// optional-field/apply-only-what-changed semantics (`onvif_imaging.c`'s
  /// `ONVIF_PARSER_OPTIONAL_*_VAL` sentinel checks).
  Future<CameraResult<void>> setImagingSettings(
    ImagingSettings settings, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final buf = StringBuffer();
    if (settings.brightness != null) {
      buf.write('<tt:Brightness>${settings.brightness}</tt:Brightness>');
    }
    if (settings.colorSaturation != null) {
      buf.write('<tt:ColorSaturation>${settings.colorSaturation}</tt:ColorSaturation>');
    }
    if (settings.contrast != null) {
      buf.write('<tt:Contrast>${settings.contrast}</tt:Contrast>');
    }
    if (settings.sharpness != null) {
      buf.write('<tt:Sharpness>${settings.sharpness}</tt:Sharpness>');
    }
    if (settings.irCutFilterMode != null) {
      buf.write('<tt:IrCutFilter>${settings.irCutFilterMode}</tt:IrCutFilter>');
    }
    if (settings.wdrMode != null) {
      buf.write('<tt:WideDynamicRange><tt:Mode>${settings.wdrMode}</tt:Mode>');
      if (settings.wdrLevel != null) {
        buf.write('<tt:Level>${settings.wdrLevel}</tt:Level>');
      }
      buf.write('</tt:WideDynamicRange>');
    } else if (settings.wdrLevel != null) {
      buf.write('<tt:WideDynamicRange><tt:Level>${settings.wdrLevel}</tt:Level></tt:WideDynamicRange>');
    }
    if (settings.exposureMode != null) {
      buf.write('<tt:Exposure><tt:Mode>${settings.exposureMode}</tt:Mode>');
      if (settings.exposureTime != null) {
        buf.write('<tt:ExposureTime>${settings.exposureTime}</tt:ExposureTime>');
      }
      if (settings.exposureGain != null) {
        buf.write('<tt:Gain>${settings.exposureGain}</tt:Gain>');
      }
      buf.write('</tt:Exposure>');
    }
    if (settings.whiteBalanceMode != null) {
      buf.write('<tt:WhiteBalance><tt:Mode>${settings.whiteBalanceMode}</tt:Mode></tt:WhiteBalance>');
    }

    final bodyResult = await _post(
      '<timg:SetImagingSettings xmlns:timg="http://www.onvif.org/ver20/imaging/wsdl" '
      'xmlns:tt="http://www.onvif.org/ver10/schema">'
      '<timg:VideoSourceToken>$_kVideoSourceToken</timg:VideoSourceToken>'
      '<timg:ImagingSettings>$buf</timg:ImagingSettings>'
      '<timg:ForcePersistence>true</timg:ForcePersistence>'
      '</timg:SetImagingSettings>',
      timeout,
    );
    return bodyResult.map((_) {});
  }

  Future<CameraResult<String>> _post(String bodyXml, Duration timeout) async {
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
            connection.onvifImagingEndpoint,
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
    } on Exception catch (e) {
      return CameraFailure(e.toString());
    }
  }

  String? _findText(XmlDocument doc, String tag) {
    final el = doc.findAllElements(tag, namespace: '*');
    return el.isEmpty ? null : el.first.innerText.trim();
  }

  double? _findDouble(XmlDocument doc, String tag) {
    final text = _findText(doc, tag);
    return text == null ? null : double.tryParse(text);
  }

  String? _findTextIn(XmlElement parent, String tag) {
    final el = parent.findAllElements(tag, namespace: '*');
    return el.isEmpty ? null : el.first.innerText.trim();
  }

  double? _findDoubleIn(XmlElement parent, String tag) {
    final text = _findTextIn(parent, tag);
    return text == null ? null : double.tryParse(text);
  }

  void close() => _http.close();
}

extension _ResultMap<T> on CameraResult<T> {
  CameraResult<R> map<R>(R Function(T value) f) {
    return switch (this) {
      CameraSuccess(:final value) => CameraSuccess<R>(f(value)),
      CameraFailure(:final reason) => CameraFailure<R>(reason),
      CameraTimeout() => CameraTimeout<R>(),
    };
  }
}
