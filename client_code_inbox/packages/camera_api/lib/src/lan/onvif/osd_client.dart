import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';

import '../../camera_connection.dart';
import '../../camera_result.dart';
import '../insecure_camera_http_client.dart';
import 'onvif_device_client.dart';
import '../wsse_digest.dart';
import 'soap_fault.dart';

const _kVideoSourceConfigToken = 'VideoSourceCfg_1';
const _kMedia2Namespace = 'http://www.onvif.org/ver20/media/wsdl';

/// `'Custom'` (draggable, `x`/`y` in `[-1, 1]`) or one of the fixed corner presets
/// (`'UpperLeft'`/`'UpperRight'`/`'LowerLeft'`/`'LowerRight'`) — the ONVIF `tt:Position/tt:Type`
/// wire value, per `onvif_types.h`'s `OnvifOSDPositionTypeEnum`.
const kOsdPositionCustom = 'Custom';
const kOsdPositionUpperLeft = 'UpperLeft';
const kOsdPositionUpperRight = 'UpperRight';
const kOsdPositionLowerLeft = 'LowerLeft';
const kOsdPositionLowerRight = 'LowerRight';

/// `onvif_types.c`'s `paOSDDateFormatStrings`/`paOSDTimeFormatStrings` — the exact wire strings,
/// not display labels (e.g. `dd/MM/yyyy`, not "DD/MM/YYYY"). Kept here rather than derived from
/// `OsdOptions.dateFormats`/`timeFormats` alone since `createTimestampOsd`'s own factory-default
/// values need a source of truth independent of whatever `GetOSDOptions` happens to report.
const kOsdDefaultDateFormat = 'dd/MM/yyyy';
const kOsdDefaultTimeFormat = 'hh:mm:ss tt';

/// One currently-configured OSD entry as reported by `GetOSDs` — either the `DateAndTime`
/// (timestamp) slot or the `Plain` (Text OSD) slot. Only these two text-string types are
/// modeled since that's the entirety of `FR-MOB-073`'s scope (timestamp + free-text overlay);
/// `Date`/`Time`-only and `Image` OSD types exist in the ONVIF schema but aren't exposed here.
/// **Not a "camera name" field** — `Plain` is a generic free-text slot the app defaults to the
/// camera's name, distinct from `FR-MOB-096`'s actual device-identity Camera Name setting.
class OsdEntry {
  const OsdEntry({
    required this.token,
    required this.textType,
    this.plainText,
    this.posType,
    this.posX,
    this.posY,
    this.dateFormat,
    this.timeFormat,
    this.fontColor,
  });
  final String token;

  /// `'DateAndTime'` or `'Plain'` — the raw ONVIF `tt:TextString/tt:Type` wire value.
  final String textType;
  final String? plainText;

  /// `kOsdPositionCustom`/`kOsdPositionUpperLeft`/etc — `null` if the camera reported a position
  /// type this client doesn't recognize.
  final String? posType;

  /// Current position, each in `[-1, 1]` (`FR-MOB-095`) — `null` unless [posType] is
  /// [kOsdPositionCustom] (fixed corners carry no `Pos` on the wire at all).
  final double? posX;
  final double? posY;

  /// Wire-format date/time format strings (e.g. `dd/MM/yyyy`, `hh:mm:ss tt`) — only present for
  /// the `DateAndTime` entry.
  final String? dateFormat;
  final String? timeFormat;

  final OsdColor? fontColor;
}

class OsdColor {
  const OsdColor({required this.x, required this.y, required this.z, required this.colorspace});
  final double x;
  final double y;
  final double z;
  final String colorspace;

  @override
  bool operator ==(Object other) =>
      other is OsdColor &&
      x == other.x &&
      y == other.y &&
      z == other.z &&
      colorspace == other.colorspace;

  @override
  int get hashCode => Object.hash(x, y, z, colorspace);
}

