import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';

import '../../camera_connection.dart';
import '../../camera_result.dart';
import '../../util/onvif_rect_coordinates.dart';
import '../insecure_camera_http_client.dart';
import 'onvif_device_client.dart';
import '../wsse_digest.dart';
import 'soap_fault.dart';

const _kVideoSourceConfigToken = 'VideoSourceCfg_1';
const _kMedia2Namespace = 'http://www.onvif.org/ver20/media/wsdl';

/// One currently-configured privacy mask, as reported by ONVIF Media2 `GetMasks`.
class MaskEntry {
  const MaskEntry({
    required this.token,
    required this.vsrcCfgToken,
    required this.polygon,
    required this.type,
    required this.enabled,
    this.colorX,
    this.colorY,
    this.colorZ,
    this.colorspace,
  });

  final String token;
  final String vsrcCfgToken;
  final List<OnvifPoint> polygon;

  /// `"Color"`, `"Pixelated"`, or `"Blurred"` — accepted and echoed by ONVIF, but only `"Color"`
  /// (a fixed black rectangle) is actually applied to the video on this camera today
  /// (`bsp_camera_ameba.c`'s `fast_mask.color` is hardcoded, never read from this field) —
  /// `MaskOptions.types`/`colorList` (below) are what a client should actually gate UI on.
  final String type;
  final bool enabled;
  final double? colorX;
  final double? colorY;
  final double? colorZ;
  final String? colorspace;
}

class MaskColor {
  const MaskColor({required this.x, required this.y, required this.z, required this.colorspace});
  final double x;
  final double y;
  final double z;

  /// `"RGB"` or `"YCbCr"` — the raw ONVIF `Colorspace` wire value.
  final String colorspace;

  @override
  bool operator ==(Object other) =>
      other is MaskColor &&
      x == other.x &&
      y == other.y &&
      z == other.z &&
      colorspace == other.colorspace;

  @override
  int get hashCode => Object.hash(x, y, z, colorspace);
}

/// The camera's mask capability envelope, from `GetMaskOptions` — the source a mask editor
/// should query before rendering type/color pickers (`FR-MOB-093`): render a picker only when
/// more than one value is reported, never assume from `MaskEntry`'s own `type`/`color` fields
/// alone.
class MaskOptions {
  const MaskOptions({
    required this.rectangleOnly,
    required this.singleColorOnly,
    required this.maxMasks,
    required this.maxPoints,
    required this.types,
    required this.colorList,
  });

  final bool rectangleOnly;
  final bool singleColorOnly;
  final int maxMasks;
  final int maxPoints;
  final List<String> types;
  final List<MaskColor> colorList;
}

/// LAN-only ONVIF Media2 client for `CreateMask`/`SetMask`/`DeleteMask`/`GetMasks`/
/// `GetMaskOptions` (`FR-MOB-093`'s privacy mask editor). Always sends a 4-point rectangle
/// polygon (`pixelRectToOnvifPolygon`) and, per `MaskOptions`' capability-driven-visibility
/// rule, the camera's own single reported type/color when it reports only one of either —
/// never a value the UI invented.
///
/// Endpoint resolved via `OnvifDeviceClient.getServices()` (real ONVIF service discovery,
/// not a hardcoded path) — same pattern `Media2CapabilitiesClient` established.
/// **Process-lifetime caching of the resolved endpoint and `GetMaskOptions` response now lives
/// in the app layer** (`mobile_app/lib/features/settings/camera_settings_cache.dart`'s
/// `NetworkAnswerCache`), not in this class — moved 2026-08-28 per direct user decision that
/// `camera_api` should be "clean... just network client only." `MaskEditorCardState` constructs
/// a brand-new `MaskClient` every time the editor screen mounts; the app now passes a
/// previously-cached endpoint into the `endpoint` constructor parameter (see
/// [resolvedEndpoint]'s doc) so that still avoids a redundant `GetServices` round trip on every
/// screen open — same real-world motivation as before: on this camera the HTTPD task runs at
/// the highest FreeRTOS priority tier (see `.claude/rules/camera-firmware.md` § Task priority
/// convention), so a burst of redundant ONVIF requests during mask editing visibly starved the
/// RTSP/NVR video pipeline, not just slowed the mobile app UI. The app-level cache also fixes a
/// real bug the old client-side static cache had no way to fix: no invalidation hook on camera
/// removal, so a stale/incorrect cached answer could survive a remove-and-re-add.
///
/// **Not yet hardware-verified** — no `testing_utilities/*.py` reference script exists for
/// mask CRUD; this wire format is matched directly against `onvif_media2.c`/`onvif_parser.c`
/// source, same higher-risk caveat `OsdClient`'s own doc carries.
class MaskClient {
  MaskClient(this.connection, {http.Client? httpClient, Uri? endpoint})
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

