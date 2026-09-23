import 'dart:async';
import 'dart:typed_data';

import 'package:camera_api/camera_api.dart';

import '../../app_state/camera_network.dart';
import '../../app_state/transport_preference.dart';
import 'package:flutter/material.dart';

import '../../app_state/camera_settings_cache.dart';
import '../../app_state/camera_sync.dart';
import '../../app_state/homes_controller.dart';
import '../../models/camera.dart';
import '../../widgets/camera_preview_thumbnail.dart';
import '../../widgets/fixed_preview_layout.dart';
import '../../widgets/glass_card.dart';
import '../../widgets/gradient_background.dart';
import '../../widgets/navigation_leave_guard.dart';
import '../../widgets/refresh_preview_button.dart';
import '../../widgets/reload_settings_button.dart';
import '../../widgets/saving_overlay.dart';
import '../../widgets/settings_save_button.dart';

const _defaultBrightness = 50.0;
const _defaultContrast = 50.0;
const _defaultSaturation = 50.0;
const _defaultSharpness = 50.0;
const _defaultMirrorFlip = CameraMirrorFlip.off;
const _defaultAntiFlickerMode = CameraAntiFlickerMode.auto;
const _defaultWdrEnabled = false;
const _defaultWdrLevel = 50.0;
const _defaultWhiteBalance = CameraAutoManual.auto;
const _defaultExposure = CameraAutoManual.auto;

/// Fallback bounds/defaults for manual exposure's numeric fields, only used
/// pre-connection or when the camera hasn't reported real
/// `getImagingOptions().exposureTime`/`exposureGain` ranges yet — same
/// fallback-range convention `video_encoder_screen.dart`'s sliders use.
/// Units match the ONVIF wire values (`ImagingSettings.exposureTime`
/// microseconds, `exposureGain` dB) — not independently re-derived.
const _defaultExposureTime = 10000.0;
const _defaultExposureGain = 0.0;
const _fallbackExposureTimeMin = 100.0;
const _fallbackExposureTimeMax = 100000.0;
const _fallbackExposureGainMin = 0.0;
const _fallbackExposureGainMax = 48.0;

/// Same fallback convention for the four ISP sliders and WDR level — used
/// only until `getImagingOptions()` reports this sensor's real ranges, which
/// are not guaranteed to be 0-100 on every firmware build.
const _fallbackIspMin = 0.0;
const _fallbackIspMax = 100.0;
const _fallbackWdrLevelMin = 1.0;
const _fallbackWdrLevelMax = 100.0;

/// `CameraMirrorFlip` <-> `MirrorFlipMode` — same 4 values, different enum
/// types (one app-side, one camera_api-side).
MirrorFlipMode _toWireMirrorFlip(CameraMirrorFlip mode) => switch (mode) {
  CameraMirrorFlip.off => MirrorFlipMode.off,
  CameraMirrorFlip.mirror => MirrorFlipMode.mirror,
  CameraMirrorFlip.flip => MirrorFlipMode.flip,
  CameraMirrorFlip.both => MirrorFlipMode.both,
};

CameraMirrorFlip _fromWireMirrorFlip(MirrorFlipMode mode) => switch (mode) {
  MirrorFlipMode.off => CameraMirrorFlip.off,
  MirrorFlipMode.mirror => CameraMirrorFlip.mirror,
  MirrorFlipMode.flip => CameraMirrorFlip.flip,
  MirrorFlipMode.both => CameraMirrorFlip.both,
};

/// `CameraAntiFlickerMode` <-> `AntiFlickerMode` — same 3 values, different
/// enum types, same reasoning as [_toWireMirrorFlip]/[_fromWireMirrorFlip].
AntiFlickerMode _toWireAntiFlicker(CameraAntiFlickerMode mode) =>
    switch (mode) {
      CameraAntiFlickerMode.hz50 => AntiFlickerMode.hz50,
      CameraAntiFlickerMode.hz60 => AntiFlickerMode.hz60,
      CameraAntiFlickerMode.auto => AntiFlickerMode.auto,
    };

CameraAntiFlickerMode _fromWireAntiFlicker(AntiFlickerMode mode) =>
    switch (mode) {
      AntiFlickerMode.hz50 => CameraAntiFlickerMode.hz50,
      AntiFlickerMode.hz60 => CameraAntiFlickerMode.hz60,
      AntiFlickerMode.auto => CameraAntiFlickerMode.auto,
    };

/// `CameraAutoManual` <-> ONVIF `"AUTO"`/`"MANUAL"` wire values, shared by
/// both the white-balance and exposure mode fields.
String _autoManualToWire(CameraAutoManual mode) => switch (mode) {
  CameraAutoManual.auto => 'AUTO',
  CameraAutoManual.manual => 'MANUAL',
};

CameraAutoManual? _autoManualFromWire(String? wireValue) =>
    switch (wireValue?.toUpperCase()) {
      'AUTO' => CameraAutoManual.auto,
      'MANUAL' => CameraAutoManual.manual,
      _ => null,
    };