/// The camera's OSD capability envelope, from `GetOSDOptions` (`FR-MOB-095`) — the source the
/// overlay editor queries before rendering pickers: position type, date/time format, and font
/// color controls are each only shown when the camera reports more than one choice / a usable
/// range, never guessed.
class OsdOptions {
  const OsdOptions({
    required this.fontSizeMin,
    required this.fontSizeMax,
    required this.fontColors,
    required this.fontColorRangeAvailable,
    required this.positionTypes,
    required this.dateFormats,
    required this.timeFormats,
  });
  final int fontSizeMin;
  final int fontSizeMax;

  /// Discrete color choices, if the camera reports a `ColorList` — empty on this firmware, which
  /// reports a continuous [fontColorRangeAvailable] range instead (see that field's doc).
  final List<OsdColor> fontColors;

  /// `true` when `GetOSDOptions` reports a `ColorspaceRange` (this firmware always does, RGB
  /// `[0,1]` on every channel) — added 2026-08-05, direct user report that there was no text
  /// color UI at all. Root cause: this client previously only parsed discrete `ColorList`
  /// entries into [fontColors]; this firmware's `onvif_server_config.c` configures a
  /// `colorspace_range` (a continuous range), not a discrete list (`color_count: 0`), so
  /// [fontColors] was always empty and the swatch-row UI that gated on it never rendered. A
  /// continuous range calls for a slider-based RGB picker, not a fixed swatch list — see
  /// `osd_settings_screen.dart`'s `_RgbColorPicker`.
  final bool fontColorRangeAvailable;

  /// Every position type the camera reports as valid (`kOsdPositionCustom`/`kOsdPositionUpperLeft`
  /// /etc) — added 2026-08-05, direct user report that dragging was the only option shown even
  /// though the ONVIF stack (and this camera's BSP, `osd_helper.c`'s `prvConvertOnvifOSDPosition`)
  /// fully supports the 4 fixed corners too. Root cause: `onvif_server_config.c`'s OSD options
  /// only configured `Custom`, so `GetOSDOptions` never reported the others — fixed firmware-side
  /// (`[AI Fix]` in that file) alongside this client gaining the ability to read/send them.
  final List<String> positionTypes;

  /// Wire-format date/time format strings the camera accepts (e.g. `dd/MM/yyyy`) — only
  /// meaningful for the `DateAndTime` OSD slot.
  final List<String> dateFormats;
  final List<String> timeFormats;
}

/// LAN-only ONVIF **Media2** client for `GetOSDs`/`CreateOSD`/`SetOSD`/`DeleteOSD`/
/// `GetOSDOptions` (`FR-OV-100`) — `FR-MOB-073`'s timestamp-on/off and Text-OSD control, plus
/// (2026-08-05) position type (fixed corner or draggable), date/time format, and font color —
/// see [OsdOptions]' doc for why those three were previously missing from the UI entirely.
///
/// **Migrated from Media v1 to Media2 2026-08-11** — direct user report ("still mobile app
/// using ONVIF media_service, not media2... for audio settings and few others"). `AudioVolumeClient`
/// followed the same day, once `FR-OV-101` closed a real Media2 gap (`SetAudioOutputConfiguration`/
/// `GetAudioOutputConfigurationOptions` existed only in Media v1 until then — an earlier claim
/// here that Media2 has no audio operations *at all* was wrong, corrected against the real
/// `ver20/media/wsdl/media.wsdl`: `GetAudioSourceConfigurations`/`GetAudioOutputConfigurations`
/// were already implemented in Media2). `AudioCapabilityClient` is the one client that
/// genuinely must stay on Media v1 — `GetAudioSources`/`GetAudioOutputs` (physical hardware
/// enumeration, not configuration) really don't exist in Media2 per the WSDL. OSD has
/// full parity in this firmware: `onvif_media2.c` implements `GetOSDs`/`CreateOSD`/`SetOSD`/
/// `DeleteOSD`/`GetOSDOptions` by calling the exact same shared parser/generator functions
/// (`onvif_parser_parseOSDConfig`, `onvif_media_osd_generateOSDSnippet`/
/// `generateOSDOptionsSnippet`) that Media v1's own handlers use — confirmed by reading both
/// `onvif_media.c` and `onvif_media2.c` side by side — so the wire schema for every element/
/// attribute here is byte-identical between the two, only the SOAP action namespace/prefix
/// differs (`trt:`/`ver10` vs `tr2:`/`ver20`). This is also what the WAN path
/// (`nuraeye.c`'s `SetOsdConfig`, `FR-NE-103`) is already built around
/// (`onvif_media2_osd_applyNewConfig`), so this migration makes LAN and WAN consistent with
/// each other too, not just with `MaskClient`/`OnvifVideoEncoderClient`'s existing Media2-only
/// convention.
///
/// The camera ships with **both** OSD slots already `used: true` by default
/// (`onvif_user_config.c`: `OSDCfg_2` = DateAndTime at position (0.8, 1), `OSDCfg_1` = Plain at
/// (-1, 1)) — so `getOsds()` normally returns both entries already populated; "off" is modeled
/// as `DeleteOSD` (frees the slot back to unused) and re-enabling after that is `CreateOSD`
/// (same slot type, a fresh token).
///
/// No `testing_utilities/*.py` reference script exists for OSD yet (unlike every other client in
/// this package — see `.claude/rules/mobile-app.md`'s "Implementing camera_api clients" rule) —
/// this wire format is instead matched directly against `onvif_media_osd.c`'s
/// `generateOSDSnippet`/`onvif_parser_parseOSDConfig` and `onvif_user_config.c`'s default
/// config, read directly from firmware source. **Flagged as not yet hardware-verified against a
/// real camera for this reason** — a higher-risk gap than this package's other clients.
class OsdClient {
  OsdClient(this.connection, {http.Client? httpClient, Uri? endpoint})
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

