import 'package:camera_api/camera_api.dart';

/// WAN counterpart to `OnvifImagingClient`'s Day/Night and WDR fields — `FR-NE-036/055/056/057`
/// (`GetVideoMode`/`SetVideoMode`/`GetWDRMode`/`SetWDRMode`, pre-existing) plus
/// `GetImagingSettingsOptions` (command `40`, added for the 2026-08-05 options-parity audit,
/// `kb/raw/2026-08-05-code-options-parity-rule-audit.md`) for the choice list/support flag those
/// two Set commands need so the WAN-path UI is never hardcoded — see
/// `.claude/rules/mobile-app-screen-conventions.md` § "LAN/WAN transport selection for settings screens" item 6.
///
/// Mirror/Flip and ISP image quality are intentionally out of scope here — Mirror/Flip is a
/// NuraEye-only fixed enum with no ONVIF Options concept (see `GetImagingSettingsOptions`'s own
/// firmware-side doc comment), and image quality already has its own dedicated
/// `WanImageQualityClient`.
///
/// **Wire-vocabulary note**: `GetVideoMode`/`SetVideoMode` use NuraEye's own lowercase
/// `day`/`night`/`auto` vocabulary, while `GetImagingSettingsOptions`' `ircut_filter_modes` list
/// and the ONVIF/LAN path both use `ON`/`OFF`/`AUTO` (`GetImagingSettingsOptions` reads the same
/// `OnvifImagingOptionsStruct` the ONVIF SOAP path uses). To let callers keep exactly one
/// vocabulary in their own state (the `ON`/`OFF`/`AUTO` one, matching `ImagingSettings
/// .irCutFilterMode`/`ImagingOptions.irCutFilterModes` on the LAN side), [getDayNightMode] and
/// [setDayNightMode] translate at this client's boundary — [getImagingOptions] returns the
/// `ircut_filter_modes` list untranslated, already in that same `ON`/`OFF`/`AUTO` vocabulary.
class WanImagingClient {
  WanImagingClient(this.thingName, {IotCommandClient? iotCommandClient})
    : _iot = iotCommandClient ?? IotCommandClient(thingName);

  /// Exposed so `_DayNightCard` (`imaging_settings_screen.dart`) can filter
  /// `CameraAlertsHub.instance.events` (`FR-MOB-064`'s always-on background WAN alert listener,
  /// `core/camera_alerts_hub.dart`) down to just this camera's own alerts.
  final String thingName;

  final IotCommandClient _iot;

  static const _onvifToWan = {'ON': 'day', 'OFF': 'night', 'AUTO': 'auto'};
  static const _wanToOnvif = {'day': 'ON', 'night': 'OFF', 'auto': 'AUTO'};

  Future<CameraResult<String>> getDayNightMode({
    Duration timeout = const Duration(seconds: 15),
    bool retryOnTimeout = true,
  }) async {
    try {
      final output = await _iot.sendCommandWithResponse(
        IotCommandClient.getVideoMode,
        timeoutSeconds: timeout.inMilliseconds / 1000,
        retryOnTimeout: retryOnTimeout,
      );
      if (output == null) return const CameraTimeout();
      final mode = output['configured_mode'];
      if (mode is! String) {
        return CameraFailure('GetVideoMode response missing fields: $output');
      }
      return CameraSuccess(_wanToOnvif[mode] ?? mode.toUpperCase());
    } catch (e) {
      return CameraFailure(e.toString());
    }
  }

  /// `FR-MOB-064`'s effective-state badge (WAN initial value only; live updates come from
  /// `CameraAlertsHub` instead) — `GetVideoMode`'s `effective_state` field, distinct from
  /// [getDayNightMode]'s `configured_mode`. `true` = day, `false` = night.
  Future<CameraResult<bool>> getEffectiveDayMode({
    Duration timeout = const Duration(seconds: 15),
    bool retryOnTimeout = true,
  }) async {
    try {
      final output = await _iot.sendCommandWithResponse(
        IotCommandClient.getVideoMode,
        timeoutSeconds: timeout.inMilliseconds / 1000,
        retryOnTimeout: retryOnTimeout,
      );
      if (output == null) return const CameraTimeout();
      final state = output['effective_state'];
      if (state is! String) {
        return CameraFailure(
          'GetVideoMode response missing effective_state: $output',
        );
      }
      return CameraSuccess(state == 'day');
    } catch (e) {
      return CameraFailure(e.toString());
    }
  }