  Future<CameraResult<List<MaskEntry>>> getMasks({
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final bodyResult = await _post(
      '<tr2:GetMasks xmlns:tr2="$_kMedia2Namespace"/>',
      timeout,
    );
    return bodyResult.map((body) {
      final doc = XmlDocument.parse(body);
      final entries = <MaskEntry>[];
      for (final el in doc.findAllElements('Masks', namespace: '*')) {
        final token = el.getAttribute('token');
        if (token == null || token.isEmpty) continue;
        final cfgTokenEl = el.findElements('ConfigurationToken', namespace: '*');
        final typeEl = el.findElements('Type', namespace: '*');
        final enabledEl = el.findElements('Enabled', namespace: '*');
        if (typeEl.isEmpty || enabledEl.isEmpty) continue;

        final points = <OnvifPoint>[];
        for (final polygonEl in el.findElements('Polygon', namespace: '*')) {
          for (final pointEl in polygonEl.findElements('Point', namespace: '*')) {
            final x = double.tryParse(pointEl.getAttribute('x') ?? '');
            final y = double.tryParse(pointEl.getAttribute('y') ?? '');
            if (x != null && y != null) points.add(OnvifPoint(x, y));
          }
        }

        final colorEl = el.findElements('Color', namespace: '*');
        entries.add(
          MaskEntry(
            token: token,
            vsrcCfgToken: cfgTokenEl.isEmpty ? '' : cfgTokenEl.first.innerText.trim(),
            polygon: points,
            type: typeEl.first.innerText.trim(),
            enabled: enabledEl.first.innerText.trim() == 'true',
            colorX: colorEl.isEmpty ? null : double.tryParse(colorEl.first.getAttribute('X') ?? ''),
            colorY: colorEl.isEmpty ? null : double.tryParse(colorEl.first.getAttribute('Y') ?? ''),
            colorZ: colorEl.isEmpty ? null : double.tryParse(colorEl.first.getAttribute('Z') ?? ''),
            colorspace: colorEl.isEmpty ? null : colorEl.first.getAttribute('Colorspace'),
          ),
        );
      }
      return entries;
    });
  }

  /// Always a live network call — no caching in this package (see
  /// `.claude/rules/mobile-app-screen-conventions.md`'s "Caching capability/service-discovery
  /// responses" convention; the app layer caches this in `camera_settings_cache.dart`'s
  /// `NetworkAnswerCache`).
  Future<CameraResult<MaskOptions>> getMaskOptions({
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final bodyResult = await _post(
      '<tr2:GetMaskOptions xmlns:tr2="$_kMedia2Namespace">'
      '<tr2:ConfigurationToken>$_kVideoSourceConfigToken</tr2:ConfigurationToken>'
      '</tr2:GetMaskOptions>',
      timeout,
    );
    final result = bodyResult.map((body) {
      final doc = XmlDocument.parse(body);
      final optionsEl = doc.findAllElements('Options', namespace: '*');
      if (optionsEl.isEmpty) {
        return const MaskOptions(
          rectangleOnly: true,
          singleColorOnly: true,
          maxMasks: 0,
          maxPoints: 4,
          types: [],
          colorList: [],
        );
      }
      final el = optionsEl.first;
      final maxMasksEl = el.findElements('MaxMasks', namespace: '*');
      final maxPointsEl = el.findElements('MaxPoints', namespace: '*');
      final types = el
          .findElements('Types', namespace: '*')
          .map((e) => e.innerText.trim())
          .toList(growable: false);
      final colorList = <MaskColor>[];
      for (final colorOptEl in el.findElements('Color', namespace: '*')) {
        for (final listEl in colorOptEl.findElements('ColorList', namespace: '*')) {
          final x = double.tryParse(listEl.getAttribute('X') ?? '');
          final y = double.tryParse(listEl.getAttribute('Y') ?? '');
          final z = double.tryParse(listEl.getAttribute('Z') ?? '');
          final cs = listEl.getAttribute('Colorspace');
          if (x != null && y != null && z != null && cs != null) {
            colorList.add(MaskColor(x: x, y: y, z: z, colorspace: cs));
          }
        }
      }
      return MaskOptions(
        rectangleOnly: el.getAttribute('RectangleOnly') == 'true',
        singleColorOnly: el.getAttribute('SingleColorOnly') == 'true',
        maxMasks: maxMasksEl.isEmpty ? 0 : int.tryParse(maxMasksEl.first.innerText.trim()) ?? 0,
        maxPoints: maxPointsEl.isEmpty ? 4 : int.tryParse(maxPointsEl.first.innerText.trim()) ?? 4,
        types: types,
        colorList: colorList,
      );
    });
    return result;
  }

  Future<CameraResult<String>> createMask({
    required List<OnvifPoint> polygon,
    required bool enabled,
    required String type,
    MaskColor? color,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final bodyResult = await _post(
      '<tr2:CreateMask xmlns:tr2="$_kMedia2Namespace" xmlns:tt="http://www.onvif.org/ver10/schema">'
      '${_maskXml(token: '', polygon: polygon, enabled: enabled, type: type, color: color)}'
      '</tr2:CreateMask>',
      timeout,
    );
    return bodyResult.map((body) {
      final doc = XmlDocument.parse(body);
      final tokenEl = doc.findAllElements('Token', namespace: '*');
      return tokenEl.isEmpty ? '' : tokenEl.first.innerText.trim();
    });
  }

  Future<CameraResult<void>> setMask({
    required String token,
    required List<OnvifPoint> polygon,
    required bool enabled,
    required String type,
    MaskColor? color,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final bodyResult = await _post(
      '<tr2:SetMask xmlns:tr2="$_kMedia2Namespace" xmlns:tt="http://www.onvif.org/ver10/schema">'
      '${_maskXml(token: token, polygon: polygon, enabled: enabled, type: type, color: color)}'
      '</tr2:SetMask>',
      timeout,
    );
    return bodyResult.map((_) {});
  }

  Future<CameraResult<void>> deleteMask(
    String token, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final bodyResult = await _post(
      '<tr2:DeleteMask xmlns:tr2="$_kMedia2Namespace">'
      '<tr2:Token>$token</tr2:Token>'
      '</tr2:DeleteMask>',
      timeout,
    );
    return bodyResult.map((_) {});
  }

  String _maskXml({
    required String token,
    required List<OnvifPoint> polygon,
    required bool enabled,
    required String type,
    MaskColor? color,
  }) {
    final pointsXml = polygon.map((p) => '<tt:Point x="${p.x}" y="${p.y}"/>').join();
    final colorXml = color == null
        ? ''
        : '<tr2:Color X="${color.x}" Y="${color.y}" Z="${color.z}" '
              'Colorspace="${color.colorspace}"/>';
    return '<tr2:Mask token="$token">'
        '<tr2:ConfigurationToken>$_kVideoSourceConfigToken</tr2:ConfigurationToken>'
        '<tr2:Polygon>$pointsXml</tr2:Polygon>'
        '<tr2:Type>$type</tr2:Type>'
        '$colorXml'
        '<tr2:Enabled>$enabled</tr2:Enabled>'
        '</tr2:Mask>';
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
    } on Exception catch (e) {
      return CameraFailure(e.toString());
    }
  }

  void close() {
    _http.close();
    _device.close();
  }
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
