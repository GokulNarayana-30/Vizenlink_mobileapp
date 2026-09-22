import 'package:camera_api/camera_api.dart';

/// WAN counterpart to `MaskClient` (`camera_api`'s LAN ONVIF Media2 privacy-mask client) —
/// `GetMaskConfigs`/`SetMaskConfig`/`DeleteMaskConfig`/`GetMaskOptions` (commands `41`-`44`),
/// added for the 2026-08-05 options-parity audit
/// (`kb/raw/2026-08-05-code-options-parity-rule-audit.md`) — privacy masks had zero WAN support
/// before this. Reuses `MaskEntry`/`MaskColor`/`MaskOptions`/`OnvifPoint` from `camera_api` so
/// callers (`mask_editor_card.dart`) work with the same types regardless of transport, same
/// convention as `WanVideoEncoderClient` reusing `onvif_video_encoder_client.dart`'s types.
class WanMaskClient {
  WanMaskClient(String thingName, {IotCommandClient? iotCommandClient})
    : _iot = iotCommandClient ?? IotCommandClient(thingName);

  final IotCommandClient _iot;

  Future<CameraResult<List<MaskEntry>>> getMasks({
    Duration timeout = const Duration(seconds: 15),
    bool retryOnTimeout = true,
  }) async {
    try {
      final output = await _iot.sendCommandWithResponse(
        IotCommandClient.getMaskConfigs,
        timeoutSeconds: timeout.inMilliseconds / 1000,
        retryOnTimeout: retryOnTimeout,
      );
      if (output == null) return const CameraTimeout();
      final masks = output['masks'];
      if (masks is! List) {
        return CameraFailure('GetMaskConfigs response missing fields: $output');
      }
      final entries = <MaskEntry>[];
      for (final m in masks) {
        if (m is! Map) continue;
        final token = m['token'];
        final enabled = m['enabled'];
        final type = m['type'];
        final points = m['points'];
        if (token is! String ||
            enabled is! bool ||
            type is! String ||
            points is! List) {
          continue;
        }
        final polygon = <OnvifPoint>[
          for (final p in points)
            if (p is Map && p['x'] is num && p['y'] is num)
              OnvifPoint(
                (p['x'] as num).toDouble(),
                (p['y'] as num).toDouble(),
              ),
        ];
        final color = m['color'];
        entries.add(
          MaskEntry(
            token: token,
            vsrcCfgToken: '',
            polygon: polygon,
            type: type,
            enabled: enabled,
            colorX: (color is Map && color['x'] is num)
                ? (color['x'] as num).toDouble()
                : null,
            colorY: (color is Map && color['y'] is num)
                ? (color['y'] as num).toDouble()
                : null,
            colorZ: (color is Map && color['z'] is num)
                ? (color['z'] as num).toDouble()
                : null,
            colorspace: (color is Map) ? color['colorspace'] as String? : null,
          ),
        );
      }
      return CameraSuccess(entries);
    } catch (e) {
      return CameraFailure(e.toString());
    }
  }

  Future<CameraResult<MaskOptions>> getMaskOptions({
    Duration timeout = const Duration(seconds: 15),
    bool retryOnTimeout = true,
  }) async {
    try {
      final output = await _iot.sendCommandWithResponse(
        IotCommandClient.getMaskOptions,
        timeoutSeconds: timeout.inMilliseconds / 1000,
        retryOnTimeout: retryOnTimeout,
      );
      if (output == null) return const CameraTimeout();
      final types = output['types'];
      final colorList = output['color_list'];
      if (types is! List || colorList is! List) {
        return CameraFailure('GetMaskOptions response missing fields: $output');
      }
      return CameraSuccess(
        MaskOptions(
          rectangleOnly: output['rectangle_only'] == true,
          singleColorOnly: output['single_color_only'] == true,
          maxMasks: (output['max_masks'] as num?)?.toInt() ?? 0,
          maxPoints: (output['max_points'] as num?)?.toInt() ?? 4,
          types: types.whereType<String>().toList(),
          colorList: [
            for (final c in colorList)
              if (c is Map &&
                  c['x'] is num &&
                  c['y'] is num &&
                  c['z'] is num &&
                  c['colorspace'] is String)
                MaskColor(
                  x: (c['x'] as num).toDouble(),
                  y: (c['y'] as num).toDouble(),
                  z: (c['z'] as num).toDouble(),
                  colorspace: c['colorspace'] as String,
                ),
          ],
        ),
      );
    } catch (e) {
      return CameraFailure(e.toString());
    }
  }

  /// [token] empty/omitted creates a new mask (free slot); non-empty updates the existing mask
  /// with that token. Returns the applied mask's token on success.
  Future<CameraResult<String>> setMask({
    String token = '',
    required List<OnvifPoint> polygon,
    required bool enabled,
    required String type,
    MaskColor? color,
    Duration timeout = const Duration(seconds: 15),
    bool retryOnTimeout = true,
  }) async {
    try {
      final output = await _iot.sendCommandWithResponse(
        IotCommandClient.setMaskConfig,
        params: {
          if (token.isNotEmpty) 'token': token,
          'enabled': enabled,
          'type': type,
          'points': [
            for (final p in polygon) {'x': p.x, 'y': p.y},
          ],
          if (color != null)
            'color': {
              'x': color.x,
              'y': color.y,
              'z': color.z,
              'colorspace': color.colorspace,
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

  Future<CameraResult<void>> deleteMask(
    String token, {
    Duration timeout = const Duration(seconds: 15),
    bool retryOnTimeout = true,
  }) async {
    try {
      final output = await _iot.sendCommandWithResponse(
        IotCommandClient.deleteMaskConfig,
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