  /// Combined configured+effective read in a single round trip — used wherever both are shown
  /// together (the Day/Night status tag). Returns `configuredMode` untranslated, in the same
  /// raw `day`/`night`/`auto` wire vocabulary `nuraeye.c`'s `prvVideoModeToString()` emits on
  /// both LAN and WAN, not [getDayNightMode]'s ON/OFF/AUTO translation.
  Future<CameraResult<({String configuredMode, bool isDayMode})>>
  getVideoModeStatus({
    Duration timeout = const Duration(seconds: 15),
    bool retryOnTimeout = true,
  }) async {
    try {
      final output = await _iot.sendCommandWithResponse(
        IotCommandClient.getVideoMode,
        timeoutSeconds: timeout.inMilliseconds / 1000,
        retryOnTimeout: retryOnTimeout,
      );
      if (output == null) return const CameraTimeout();
      final configured = output['configured_mode'];
      final effective = output['effective_state'];
      if (configured is! String || effective is! String) {
        return CameraFailure('GetVideoMode response missing fields: $output');
      }
      return CameraSuccess((
        configuredMode: configured,
        isDayMode: effective == 'day',
      ));
    } catch (e) {
      return CameraFailure(e.toString());
    }
  }

  Future<CameraResult<void>> setDayNightMode(
    String onvifMode, {
    Duration timeout = const Duration(seconds: 15),
    bool retryOnTimeout = true,
  }) async {
    try {
      final wanMode = _onvifToWan[onvifMode] ?? onvifMode.toLowerCase();
      final output = await _iot.sendCommandWithResponse(
        IotCommandClient.setVideoMode,
        params: {'mode': wanMode},
        timeoutSeconds: timeout.inMilliseconds / 1000,
        retryOnTimeout: retryOnTimeout,
      );
      if (output == null) return const CameraTimeout();
      return const CameraSuccess(null);
    } catch (e) {
      return CameraFailure(e.toString());
    }
  }

  Future<CameraResult<({bool enabled, double level})>> getWdr({
    Duration timeout = const Duration(seconds: 15),
    bool retryOnTimeout = true,
  }) async {
    try {
      final output = await _iot.sendCommandWithResponse(
        IotCommandClient.getWDRMode,
        timeoutSeconds: timeout.inMilliseconds / 1000,
        retryOnTimeout: retryOnTimeout,
      );
      if (output == null) return const CameraTimeout();
      final mode = output['mode'];
      final level = output['level'];
      if (mode is! String || level is! num) {
        return CameraFailure('GetWDRMode response missing fields: $output');
      }
      return CameraSuccess((enabled: mode == 'ON', level: level.toDouble()));
    } catch (e) {
      return CameraFailure(e.toString());
    }
  }

  Future<CameraResult<void>> setWdr(
    bool enabled,
    double level, {
    Duration timeout = const Duration(seconds: 15),
    bool retryOnTimeout = true,
  }) async {
    try {
      final output = await _iot.sendCommandWithResponse(
        IotCommandClient.setWDRMode,
        params: {'mode': enabled ? 'ON' : 'OFF', 'level': level.round()},
        timeoutSeconds: timeout.inMilliseconds / 1000,
        retryOnTimeout: retryOnTimeout,
      );
      if (output == null) return const CameraTimeout();
      return const CameraSuccess(null);
    } catch (e) {
      return CameraFailure(e.toString());
    }
  }

  /// Returns the Day/Night choice list in the same `ON`/`OFF`/`AUTO` vocabulary
  /// [getDayNightMode]/[setDayNightMode] use, plus `wdrSupported`.
  Future<CameraResult<({List<String> dayNightModes, bool wdrSupported})>>
  getImagingOptions({
    Duration timeout = const Duration(seconds: 15),
    bool retryOnTimeout = true,
  }) async {
    try {
      final output = await _iot.sendCommandWithResponse(
        IotCommandClient.getImagingSettingsOptions,
        timeoutSeconds: timeout.inMilliseconds / 1000,
        retryOnTimeout: retryOnTimeout,
      );
      if (output == null) return const CameraTimeout();
      final modes = output['ircut_filter_modes'];
      final wdrSupported = output['wdr_supported'];
      if (modes is! List || wdrSupported is! bool) {
        return CameraFailure(
          'GetImagingSettingsOptions response missing fields: $output',
        );
      }
      return CameraSuccess((
        dayNightModes: modes.whereType<String>().toList(),
        wdrSupported: wdrSupported,
      ));
    } catch (e) {
      return CameraFailure(e.toString());
    }
  }
}
