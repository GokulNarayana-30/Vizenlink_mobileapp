import 'package:camera_api/camera_api.dart';

/// WAN counterpart to `OsdClient` (`camera_api`'s LAN ONVIF Media client for the timestamp/
/// camera-name OSD overlays) — `GetOsdConfigs`/`SetOsdConfig`/`DeleteOsdConfig`/`GetOsdOptions`
/// (commands `45`-`48`), added for the 2026-08-05 options-parity audit
/// (`kb/raw/2026-08-05-code-options-parity-rule-audit.md`) — OSD had zero WAN support before
/// this. Reuses `OsdEntry`/`OsdColor`/`OsdOptions` from `camera_api`. Scoped to exactly the two
/// OSD text-string types `OsdClient` itself models (`Plain` = camera name, `DateAndTime` =
/// timestamp) — same restriction, not the full ONVIF OSD schema.
class WanOsdClient {
  WanOsdClient(String thingName, {IotCommandClient? iotCommandClient})
    : _iot = iotCommandClient ?? IotCommandClient(thingName);

  final IotCommandClient _iot;

  Future<CameraResult<List<OsdEntry>>> getOsds({
    Duration timeout = const Duration(seconds: 15),
    bool retryOnTimeout = true,
  }) async {
    try {
      final output = await _iot.sendCommandWithResponse(
        IotCommandClient.getOsdConfigs,
        timeoutSeconds: timeout.inMilliseconds / 1000,
        retryOnTimeout: retryOnTimeout,
      );
      if (output == null) return const CameraTimeout();
      final osds = output['osds'];
      if (osds is! List) {
        return CameraFailure('GetOsdConfigs response missing fields: $output');
      }
      final entries = <OsdEntry>[
        for (final o in osds)
          if (o is Map && o['token'] is String && o['text_type'] is String)
            OsdEntry(
              token: o['token'] as String,
              textType: o['text_type'] as String,
              plainText: o['text'] as String?,
              posType: o['pos_type'] as String?,
              posX: (o['pos_x'] as num?)?.toDouble(),
              posY: (o['pos_y'] as num?)?.toDouble(),
              dateFormat: o['date_format'] as String?,
              timeFormat: o['time_format'] as String?,
              fontColor: _parseColor(o['font_color']),
            ),
      ];
      return CameraSuccess(entries);
    } catch (e) {
      return CameraFailure(e.toString());
    }
  }

  Future<CameraResult<OsdOptions>> getOsdOptions({
    Duration timeout = const Duration(seconds: 15),
    bool retryOnTimeout = true,
  }) async {
    try {
      final output = await _iot.sendCommandWithResponse(
        IotCommandClient.getOsdOptions,
        timeoutSeconds: timeout.inMilliseconds / 1000,
        retryOnTimeout: retryOnTimeout,
      );
      if (output == null) return const CameraTimeout();
      final fontColors = output['font_colors'];
      if (fontColors is! List) {
        return CameraFailure('GetOsdOptions response missing fields: $output');
      }
      final positionTypes = output['position_types'];
      final dateFormats = output['date_formats'];
      final timeFormats = output['time_formats'];
      return CameraSuccess(
        OsdOptions(
          fontSizeMin: (output['font_size_min'] as num?)?.toInt() ?? 8,
          fontSizeMax: (output['font_size_max'] as num?)?.toInt() ?? 24,
          fontColors: [
            for (final c in fontColors)
              if (c is Map &&
                  c['x'] is num &&
                  c['y'] is num &&
                  c['z'] is num &&
                  c['colorspace'] is String)
                OsdColor(
                  x: (c['x'] as num).toDouble(),
                  y: (c['y'] as num).toDouble(),
                  z: (c['z'] as num).toDouble(),
                  colorspace: c['colorspace'] as String,
                ),
          ],
          fontColorRangeAvailable: output['font_color_range_available'] == true,
          positionTypes: positionTypes is List
              ? positionTypes.whereType<String>().toList()
              : const [],
          dateFormats: dateFormats is List
              ? dateFormats.whereType<String>().toList()
              : const [],
          timeFormats: timeFormats is List
              ? timeFormats.whereType<String>().toList()
              : const [],
        ),
      );
    } catch (e) {
      return CameraFailure(e.toString());
    }
  }

  OsdColor? _parseColor(dynamic c) {
    if (c is! Map ||
        c['x'] is! num ||
        c['y'] is! num ||
        c['z'] is! num ||
        c['colorspace'] is! String) {
      return null;
    }
    return OsdColor(
      x: (c['x'] as num).toDouble(),
      y: (c['y'] as num).toDouble(),
      z: (c['z'] as num).toDouble(),
      colorspace: c['colorspace'] as String,
    );
  }

  /// [token] empty/omitted creates a new OSD (free slot of [textType]); non-empty updates the
  /// existing OSD with that token. [text] required when [textType] is `'Plain'`. [posType]
  /// defaults to `'Custom'`; [posX]/[posY] only sent when [posType] is `'Custom'` — a fixed
  /// corner carries no coordinates on the wire (matches `OsdClient`'s LAN convention).
  /// [dateFormat]/[timeFormat] only meaningful when [textType] is `'DateAndTime'`. Returns the
  /// applied OSD's token on success.
  Future<CameraResult<String>> setOsd({
    String token = '',
    required String textType,
    String? text,
    String posType = 'Custom',
    double? posX,
    double? posY,
    String? dateFormat,
    String? timeFormat,
    OsdColor? fontColor,
    Duration timeout = const Duration(seconds: 15),
    bool retryOnTimeout = true,
  }) async {
    try {
      final output = await _iot.sendCommandWithResponse(
        IotCommandClient.setOsdConfig,
        params: {
          if (token.isNotEmpty) 'token': token,
          'text_type': textType,
          'text': ?text,
          'pos_type': posType,
          if (posType == 'Custom' && posX != null) 'pos_x': posX,
          if (posType == 'Custom' && posY != null) 'pos_y': posY,
          'date_format': ?dateFormat,
          'time_format': ?timeFormat,
          if (fontColor != null)
            'font_color': {
              'x': fontColor.x,
              'y': fontColor.y,
              'z': fontColor.z,
              'colorspace': fontColor.colorspace,
            },
        },
        timeoutSeconds: timeout.inMilliseconds / 1000,
        retryOnTimeout: retryOnTimeout,
      );
      if (output == null) return const CameraTimeout();
      final resultToken = output['token'];
      return CameraSuccess(resultToken is String ? resultToken : token);
    } catch (e) {
      return CameraFailure(e.toString());
    }
  }

  Future<CameraResult<void>> deleteOsd(
    String token, {
    Duration timeout = const Duration(seconds: 15),
    bool retryOnTimeout = true,
  }) async {
    try {
      final output = await _iot.sendCommandWithResponse(
        IotCommandClient.deleteOsdConfig,
        params: {'token': token},
        timeoutSeconds: timeout.inMilliseconds / 1000,
        retryOnTimeout: retryOnTimeout,
      );
      if (output == null) return const CameraTimeout();
      return const CameraSuccess(null);
    } catch (e) {
      return CameraFailure(e.toString());
    }
  }
}