/// Parsed from `NuraeyeClient.call('GetImageDefaults')`'s raw JSON — only the fields this
/// screen's sliders/segmented buttons cover. Mirror/flip, anti-flicker, and WDR have no defaults
/// endpoint, so [_resetToDefault] keeps this screen's local hardcoded fallback for those three.
class _ImageDefaults {
  const _ImageDefaults({
    this.brightness,
    this.contrast,
    this.saturation,
    this.sharpness,
    this.whiteBalance,
    this.exposure,
    this.exposureTime,
    this.exposureGain,
  });

  final double? brightness;
  final double? contrast;
  final double? saturation;
  final double? sharpness;
  final CameraAutoManual? whiteBalance;
  final CameraAutoManual? exposure;
  final double? exposureTime;
  final double? exposureGain;

  factory _ImageDefaults.fromJson(Map<String, dynamic> json) => _ImageDefaults(
    brightness: (json['brightness'] as num?)?.toDouble(),
    contrast: (json['contrast'] as num?)?.toDouble(),
    saturation: (json['saturation'] as num?)?.toDouble(),
    sharpness: (json['sharpness'] as num?)?.toDouble(),
    whiteBalance: _autoManualFromWire(json['white_balance_mode'] as String?),
    exposure: _autoManualFromWire(json['exposure_mode'] as String?),
    // Not confirmed present in GetImageDefaults' real response (undocumented
    // beyond the fields this screen already used before this) — read
    // defensively; absent simply falls back to the hardcoded default below.
    exposureTime: (json['exposure_time'] as num?)?.toDouble(),
    exposureGain: (json['exposure_gain'] as num?)?.toDouble(),
  );
}

const _autoManualSegmentsByMode = {
  CameraAutoManual.auto: ButtonSegment(
    value: CameraAutoManual.auto,
    label: Text('Auto'),
  ),
  CameraAutoManual.manual: ButtonSegment(
    value: CameraAutoManual.manual,
    label: Text('Manual'),
  ),
};

/// Builds the Auto/Manual segments to actually show — only the modes the
/// camera's own Options response reports (never a hardcoded fixed set, per
/// `.claude/rules/mobile-app-screen-conventions.md`), always including
/// [current] defensively so `SegmentedButton`'s `selected` is never outside
/// its own `segments`. Shows both when [wireModes] is null (unverified — no
/// connection yet).
List<ButtonSegment<CameraAutoManual>> _autoManualSegments(
  List<String>? wireModes,
  CameraAutoManual current,
) {
  if (wireModes == null) return _autoManualSegmentsByMode.values.toList();
  final supported = wireModes
      .map(_autoManualFromWire)
      .whereType<CameraAutoManual>()
      .toSet();
  supported.add(current);
  return [
    for (final mode in CameraAutoManual.values)
      if (supported.contains(mode)) _autoManualSegmentsByMode[mode]!,
  ];
}

/// Imaging: preview, mirror/flip, brightness/contrast/saturation/sharpness,
/// WDR, white balance, and exposure. Backed by real `camera_api` when the
/// camera has a saved connection: `OnvifImagingClient` for everything except
/// mirror/flip, which is a separate NuraEye setting (`MirrorFlipClient`) —
/// both are loaded together on screen open and saved together on Save.
/// Falls back to local-only `HomesController` state (`simulateCameraSave`)
/// for a camera with no saved connection yet. Manual exposure's numeric
/// time/gain fields (`ImagingSettings.exposureTime`/`exposureGain`, IMG-018/
/// IMG-019) only render when Exposure (IMG-010) is set to Manual, bounded by
/// the camera's own `getImagingOptions().exposureTime`/`exposureGain`
/// ranges when available. LAN-only — unlike every other field on this
/// screen, no WAN fallback exists for these two specifically
/// (`WanImageQualityClient`'s raw JSON map is undocumented for these two
/// keys, and `OnvifImagingClient`'s own doc previously noted no WAN
/// counterpart existed here at all — since superseded by `WanImageQualityClient`
/// for the other fields, but not independently confirmed for these). LAN is
/// tried first for both load and save; a WAN retry (`WanImageQualityClient`
/// for brightness/contrast/
/// saturation/sharpness/white-balance/exposure, `WanImagingClient.setWdr`
/// for WDR, `WanMirrorFlipClient` for mirror/flip) kicks in when the LAN
/// call itself fails/times out and `connection.thingName` is known, per
/// `.claude/rules/mobile-app-screen-conventions.md`'s LAN/WAN convention.
/// `WanImageQualityClient.getImageSettings`/`setImageSettings` take/return a
/// raw JSON map (no typed wrapper exists) — this screen reads/writes it
/// using the same field-name vocabulary `GetImageDefaults`'s JSON already
/// uses (`brightness`/`contrast`/`saturation`/`sharpness`/
/// `white_balance_mode`/`exposure_mode`), not independently hardware-verified
/// since no other documented source names them for this specific WAN call.
/// "Reset to Default" resets brightness/contrast/saturation/sharpness/white-balance/exposure to
/// the camera's own reported factory defaults (`NuraeyeClient.call('GetImageDefaults')`, loaded
/// alongside the other LAN calls above) when available — not to whatever was last saved.
/// Mirror/flip and WDR have no defaults endpoint, so those two always fall back to this screen's
/// hardcoded constants; the other fields also fall back to those constants when unverified (no
/// connection yet, or the `GetImageDefaults` call failed).
class ImagingScreen extends StatefulWidget {
  const ImagingScreen({
    super.key,
    required this.camera,
    required this.homesController,
  });