  Future<CameraResult<List<OsdEntry>>> getOsds({
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final bodyResult = await _post(
      '<tr2:GetOSDs xmlns:tr2="http://www.onvif.org/ver20/media/wsdl">'
      '<tr2:ConfigurationToken>$_kVideoSourceConfigToken</tr2:ConfigurationToken>'
      '</tr2:GetOSDs>',
      timeout,
    );
    return bodyResult.map((body) {
      final doc = XmlDocument.parse(body);
      final entries = <OsdEntry>[];
      for (final el in doc.findAllElements('OSDs', namespace: '*')) {
        final token = el.getAttribute('token');
        if (token == null || token.isEmpty) continue;
        final textStringEl = el.findAllElements('TextString', namespace: '*');
        if (textStringEl.isEmpty) continue;
        final typeEl = textStringEl.first.findAllElements('Type', namespace: '*');
        if (typeEl.isEmpty) continue;
        final textType = typeEl.first.innerText.trim();
        final plainEl = textStringEl.first.findAllElements('PlainText', namespace: '*');
        final dateFormatEl = textStringEl.first.findAllElements('DateFormat', namespace: '*');
        final timeFormatEl = textStringEl.first.findAllElements('TimeFormat', namespace: '*');

        final positionEl = el.findAllElements('Position', namespace: '*');
        String? posType;
        double? posX;
        double? posY;
        if (positionEl.isNotEmpty) {
          final posTypeEl = positionEl.first.findAllElements('Type', namespace: '*');
          posType = posTypeEl.isEmpty ? null : posTypeEl.first.innerText.trim();
          final posEl = positionEl.first.findAllElements('Pos', namespace: '*');
          if (posEl.isNotEmpty) {
            posX = double.tryParse(posEl.first.getAttribute('x') ?? '');
            posY = double.tryParse(posEl.first.getAttribute('y') ?? '');
          }
        }

        final fontColorEl = textStringEl.first.findAllElements('FontColor', namespace: '*');
        OsdColor? fontColor;
        if (fontColorEl.isNotEmpty) {
          final colorEl = fontColorEl.first.findAllElements('Color', namespace: '*');
          if (colorEl.isNotEmpty) {
            final x = double.tryParse(colorEl.first.getAttribute('X') ?? '');
            final y = double.tryParse(colorEl.first.getAttribute('Y') ?? '');
            final z = double.tryParse(colorEl.first.getAttribute('Z') ?? '');
            final cs = colorEl.first.getAttribute('Colorspace');
            if (x != null && y != null && z != null && cs != null) {
              fontColor = OsdColor(x: x, y: y, z: z, colorspace: cs);
            }
          }
        }

        entries.add(
          OsdEntry(
            token: token,
            textType: textType,
            plainText: plainEl.isEmpty ? null : plainEl.first.innerText,
            posType: posType,
            posX: posX,
            posY: posY,
            dateFormat: dateFormatEl.isEmpty ? null : dateFormatEl.first.innerText.trim(),
            timeFormat: timeFormatEl.isEmpty ? null : timeFormatEl.first.innerText.trim(),
            fontColor: fontColor,
          ),
        );
      }
      return entries;
    });
  }

  /// `CreateOSD` for the `DateAndTime` (timestamp) slot. [posType] defaults to
  /// [kOsdPositionCustom]; [posX]/[posY] only sent (and only meaningful) when [posType] is
  /// [kOsdPositionCustom] — fixed corners carry no coordinates on the wire, `osd_helper.c`'s BSP
  /// layer computes the pixel position itself. [dateFormat]/[timeFormat] default to this app's
  /// existing factory-default format strings. Returns the new OSD token on success.
  Future<CameraResult<String>> createTimestampOsd({
    String posType = kOsdPositionCustom,
    double posX = 0.8,
    double posY = 1,
    String dateFormat = kOsdDefaultDateFormat,
    String timeFormat = kOsdDefaultTimeFormat,
    OsdColor? fontColor,
    Duration timeout = const Duration(seconds: 10),
  }) => _createOsd(
    textType: 'DateAndTime',
    posType: posType,
    posX: posX,
    posY: posY,
    fontColor: fontColor,
    extraTextFields:
        '<tt:DateFormat>${_escape(dateFormat)}</tt:DateFormat>'
        '<tt:TimeFormat>${_escape(timeFormat)}</tt:TimeFormat>',
    timeout: timeout,
  );

  /// `CreateOSD` for the `Plain` (Text OSD) slot. [posType] defaults to [kOsdPositionCustom];
  /// see [createTimestampOsd]'s doc for the position-type convention. Returns the new OSD token
  /// on success.
  Future<CameraResult<String>> createTextOsd(
    String text, {
    String posType = kOsdPositionCustom,
    double posX = -1,
    double posY = 1,
    OsdColor? fontColor,
    Duration timeout = const Duration(seconds: 10),
  }) => _createOsd(
    textType: 'Plain',
    posType: posType,
    posX: posX,
    posY: posY,
    fontColor: fontColor,
    extraTextFields: '<tt:PlainText>${_escape(text)}</tt:PlainText>',
    timeout: timeout,
  );

  Future<CameraResult<String>> _createOsd({
    required String textType,
    required String posType,
    required double posX,
    required double posY,
    required String extraTextFields,
    required Duration timeout,
    OsdColor? fontColor,
  }) async {
    final bodyResult = await _post(
      '<tr2:CreateOSD xmlns:tr2="http://www.onvif.org/ver20/media/wsdl" '
      'xmlns:tt="http://www.onvif.org/ver10/schema">'
      '<tr2:OSD token="">'
      '<tt:VideoSourceConfigurationToken>$_kVideoSourceConfigToken</tt:VideoSourceConfigurationToken>'
      '<tt:Type>Text</tt:Type>'
      '${_positionXml(posType, posX, posY)}'
      '<tt:TextString IsPersistentText="true">'
      '<tt:FontSize>12</tt:FontSize>'
      '<tt:Type>$textType</tt:Type>'
      '${_fontColorXml(fontColor)}'
      '$extraTextFields'
      '</tt:TextString>'
      '</tr2:OSD>'
      '</tr2:CreateOSD>',
      timeout,
    );
    return bodyResult.map((body) {
      final doc = XmlDocument.parse(body);
      final tokenEl = doc.findAllElements('OSDToken', namespace: '*');
      return tokenEl.isEmpty ? '' : tokenEl.first.innerText.trim();
    });
  }

  /// `SetOSD` — updates the `Plain` OSD's text/position/color in place, keeping its existing
  /// [token]. Only used for the Text OSD field; the timestamp OSD has nothing else
  /// user-editable once created besides position/date-time-format/color (all handled by
  /// [updateTimestampPosition]/this method's DateAndTime counterpart).
  Future<CameraResult<void>> updateTextOsd(
    String token,
    String text, {
    String posType = kOsdPositionCustom,
    double posX = -1,
    double posY = 1,
    OsdColor? fontColor,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final bodyResult = await _post(
      '<tr2:SetOSD xmlns:tr2="http://www.onvif.org/ver20/media/wsdl" '
      'xmlns:tt="http://www.onvif.org/ver10/schema">'
      '<tr2:OSD token="$token">'
      '<tt:VideoSourceConfigurationToken>$_kVideoSourceConfigToken</tt:VideoSourceConfigurationToken>'
      '<tt:Type>Text</tt:Type>'
      '${_positionXml(posType, posX, posY)}'
      '<tt:TextString IsPersistentText="true">'
      '<tt:FontSize>12</tt:FontSize>'
      '<tt:Type>Plain</tt:Type>'
      '${_fontColorXml(fontColor)}'
      '<tt:PlainText>${_escape(text)}</tt:PlainText>'
      '</tt:TextString>'
      '</tr2:OSD>'
      '</tr2:SetOSD>',
      timeout,
    );
    return bodyResult.map((_) {});
  }

  /// `SetOSD` — updates the `DateAndTime` OSD's position/format/color in place, keeping its
  /// existing [token]. Counterpart to [updateTextOsd] for the timestamp slot.
  /// [dateFormat]/[timeFormat] default to this app's existing factory-default format strings —
  /// pass the value from a loaded [OsdEntry]/user selection to preserve/change it explicitly.
  Future<CameraResult<void>> updateTimestampPosition(
    String token, {
    String posType = kOsdPositionCustom,
    required double posX,
    required double posY,
    String dateFormat = kOsdDefaultDateFormat,
    String timeFormat = kOsdDefaultTimeFormat,
    OsdColor? fontColor,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final bodyResult = await _post(
      '<tr2:SetOSD xmlns:tr2="http://www.onvif.org/ver20/media/wsdl" '
      'xmlns:tt="http://www.onvif.org/ver10/schema">'
      '<tr2:OSD token="$token">'
      '<tt:VideoSourceConfigurationToken>$_kVideoSourceConfigToken</tt:VideoSourceConfigurationToken>'
      '<tt:Type>Text</tt:Type>'
      '${_positionXml(posType, posX, posY)}'
      '<tt:TextString IsPersistentText="true">'
      '<tt:FontSize>12</tt:FontSize>'
      '<tt:Type>DateAndTime</tt:Type>'
      '${_fontColorXml(fontColor)}'
      '<tt:DateFormat>${_escape(dateFormat)}</tt:DateFormat>'
      '<tt:TimeFormat>${_escape(timeFormat)}</tt:TimeFormat>'
      '</tt:TextString>'
      '</tr2:OSD>'
      '</tr2:SetOSD>',
      timeout,
    );
    return bodyResult.map((_) {});
  }

  String _positionXml(String posType, double posX, double posY) {
    final posXml = posType == kOsdPositionCustom ? '<tt:Pos x="$posX" y="$posY"/>' : '';
    return '<tt:Position><tt:Type>$posType</tt:Type>$posXml</tt:Position>';
  }

  String _fontColorXml(OsdColor? color) {
    if (color == null) return '';
    return '<tt:FontColor><tt:Color X="${color.x}" Y="${color.y}" Z="${color.z}" '
        'Colorspace="${color.colorspace}"/></tt:FontColor>';
  }

  /// `GetOSDOptions` — font size/color, position type, and date/time format bounds/choices
  /// (`FR-MOB-095`) — the capability source every picker on the OSD screen gates on: render one
  /// only when more than one choice (or a usable range) is reported. Always a live network
  /// call — no caching in this package (see `.claude/rules/mobile-app-screen-conventions.md`'s
  /// "Caching capability/service-discovery responses" convention; the app layer caches this in
  /// `camera_settings_cache.dart`'s `NetworkAnswerCache`).
  Future<CameraResult<OsdOptions>> getOsdOptions({
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final bodyResult = await _post(
      '<tr2:GetOSDOptions xmlns:tr2="http://www.onvif.org/ver20/media/wsdl">'
      '<tr2:ConfigurationToken>$_kVideoSourceConfigToken</tr2:ConfigurationToken>'
      '</tr2:GetOSDOptions>',
      timeout,
    );
    final result = bodyResult.map((body) {
      final doc = XmlDocument.parse(body);
      final rangeEl = doc.findAllElements('FontSizeRange', namespace: '*');
      final minEl = rangeEl.isEmpty ? null : rangeEl.first.findElements('Min', namespace: '*');
      final maxEl = rangeEl.isEmpty ? null : rangeEl.first.findElements('Max', namespace: '*');

      final fontColorEl = doc.findAllElements('FontColor', namespace: '*');
      final colors = <OsdColor>[];
      var rangeAvailable = false;
      if (fontColorEl.isNotEmpty) {
        for (final listEl in fontColorEl.first.findAllElements('ColorList', namespace: '*')) {
          final x = double.tryParse(listEl.getAttribute('X') ?? '');
          final y = double.tryParse(listEl.getAttribute('Y') ?? '');
          final z = double.tryParse(listEl.getAttribute('Z') ?? '');
          final cs = listEl.getAttribute('Colorspace');
          if (x != null && y != null && z != null && cs != null) {
            colors.add(OsdColor(x: x, y: y, z: z, colorspace: cs));
          }
        }
        rangeAvailable = fontColorEl.first.findAllElements('ColorspaceRange', namespace: '*').isNotEmpty;
      }

      final positionTypes = doc
          .findAllElements('PositionOption', namespace: '*')
          .map((e) => e.innerText.trim())
          .where((s) => s.isNotEmpty)
          .toList(growable: false);
      final dateFormats = doc
          .findAllElements('DateFormat', namespace: '*')
          .map((e) => e.innerText.trim())
          .where((s) => s.isNotEmpty)
          .toList(growable: false);
      final timeFormats = doc
          .findAllElements('TimeFormat', namespace: '*')
          .map((e) => e.innerText.trim())
          .where((s) => s.isNotEmpty)
          .toList(growable: false);

      return OsdOptions(
        fontSizeMin: (minEl == null || minEl.isEmpty)
            ? 8
            : int.tryParse(minEl.first.innerText.trim()) ?? 8,
        fontSizeMax: (maxEl == null || maxEl.isEmpty)
            ? 24
            : int.tryParse(maxEl.first.innerText.trim()) ?? 24,
        fontColors: colors,
        fontColorRangeAvailable: rangeAvailable,
        positionTypes: positionTypes,
        dateFormats: dateFormats,
        timeFormats: timeFormats,
      );
    });
    return result;
  }

  Future<CameraResult<void>> deleteOsd(
    String token, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final bodyResult = await _post(
      '<tr2:DeleteOSD xmlns:tr2="http://www.onvif.org/ver20/media/wsdl">'
      '<tr2:OSDToken>$token</tr2:OSDToken>'
      '</tr2:DeleteOSD>',
      timeout,
    );
    return bodyResult.map((_) {});
  }

  String _escape(String text) => text
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;');

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

extension _ResultMap<T> on CameraResult<T> {
  CameraResult<R> map<R>(R Function(T value) f) {
    return switch (this) {
      CameraSuccess(:final value) => CameraSuccess<R>(f(value)),
      CameraFailure(:final reason) => CameraFailure<R>(reason),
      CameraTimeout() => CameraTimeout<R>(),
    };
  }
}