  static const routeName = 'imaging';

  final Camera camera;
  final HomesController homesController;

  @override
  State<ImagingScreen> createState() => _ImagingScreenState();
}

class _ImagingScreenState extends State<ImagingScreen> {
  late CameraMirrorFlip _mirrorFlip = _camera.mirrorFlip;
  late CameraAntiFlickerMode _antiFlickerMode = _camera.antiFlickerMode;
  late double _brightness = _camera.brightness;
  late double _contrast = _camera.contrast;
  late double _saturation = _camera.saturation;
  late double _sharpness = _camera.sharpness;
  late bool _wdrEnabled = _camera.wdrEnabled;
  late double _wdrLevel = _camera.wdrLevel;
  late CameraAutoManual _whiteBalance = _camera.whiteBalance;
  late CameraAutoManual _exposure = _camera.exposure;
  late double _exposureTime = _camera.exposureTime;
  late double _exposureGain = _camera.exposureGain;
  bool _isDirty = false;
  bool _isSaving = false;
  bool _isRefreshing = false;
  int _previewReloadKey = 0;

  /// A transient WAN preview fetched when [_refreshPreview]'s LAN attempt
  /// fails — never persisted (see `fetchWanPreviewSnapshot`'s doc), just
  /// held here for as long as this screen is open. Cleared once a LAN
  /// refresh succeeds again, so the persisted (and now fresher) thumbnail
  /// takes back over.
  Uint8List? _wanPreviewBytes;

  /// Bounds/choice lists from the camera's own `getImagingOptions()` — null
  /// means "camera not verified yet", in which case every control shows
  /// (same fallback reasoning as `_dummyTimezones` in camera_info_screen).
  ImagingOptions? _imagingOptions;

  /// Camera-reported factory defaults for "Reset to Default" (`GetImageDefaults`) — null means
  /// unverified (no connection yet, or the call failed), in which case [_resetToDefault] falls
  /// back to this screen's hardcoded defaults.
  _ImageDefaults? _imageDefaults;

  /// True only while a saved connection exists and its `getImagingOptions`/
  /// `getImagingSettings` responses haven't landed yet — gates the
  /// capability-derived controls (WDR) so they never render off a default/
  /// unverified guess and then flicker once the real answer arrives. No
  /// connection means there's nothing to wait for.
  late bool _isLoading = _camera.connection != null;

  @override
  void initState() {
    super.initState();
    _loadRealImaging();
  }

  Future<void> _loadRealImaging() async {
    final connection = _camera.connection;
    if (connection == null) return;
    final imagingClient = OnvifImagingClient(
      connection,
      httpClient: CameraNetwork.clientFor(connection.host),
    );
    final nuraeye = NuraeyeClient(connection);

    // Known WAN (Camera.lastKnownWan) skips even the cheap probe below —
    // an instant decision beats a ~3s round trip. Otherwise, a cheap LAN
    // reachability probe first (same call camera_sync.dart's
    // syncCameraFromDevice/pingCameraReachability use) — when the phone is
    // off this camera's LAN, every one of the 5 LAN calls below fails
    // together anyway (they're already parallel), so this just skips
    // straight to the WAN fallback instead of waiting out that shared LAN
    // timeout for nothing.
    final lanReachable = _camera.lastKnownWan == true
        ? false
        : await LiveStreamUriClient(
            nuraeye,
          ).checkReachable(timeout: lanReachabilityProbeTimeout);

    final CameraResult<ImagingSettings> settingsResultRaw;
    final CameraResult<ImagingOptions> optionsResult;
    final CameraResult<MirrorFlipMode> mirrorFlipResultRaw;
    final CameraResult<Map<String, dynamic>> defaultsResultRaw;
    final CameraResult<AntiFlickerMode> antiFlickerResultRaw;
    if (lanReachable) {
      final results = await Future.wait([
        imagingClient.getImagingSettings(),
        NetworkAnswerCache.getOrFetch(
          connection.host,
          'imagingOptions',
          fetch: imagingClient.getImagingOptions,
        ),
        MirrorFlipClient(nuraeye).getMirrorFlip(),
        nuraeye.call('GetImageDefaults'),
        AntiFlickerClient(nuraeye).getAntiFlickerMode(),
      ]);
      settingsResultRaw = results[0] as CameraResult<ImagingSettings>;
      optionsResult = results[1] as CameraResult<ImagingOptions>;
      mirrorFlipResultRaw = results[2] as CameraResult<MirrorFlipMode>;
      defaultsResultRaw = results[3] as CameraResult<Map<String, dynamic>>;
      antiFlickerResultRaw = results[4] as CameraResult<AntiFlickerMode>;
    } else {
      settingsResultRaw = const CameraTimeout<ImagingSettings>();
      // Options are LAN-only regardless of transport (see this class's doc
      // comment) — a known-unreachable LAN just means no Options this load.
      optionsResult = const CameraTimeout<ImagingOptions>();
      mirrorFlipResultRaw = const CameraTimeout<MirrorFlipMode>();
      defaultsResultRaw = const CameraTimeout<Map<String, dynamic>>();
      antiFlickerResultRaw = const CameraTimeout<AntiFlickerMode>();
    }
    imagingClient.close();
    nuraeye.close();

    var settingsResult = settingsResultRaw;
    var mirrorFlipResult = mirrorFlipResultRaw;
    var defaultsResult = defaultsResultRaw;
    var antiFlickerResult = antiFlickerResultRaw;

    // Options are LAN-only on a normal load (see this class's doc comment)
    // — only current-value reads fall back to WAN here. All four requested
    // in parallel (previously sequential — up to ~24s each with
    // IotCommandClient's own built-in one-shot retry on top of this
    // class's 12s timeout, so up to ~120s combined in the worst case).
    final thingName = connection.thingName;
    Map<String, dynamic>? wanImageSettings;
    ({bool enabled, double level})? wanWdr;
    if (thingName != null) {
      final needsSettings = settingsResult is! CameraSuccess;
      final needsMirrorFlip = mirrorFlipResult is! CameraSuccess;
      final needsDefaults = defaultsResult is! CameraSuccess;
      final needsAntiFlicker = antiFlickerResult is! CameraSuccess;
      if (needsSettings ||
          needsMirrorFlip ||
          needsDefaults ||
          needsAntiFlicker) {
        final wanResults = await Future.wait([
          needsSettings
              ? WanImageQualityClient(thingName).getImageSettings()
              : Future.value(null),
          needsSettings
              ? WanImagingClient(thingName).getWdr()
              : Future.value(null),
          needsMirrorFlip
              ? WanMirrorFlipClient(thingName).getMirrorFlip()
              : Future.value(null),
          needsDefaults
              ? WanImageQualityClient(thingName).getImageDefaults()
              : Future.value(null),
          needsAntiFlicker
              ? WanAntiFlickerClient(thingName).getAntiFlickerMode()
              : Future.value(null),
        ]);
        final wanSettingsResult =
            wanResults[0] as CameraResult<Map<String, dynamic>>?;
        final wanWdrResult =
            wanResults[1] as CameraResult<({bool enabled, double level})>?;
        final wanMirrorFlipResult =
            wanResults[2] as CameraResult<MirrorFlipMode>?;
        final wanDefaultsResult =
            wanResults[3] as CameraResult<Map<String, dynamic>>?;
        final wanAntiFlickerResult =
            wanResults[4] as CameraResult<AntiFlickerMode>?;

        if (wanSettingsResult case CameraSuccess(:final value)) {
          wanImageSettings = value;
        }
        if (wanWdrResult case CameraSuccess(:final value)) wanWdr = value;
        if (needsMirrorFlip) mirrorFlipResult = wanMirrorFlipResult!;
        if (needsDefaults) defaultsResult = wanDefaultsResult!;
        if (needsAntiFlicker) antiFlickerResult = wanAntiFlickerResult!;
      }
    }
    if (!mounted) return;

    setState(() {
      if (settingsResult case CameraSuccess(:final value)) {
        if (value.brightness != null) _brightness = value.brightness!;
        if (value.colorSaturation != null) {
          _saturation = value.colorSaturation!;
        }
        if (value.contrast != null) _contrast = value.contrast!;
        if (value.sharpness != null) _sharpness = value.sharpness!;
        if (value.wdrMode != null) {
          _wdrEnabled = value.wdrMode!.toUpperCase() == 'ON';
        }
        if (value.wdrLevel != null) _wdrLevel = value.wdrLevel!;
        final whiteBalance = _autoManualFromWire(value.whiteBalanceMode);
        if (whiteBalance != null) _whiteBalance = whiteBalance;
        final exposure = _autoManualFromWire(value.exposureMode);
        if (exposure != null) _exposure = exposure;
        if (value.exposureTime != null) _exposureTime = value.exposureTime!;
        if (value.exposureGain != null) _exposureGain = value.exposureGain!;
      } else if (wanImageSettings != null) {
        final m = wanImageSettings;
        final brightness = (m['brightness'] as num?)?.toDouble();
        if (brightness != null) _brightness = brightness;
        final contrast = (m['contrast'] as num?)?.toDouble();
        if (contrast != null) _contrast = contrast;
        final saturation = (m['saturation'] as num?)?.toDouble();
        if (saturation != null) _saturation = saturation;
        final sharpness = (m['sharpness'] as num?)?.toDouble();
        if (sharpness != null) _sharpness = sharpness;
        final whiteBalance = _autoManualFromWire(
          m['white_balance_mode'] as String?,
        );
        if (whiteBalance != null) _whiteBalance = whiteBalance;
        final exposure = _autoManualFromWire(m['exposure_mode'] as String?);
        if (exposure != null) _exposure = exposure;
        final wdr = wanWdr;
        if (wdr != null) {
          _wdrEnabled = wdr.enabled;
          _wdrLevel = wdr.level;
        }
      }
      if (optionsResult case CameraSuccess(:final value)) {
        _imagingOptions = value;
      }
      if (mirrorFlipResult case CameraSuccess(:final value)) {
        _mirrorFlip = _fromWireMirrorFlip(value);
      }
      if (defaultsResult case CameraSuccess(:final value)) {
        _imageDefaults = _ImageDefaults.fromJson(value);
      }
      if (antiFlickerResult case CameraSuccess(:final value)) {
        _antiFlickerMode = _fromWireAntiFlicker(value);
      }
      _isLoading = false;
    });

    widget.homesController.updateCamera(
      widget.camera.id,
      (camera) => camera.copyWith(
        mirrorFlip: _mirrorFlip,
        antiFlickerMode: _antiFlickerMode,
        brightness: _brightness,
        contrast: _contrast,
        saturation: _saturation,
        sharpness: _sharpness,
        wdrEnabled: _wdrEnabled,
        wdrLevel: _wdrLevel,
        whiteBalance: _whiteBalance,
        exposure: _exposure,
      ),
    );
  }

  /// Manual reload — re-fetches this screen's fields from the camera, for
  /// when a change made elsewhere (another client, the camera's own web UI)
  /// hasn't shown up here yet. Distinct from [_save] (pushes local edits)
  /// and [_refreshPreview] (only refetches the preview image).
  Future<void> _reloadSettings() async {
    if (_camera.connection == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No saved connection for this camera yet'),
        ),
      );
      return;
    }
    setState(() => _isLoading = true);
    await _loadRealImaging();
  }

  void _markDirty(VoidCallback update) {
    setState(() {
      update();
      _isDirty = true;
    });
  }

  /// Looked up fresh from [HomesController] on every build (not
  /// [widget.camera] directly) so a refreshed snapshot from [_refreshPreview]
  /// actually shows up without leaving and re-entering this screen.
  Camera get _camera {
    for (final home in widget.homesController.value.homes) {
      for (final camera in home.cameras) {
        if (camera.id == widget.camera.id) return camera;
      }
    }
    return widget.camera;
  }

  Future<void> _refreshPreview() async {
    final connection = _camera.connection;
    if (connection == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No saved connection for this camera yet'),
        ),
      );
      return;
    }
    setState(() => _isRefreshing = true);
    final succeeded = await refreshCameraSnapshot(
      homesController: widget.homesController,
      cameraId: widget.camera.id,
      connection: connection,
    );
    if (!mounted) return;
    if (succeeded) {
      setState(() {
        _isRefreshing = false;
        _previewReloadKey++;
        _wanPreviewBytes = null;
      });
      return;
    }

    // LAN failed — fall back to a transient WAN preview rather than
    // surfacing an error outright, per mobile-app-screen-conventions.md's
    // LAN/WAN convention. The last-shown preview (whether the persisted
    // thumbnail or a previous WAN frame) stays on screen until this
    // resolves, not blanked out mid-refresh.
    final wanBytes = await fetchWanPreviewSnapshot(connection: connection);
    if (!mounted) return;
    setState(() {
      _isRefreshing = false;
      if (wanBytes != null) _wanPreviewBytes = wanBytes;
    });
    if (wanBytes == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Failed to refresh preview')),
      );
    }
  }

  Future<void> _save() async {
    final connection = _camera.connection;
    setState(() => _isSaving = true);

    final bool succeeded;
    if (connection != null) {
      final thingName = connection.thingName;
      final wdrSupported = _imagingOptions?.wdrSupported ?? true;
      // Skips the LAN Set attempt entirely when this camera's last
      // confirmed transport was WAN — see Camera.lastKnownWan's doc.
      final preferWan = _camera.lastKnownWan == true && thingName != null;

      // Only push the sections that actually changed from the last
      // camera-confirmed value — mobile-app-screen-conventions.md's Apply
      // convention. Sending all three independent Set calls unconditionally
      // on every Save was a real source of delay: nudging just one slider
      // still fired three full round trips (quality/WDR, mirror/flip,
      // anti-flicker) every time, each of which can take seconds on WAN.
      final qualityChanged =
          _brightness != _camera.brightness ||
          _contrast != _camera.contrast ||
          _saturation != _camera.saturation ||
          _sharpness != _camera.sharpness ||
          _wdrEnabled != _camera.wdrEnabled ||
          _wdrLevel != _camera.wdrLevel ||
          _whiteBalance != _camera.whiteBalance ||
          _exposure != _camera.exposure ||
          _exposureTime != _camera.exposureTime ||
          _exposureGain != _camera.exposureGain;
      final mirrorFlipChanged = _mirrorFlip != _camera.mirrorFlip;
      final antiFlickerChanged = _antiFlickerMode != _camera.antiFlickerMode;

      var imagingSucceeded = true;
      if (qualityChanged) {
        CameraResult<void>? imagingResult;
        if (!preferWan) {
          final imagingClient = OnvifImagingClient(
            connection,
            httpClient: CameraNetwork.clientFor(connection.host),
          );
          imagingResult = await imagingClient.setImagingSettings(
            ImagingSettings(
              brightness: _brightness,
              colorSaturation: _saturation,
              contrast: _contrast,
              sharpness: _sharpness,
              wdrMode: wdrSupported ? (_wdrEnabled ? 'ON' : 'OFF') : null,
              wdrLevel: (wdrSupported && _wdrEnabled) ? _wdrLevel : null,
              whiteBalanceMode: _autoManualToWire(_whiteBalance),
              exposureMode: _autoManualToWire(_exposure),
              exposureTime: _exposure == CameraAutoManual.manual
                  ? _exposureTime
                  : null,
              exposureGain: _exposure == CameraAutoManual.manual
                  ? _exposureGain
                  : null,
            ),
          );
          imagingClient.close();
        }

        // A failed LAN Apply/Set retries over WAN before surfacing an error
        // (or WAN is called directly when known — see preferWan above),
        // per mobile-app-screen-conventions.md's LAN/WAN convention.
        imagingSucceeded = imagingResult is CameraSuccess;
        if (!imagingSucceeded && thingName != null) {
          final wanQualityResult = await WanImageQualityClient(thingName)
              .setImageSettings({
                'brightness': _brightness,
                'contrast': _contrast,
                'saturation': _saturation,
                'sharpness': _sharpness,
                'white_balance_mode': _autoManualToWire(_whiteBalance),
                'exposure_mode': _autoManualToWire(_exposure),
              });
          var wdrOk = true;
          if (wdrSupported) {
            final wanWdrResult = await WanImagingClient(
              thingName,
            ).setWdr(_wdrEnabled, _wdrEnabled ? _wdrLevel : 0);
            wdrOk = wanWdrResult is CameraSuccess;
          }
          imagingSucceeded = wanQualityResult is CameraSuccess && wdrOk;
        }
      }

      var mirrorFlipSucceeded = true;
      if (mirrorFlipChanged) {
        CameraResult<void>? mirrorFlipResult;
        if (!preferWan) {
          final nuraeye = NuraeyeClient(connection);
          mirrorFlipResult = await MirrorFlipClient(
            nuraeye,
          ).setMirrorFlip(_toWireMirrorFlip(_mirrorFlip));
          nuraeye.close();
        }
        if (mirrorFlipResult is! CameraSuccess && thingName != null) {
          mirrorFlipResult = await WanMirrorFlipClient(
            thingName,
          ).setMirrorFlip(_toWireMirrorFlip(_mirrorFlip));
        }
        mirrorFlipSucceeded = mirrorFlipResult is CameraSuccess;
      }

      var antiFlickerSucceeded = true;
      if (antiFlickerChanged) {
        CameraResult<void>? antiFlickerResult;
        if (!preferWan) {
          final nuraeye = NuraeyeClient(connection);
          antiFlickerResult = await AntiFlickerClient(
            nuraeye,
          ).setAntiFlickerMode(_toWireAntiFlicker(_antiFlickerMode));
          nuraeye.close();
        }
        if (antiFlickerResult is! CameraSuccess && thingName != null) {
          antiFlickerResult = await WanAntiFlickerClient(
            thingName,
          ).setAntiFlickerMode(_toWireAntiFlicker(_antiFlickerMode));
        }
        antiFlickerSucceeded = antiFlickerResult is CameraSuccess;
      }

      succeeded =
          imagingSucceeded && mirrorFlipSucceeded && antiFlickerSucceeded;
    } else {
      succeeded = await simulateCameraSave();
    }

    if (!mounted) return;
    setState(() => _isSaving = false);
    if (succeeded) {
      widget.homesController.updateCamera(
        widget.camera.id,
        (camera) => camera.copyWith(
          mirrorFlip: _mirrorFlip,
          antiFlickerMode: _antiFlickerMode,
          brightness: _brightness,
          contrast: _contrast,
          saturation: _saturation,
          sharpness: _sharpness,
          wdrEnabled: _wdrEnabled,
          wdrLevel: _wdrLevel,
          whiteBalance: _whiteBalance,
          exposure: _exposure,
        ),
      );
      setState(() => _isDirty = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Changes saved')));
      if (connection != null) unawaited(_refreshPreview());
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Failed to save changes. Try again.')),
      );
    }
  }

  void _resetToDefault() {
    final defaults = _imageDefaults;
    _markDirty(() {
      // Mirror/flip, anti-flicker, and WDR have no camera-reported defaults
      // endpoint — always this screen's own hardcoded fallback.
      _mirrorFlip = _defaultMirrorFlip;
      _antiFlickerMode = _defaultAntiFlickerMode;
      _wdrEnabled = _defaultWdrEnabled;
      _wdrLevel = _defaultWdrLevel;
      _brightness = defaults?.brightness ?? _defaultBrightness;
      _contrast = defaults?.contrast ?? _defaultContrast;
      _saturation = defaults?.saturation ?? _defaultSaturation;
      _sharpness = defaults?.sharpness ?? _defaultSharpness;
      _whiteBalance = defaults?.whiteBalance ?? _defaultWhiteBalance;
      _exposure = defaults?.exposure ?? _defaultExposure;
      _exposureTime = defaults?.exposureTime ?? _defaultExposureTime;
      _exposureGain = defaults?.exposureGain ?? _defaultExposureGain;
    });
  }

  Future<bool> _confirmLeave() => confirmDiscardOnLeave(
    context: context,
    isDirty: _isDirty,
    onSave: _save,
    isDirtyAfterSave: () => _isDirty,
    dialogKey: const Key('IMG-015'),
    discardKey: const Key('IMG-016'),
    saveKey: const Key('IMG-017'),
  );

  @override
  Widget build(BuildContext context) {
    return LeaveGuard(
      canLeave: _confirmLeave,
      child: GradientBackground(
        child: Scaffold(
          backgroundColor: Colors.transparent,
          appBar: AppBar(
            key: const Key('IMG-001'),
            title: const Text('Imaging'),
            actions: [
              ReloadSettingsButton(
                settingsKey: const Key('IMG-021'),
                isBusy: _isLoading || _isSaving,
                onPressed: _reloadSettings,
              ),
              SettingsSaveButton(
                settingsKey: const Key('IMG-002'),
                isDirty: _isDirty,
                isSaving: _isSaving,
                onPressed: _save,
              ),
            ],
          ),
          body: SavingOverlay(
            isSaving: _isSaving || _isLoading,
            label: _isLoading ? 'Loading…' : 'Saving…',
            child: FixedPreviewLayout(
              preview: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  CameraPreviewThumbnail(
                    key: ValueKey(_previewReloadKey),
                    settingsKey: const Key('IMG-003'),
                    camera: _camera,
                    overrideBytes: _wanPreviewBytes,
                  ),
                  const SizedBox(height: 8),
                  RefreshPreviewButton(
                    settingsKey: const Key('IMG-014'),
                    isRefreshing: _isRefreshing,
                    onPressed: _refreshPreview,
                  ),
                ],
              ),
              scrollableChildren: [
                Align(
                  alignment: Alignment.centerRight,
                  child: OutlinedButton(
                    key: const Key('IMG-011'),
                    onPressed: _resetToDefault,
                    child: const Text('Reset to Default'),
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  'Mirror / Flip',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 8),
                SegmentedButton<CameraMirrorFlip>(
                  key: const Key('IMG-004'),
                  segments: const [
                    ButtonSegment(
                      value: CameraMirrorFlip.off,
                      label: Text('Off'),
                    ),
                    ButtonSegment(
                      value: CameraMirrorFlip.mirror,
                      label: Text('Mirror'),
                    ),
                    ButtonSegment(
                      value: CameraMirrorFlip.flip,
                      label: Text('Flip'),
                    ),
                    ButtonSegment(
                      value: CameraMirrorFlip.both,
                      label: Text('Both'),
                    ),
                  ],
                  selected: {_mirrorFlip},
                  // Without this, the selected segment's checkmark eats
                  // into an already-tight 4-segment row, wrapping "Mirror"
                  // mid-word ("Mirro"/"r") on narrower screens.
                  showSelectedIcon: false,
                  onSelectionChanged: (selection) =>
                      _markDirty(() => _mirrorFlip = selection.first),
                ),
                const SizedBox(height: 16),
                Text(
                  'Anti-Flicker',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 8),
                SegmentedButton<CameraAntiFlickerMode>(
                  key: const Key('IMG-022'),
                  segments: const [
                    ButtonSegment(
                      value: CameraAntiFlickerMode.hz50,
                      label: Text('50Hz'),
                    ),
                    ButtonSegment(
                      value: CameraAntiFlickerMode.hz60,
                      label: Text('60Hz'),
                    ),
                    ButtonSegment(
                      value: CameraAntiFlickerMode.auto,
                      label: Text('Auto'),
                    ),
                  ],
                  selected: {_antiFlickerMode},
                  onSelectionChanged: (selection) =>
                      _markDirty(() => _antiFlickerMode = selection.first),
                ),
                const SizedBox(height: 16),
                GlassCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _SliderRow(
                        settingsKey: const Key('IMG-005'),
                        label: 'Brightness',
                        value: _brightness,
                        min:
                            _imagingOptions?.brightness?.min ?? _fallbackIspMin,
                        max:
                            _imagingOptions?.brightness?.max ?? _fallbackIspMax,
                        onChanged: (value) =>
                            _markDirty(() => _brightness = value),
                      ),
                      _SliderRow(
                        settingsKey: const Key('IMG-006'),
                        label: 'Contrast',
                        value: _contrast,
                        min: _imagingOptions?.contrast?.min ?? _fallbackIspMin,
                        max: _imagingOptions?.contrast?.max ?? _fallbackIspMax,
                        onChanged: (value) =>
                            _markDirty(() => _contrast = value),
                      ),
                      _SliderRow(
                        settingsKey: const Key('IMG-007'),
                        label: 'Saturation',
                        value: _saturation,
                        min:
                            _imagingOptions?.colorSaturation?.min ??
                            _fallbackIspMin,
                        max:
                            _imagingOptions?.colorSaturation?.max ??
                            _fallbackIspMax,
                        onChanged: (value) =>
                            _markDirty(() => _saturation = value),
                      ),
                      _SliderRow(
                        settingsKey: const Key('IMG-008'),
                        label: 'Sharpness',
                        value: _sharpness,
                        min: _imagingOptions?.sharpness?.min ?? _fallbackIspMin,
                        max: _imagingOptions?.sharpness?.max ?? _fallbackIspMax,
                        onChanged: (value) =>
                            _markDirty(() => _sharpness = value),
                      ),
                    ],
                  ),
                ),
                // Hidden outright (not just disabled) when the camera's own
                // Options response says WDR isn't supported on this sensor —
                // per ImagingOptions.wdrSupported's doc. Shown when
                // unverified (no connection yet, _imagingOptions == null).
                if (_imagingOptions?.wdrSupported ?? true) ...[
                  const SizedBox(height: 16),
                  GlassCard(
                    padding: EdgeInsets.zero,
                    child: SwitchListTile(
                      key: const Key('IMG-012'),
                      title: const Text('WDR'),
                      value: _wdrEnabled,
                      onChanged: (value) =>
                          _markDirty(() => _wdrEnabled = value),
                    ),
                  ),
                  if (_wdrEnabled) ...[
                    const SizedBox(height: 8),
                    GlassCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _SliderRow(
                            settingsKey: const Key('IMG-013'),
                            label: 'WDR level',
                            value: _wdrLevel,
                            min:
                                _imagingOptions?.wdrLevel?.min ??
                                _fallbackWdrLevelMin,
                            max:
                                _imagingOptions?.wdrLevel?.max ??
                                _fallbackWdrLevelMax,
                            onChanged: (value) =>
                                _markDirty(() => _wdrLevel = value),
                          ),
                        ],
                      ),
                    ),
                  ],
                ] else if (!_isLoading) ...[
                  const SizedBox(height: 8),
                  Text(
                    'WDR not supported by this camera.',
                    key: const Key('IMG-020'),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
                const SizedBox(height: 16),
                Text(
                  'White balance',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 8),
                SegmentedButton<CameraAutoManual>(
                  key: const Key('IMG-009'),
                  segments: _autoManualSegments(
                    _imagingOptions?.whiteBalanceModes,
                    _whiteBalance,
                  ),
                  selected: {_whiteBalance},
                  showSelectedIcon: false,
                  onSelectionChanged: (selection) =>
                      _markDirty(() => _whiteBalance = selection.first),
                ),
                const SizedBox(height: 16),
                Text('Exposure', style: Theme.of(context).textTheme.bodyMedium),
                const SizedBox(height: 8),
                SegmentedButton<CameraAutoManual>(
                  key: const Key('IMG-010'),
                  segments: _autoManualSegments(
                    _imagingOptions?.exposureModes,
                    _exposure,
                  ),
                  selected: {_exposure},
                  showSelectedIcon: false,
                  onSelectionChanged: (selection) =>
                      _markDirty(() => _exposure = selection.first),
                ),
                // Only meaningful in Manual mode — the camera ignores these
                // in Auto (ImagingSettings.exposureTime/exposureGain are
                // omitted from the Save request outside Manual, see _save).
                if (_exposure == CameraAutoManual.manual) ...[
                  const SizedBox(height: 16),
                  GlassCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Builder(
                          builder: (context) {
                            final range = _imagingOptions?.exposureTime;
                            return _SliderRow(
                              settingsKey: const Key('IMG-018'),
                              label: 'Exposure time',
                              value: _exposureTime,
                              min: range?.min ?? _fallbackExposureTimeMin,
                              max: range?.max ?? _fallbackExposureTimeMax,
                              onChanged: (value) =>
                                  _markDirty(() => _exposureTime = value),
                            );
                          },
                        ),
                        Builder(
                          builder: (context) {
                            final range = _imagingOptions?.exposureGain;
                            return _SliderRow(
                              settingsKey: const Key('IMG-019'),
                              label: 'Exposure gain',
                              value: _exposureGain,
                              min: range?.min ?? _fallbackExposureGainMin,
                              max: range?.max ?? _fallbackExposureGainMax,
                              onChanged: (value) =>
                                  _markDirty(() => _exposureGain = value),
                            );
                          },
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SliderRow extends StatelessWidget {
  const _SliderRow({
    required this.settingsKey,
    required this.label,
    required this.value,
    required this.onChanged,
    this.min = 0,
    this.max = 100,
  });

  final Key settingsKey;
  final String label;
  final double value;
  final double min;
  final double max;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '$label (${value.round()})',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        Slider(
          key: settingsKey,
          value: value.clamp(min, max),
          min: min,
          max: max,
          divisions: (max - min).round().clamp(1, 1000),
          onChanged: onChanged,
        ),
      ],
    );
  }
}
