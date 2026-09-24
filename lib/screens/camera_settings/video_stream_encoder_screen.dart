import 'package:camera_api/camera_api.dart';

import '../../app_state/camera_network.dart';
import 'package:flutter/material.dart';

import '../../app_state/camera_settings_cache.dart';
import '../../app_state/homes_controller.dart';
import '../../app_state/settings_save_verify.dart';
import '../../models/camera.dart';
import '../../widgets/glass_card.dart';
import '../../widgets/gradient_background.dart';
import '../../widgets/navigation_leave_guard.dart';
import '../../widgets/reload_settings_button.dart';
import '../../widgets/saving_overlay.dart';
import '../../widgets/settings_save_button.dart';

/// `CameraEncoderType` <-> ONVIF `"H264"`/`"H265"` wire values.
CameraEncoderType _encoderTypeFromWire(String wire) =>
    wire.toUpperCase() == 'H265'
    ? CameraEncoderType.h265
    : CameraEncoderType.h264;

String _encoderTypeToWire(CameraEncoderType type) => switch (type) {
  CameraEncoderType.h264 => 'H264',
  CameraEncoderType.h265 => 'H265',
};

/// `CameraEncoderProfile` <-> ONVIF `"Baseline"`/`"Main"`/`"High"` wire values.
CameraEncoderProfile? _encoderProfileFromWire(String wire) =>
    switch (wire.toLowerCase()) {
      'baseline' => CameraEncoderProfile.baseline,
      'main' => CameraEncoderProfile.main,
      'high' => CameraEncoderProfile.high,
      _ => null,
    };

String _encoderProfileToWire(CameraEncoderProfile profile) => switch (profile) {
  CameraEncoderProfile.baseline => 'Baseline',
  CameraEncoderProfile.main => 'Main',
  CameraEncoderProfile.high => 'High',
};

String _resolutionLabel(Resolution resolution) =>
    '${resolution.width}×${resolution.height}';

String _streamTitle(VideoStream stream) => switch (stream) {
  VideoStream.highRes => 'High-res Stream',
  VideoStream.medium => 'Medium Stream',
  VideoStream.low => 'Low Stream',
};

/// The real ONVIF/WAN video encoder config token backing each stream —
/// `VideoEncoderCfg_1`/`_2`/`_3` (`Profile_1`/`_2`/`_3`). Generalized
/// 2026-09-11: `OnvifVideoEncoderClient`/`WanVideoEncoderClient` used to be
/// hardcoded to `VideoEncoderCfg_1` (high-res only) — Medium/Low now address
/// the camera's other two configs by token the same way.
String _configTokenFor(VideoStream stream) => switch (stream) {
  VideoStream.highRes => kHighResVideoEncoderToken,
  VideoStream.medium => kMediumResVideoEncoderToken,
  VideoStream.low => kLowResVideoEncoderToken,
};

/// Real bounds for a slider from the camera's own Options response, or a
/// fallback `(min, max)` pair when unverified. A loaded value outside the
/// fallback range would violate `Slider`'s own bounds assertion, so the real
/// range isn't just cosmetic.
(double min, double max) _sliderBounds(
  IntRange? range,
  double fallbackMin,
  double fallbackMax,
) {
  if (range == null) return (fallbackMin, fallbackMax);
  return (range.min.toDouble(), range.max.toDouble());
}

/// Filters [fallback] down to whatever [real] actually reports — never a
/// hardcoded fixed set once the camera is verified — while always keeping
/// [current] in the result so a dropdown's selected value is never outside
/// its own item list. Returns [fallback] unfiltered when [real] is null.
List<T> _optionsOrFallback<T>(Iterable<T>? real, T current, List<T> fallback) {
  if (real == null) return fallback;
  final supported = real.toSet()..add(current);
  return [
    for (final value in fallback)
      if (supported.contains(value)) value,
  ];
}

/// Per-stream encoder settings form — see
/// `docs/screens/camera_settings/video_display/video_stream_encoder_screen.md`.
/// **All three streams are real** (2026-09-11) — backed by
/// `OnvifVideoEncoderClient`/`WanVideoEncoderClient`, each addressing its own
/// `VideoEncoderCfg_N` token ([_configTokenFor]) with a WAN retry per
/// `.claude/rules/mobile-app-screen-conventions.md`. A camera with no saved
/// connection at all still falls back to `simulateCameraSave` for any stream,
/// same as any other settings screen.
class VideoStreamEncoderScreen extends StatefulWidget {
  const VideoStreamEncoderScreen({
    super.key,
    required this.camera,
    required this.homesController,
    required this.stream,
  });

  static const routeName = 'stream';

  final Camera camera;
  final HomesController homesController;
  final VideoStream stream;

  @override
  State<VideoStreamEncoderScreen> createState() =>
      _VideoStreamEncoderScreenState();
}

class _VideoStreamEncoderScreenState extends State<VideoStreamEncoderScreen> {
  late StreamEncoderConfig _config = _camera.encoderConfigFor(widget.stream);
  bool _isDirty = false;
  bool _isSaving = false;

  /// Native pixel size backing [_config.resolution] — loaded from the camera,
  /// needed on Save since the wire format is `(width, height)`, not an enum.

  VideoEncoderSettingsOptions? _encoderOptions;

  late bool _isLoading = _camera.connection != null;

  EncodingOptions? get _currentEncodingOptions =>
      _encoderOptions?.forEncoding(_encoderTypeToWire(_config.encoderType));

  Camera get _camera {
    for (final home in widget.homesController.value.homes) {
      for (final camera in home.cameras) {
        if (camera.id == widget.camera.id) return camera;
      }
    }
    return widget.camera;
  }

  @override
  void initState() {
    super.initState();
    _loadRealVideoEncoder();
  }

  Future<void> _loadRealVideoEncoder() async {
    final connection = _camera.connection;
    if (connection == null) return;
    final configToken = _configTokenFor(widget.stream);
    final client = OnvifVideoEncoderClient(
      connection,
      httpClient: CameraNetwork.clientFor(connection.host),
      endpoint: CameraNetwork.media2EndpointFor(connection.host),
    );
    final results = await Future.wait([
      client.getVideoEncoderSettings(configToken: configToken),
      NetworkAnswerCache.getOrFetch(
        connection.host,
        'videoEncoderOptions:$configToken',
        fetch: () =>
            client.getVideoEncoderSettingsOptions(configToken: configToken),
      ),
    ]);
    CameraNetwork.rememberMedia2Endpoint(
      connection.host,
      client.resolvedEndpoint,
    );
    client.close();

    var settingsResult = results[0] as CameraResult<VideoEncoderSettings>;
    final optionsResult =
        results[1] as CameraResult<VideoEncoderSettingsOptions>;
    debugPrint(
      '[VideoStreamEncoder] LAN getVideoEncoderSettings($configToken) -> $settingsResult',
    );
    debugPrint(
      '[VideoStreamEncoder] getVideoEncoderSettingsOptions($configToken) -> $optionsResult',
    );

    final thingName = connection.thingName;
    if (settingsResult is! CameraSuccess && thingName != null) {
      settingsResult = await WanVideoEncoderClient(
        thingName,
      ).getVideoEncoderSettings(configToken: configToken);
      debugPrint(
        '[VideoStreamEncoder] WAN getVideoEncoderSettings($configToken) -> $settingsResult',
      );
    }
    if (!mounted) return;

    setState(() {
      if (settingsResult case CameraSuccess(:final value)) {
        final profile = _encoderProfileFromWire(value.encoderProfile);
        _config = _config.copyWith(
          encoderType: _encoderTypeFromWire(value.encoding),
          encoderProfile: profile,
          frameRate: value.frameRate.toDouble(),
          govLength: value.govLength.toDouble(),
          quality: value.quality.toDouble(),
          bitrateMode: value.cbr
              ? CameraBitrateMode.cbr
              : CameraBitrateMode.vbr,
          bitrateKbps: value.bitrate.toDouble(),
          resolution: (width: value.width, height: value.height),
        );
      }
      if (optionsResult case CameraSuccess(:final value)) {
        _encoderOptions = value;
      }
      _isLoading = false;
    });

    if (settingsResult case CameraSuccess()) {
      widget.homesController.updateCamera(
        widget.camera.id,
        (camera) => camera.copyWithEncoderConfig(widget.stream, _config),
      );
    }
  }

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
    await _loadRealVideoEncoder();
  }

  void _markDirty(VoidCallback update) {
    setState(() {
      update();
      _isDirty = true;
    });
  }

  void _resetToDefault() {
    _markDirty(() => _config = StreamEncoderConfig.defaultsFor(widget.stream));
  }

  Future<void> _save() async {
    final connection = _camera.connection;
    setState(() => _isSaving = true);

    bool succeeded;
    if (connection != null) {
      final configToken = _configTokenFor(widget.stream);
      final client = OnvifVideoEncoderClient(
        connection,
        httpClient: CameraNetwork.clientFor(connection.host),
        endpoint: CameraNetwork.media2EndpointFor(connection.host),
      );
      // The picked value is already the camera's own pixel pair — no
      // reverse lookup from a bucketed enum needed any more.
      final width = _config.resolution.width;
      final height = _config.resolution.height;
      final settings = VideoEncoderSettings(
        token: configToken,
        bitrate: _config.bitrateKbps.round(),
        frameRate: _config.frameRate.round(),
        govLength: _config.govLength.round(),
        quality: _config.quality.round(),
        encoderProfile: _encoderProfileToWire(_config.encoderProfile),
        width: width,
        height: height,
        encoding: _encoderTypeToWire(_config.encoderType),
        cbr: _config.bitrateMode == CameraBitrateMode.cbr,
      );
      final thingName = connection.thingName;
      final preferWan = _camera.lastKnownWan == true && thingName != null;
      CameraResult<void>? result;
      if (!preferWan) {
        result = await client.setVideoEncoderSettings(settings);
      }
      CameraNetwork.rememberMedia2Endpoint(
        connection.host,
        client.resolvedEndpoint,
      );
      client.close();

      bool viaWan = false;
      if (result is CameraSuccess) {
        succeeded = true;
      } else if (thingName != null) {
        viaWan = true;
        final wanResult = await WanVideoEncoderClient(
          thingName,
        ).setVideoEncoderSettings(settings);
        succeeded = wanResult is CameraSuccess;
      } else {
        succeeded = false;
      }

      if (!succeeded) {
        // This ONVIF/WAN Set can land on the camera with only its reply
        // lost to a timeout — re-read before reporting failure.
        succeeded = await verifyAfterTimeout<VideoEncoderSettings>(
          fetchCurrent: () {
            if (!viaWan) {
              final verifyClient = OnvifVideoEncoderClient(
                connection,
                httpClient: CameraNetwork.clientFor(connection.host),
              );
              return verifyClient
                  .getVideoEncoderSettings(configToken: configToken)
                  .whenComplete(verifyClient.close);
            }
            return WanVideoEncoderClient(
              thingName!,
            ).getVideoEncoderSettings(configToken: configToken);
          },
          matchesExpected: (current) =>
              current.bitrate == settings.bitrate &&
              current.frameRate == settings.frameRate &&
              current.govLength == settings.govLength &&
              current.quality == settings.quality &&
              current.encoderProfile == settings.encoderProfile &&
              current.width == settings.width &&
              current.height == settings.height &&
              current.encoding == settings.encoding &&
              current.cbr == settings.cbr,
        );
      }
    } else {
      succeeded = await simulateCameraSave();
    }

    if (!mounted) return;
    setState(() => _isSaving = false);
    if (succeeded) {
      widget.homesController.updateCamera(
        widget.camera.id,
        (camera) => camera.copyWithEncoderConfig(widget.stream, _config),
      );
      setState(() => _isDirty = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Changes saved')));
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Failed to save changes. Try again.')),
      );
    }
  }

  Future<bool> _confirmLeave() => confirmDiscardOnLeave(
    context: context,
    isDirty: _isDirty,
    onSave: _save,
    isDirtyAfterSave: () => _isDirty,
    dialogKey: const Key('SENC-013'),
    discardKey: const Key('SENC-014'),
    saveKey: const Key('SENC-015'),
  );

  @override
  Widget build(BuildContext context) {
    return LeaveGuard(
      canLeave: _confirmLeave,
      child: GradientBackground(
        child: Scaffold(
          backgroundColor: Colors.transparent,
          appBar: AppBar(
            key: const Key('SENC-001'),
            title: Text(_streamTitle(widget.stream)),
            actions: [
              ReloadSettingsButton(
                settingsKey: const Key('SENC-003'),
                isBusy: _isLoading || _isSaving,
                onPressed: _reloadSettings,
              ),
              SettingsSaveButton(
                settingsKey: const Key('SENC-002'),
                isDirty: _isDirty,
                isSaving: _isSaving,
                onPressed: _save,
              ),
            ],
          ),
          body: SavingOverlay(
            isSaving: _isSaving || _isLoading,
            label: _isLoading ? 'Loading…' : 'Saving…',
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Align(
                  alignment: Alignment.centerRight,
                  child: OutlinedButton(
                    key: const Key('SENC-004'),
                    onPressed: _resetToDefault,
                    child: const Text('Reset to Default'),
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  'Resolution',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 8),
                Builder(
                  builder: (context) {
                    final resolutions = _currentEncodingOptions?.resolutions;
                    if (resolutions != null && resolutions.length <= 1) {
                      return Text(
                        key: const Key('SENC-005'),
                        _resolutionLabel(_config.resolution),
                        style: Theme.of(context).textTheme.bodyLarge,
                      );
                    }
                    // Unlike the enum-backed fields, resolution has no fixed
                    // universe to filter — whatever the camera reports *is*
                    // the list. The current value is always included so the
                    // dropdown's `initialValue` is never outside its items.
                    final available =
                        <Resolution>{
                          ...?resolutions,
                          _config.resolution,
                        }.toList()..sort(
                          (a, b) => (b.width * b.height).compareTo(
                            a.width * a.height,
                          ),
                        );
                    return DropdownButtonFormField<Resolution>(
                      key: const Key('SENC-005'),
                      initialValue: _config.resolution,
                      isExpanded: true,
                      items: [
                        for (final res in available)
                          DropdownMenuItem(
                            value: res,
                            child: Text(
                              _resolutionLabel(res),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                      onChanged: (value) => _markDirty(
                        () => _config = _config.copyWith(resolution: value),
                      ),
                    );
                  },
                ),
                const SizedBox(height: 16),
                Text(
                  'Video encoder',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 8),
                DropdownButtonFormField<CameraEncoderType>(
                  key: const Key('SENC-006'),
                  initialValue: _config.encoderType,
                  isExpanded: true,
                  items: [
                    for (final type in _optionsOrFallback(
                      _encoderOptions?.availableEncodings.map(
                        _encoderTypeFromWire,
                      ),
                      _config.encoderType,
                      CameraEncoderType.values,
                    ))
                      DropdownMenuItem(
                        value: type,
                        child: Text(
                          type == CameraEncoderType.h265 ? 'H.265' : 'H.264',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: (value) => _markDirty(() {
                    _config = _config.copyWith(encoderType: value);
                    // Each encoding has its own supportsCbr — if the new
                    // one doesn't allow CBR, force VBR so SENC-011 never
                    // ends up selecting a value outside its own item list.
                    if (!(_currentEncodingOptions?.supportsCbr ?? true)) {
                      _config = _config.copyWith(
                        bitrateMode: CameraBitrateMode.vbr,
                      );
                    }
                  }),
                ),
                const SizedBox(height: 16),
                Text(
                  'Encoder profile',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 8),
                DropdownButtonFormField<CameraEncoderProfile>(
                  key: const Key('SENC-007'),
                  initialValue: _config.encoderProfile,
                  isExpanded: true,
                  items: [
                    for (final profile in _optionsOrFallback(
                      _currentEncodingOptions?.encoderProfiles
                          .map(_encoderProfileFromWire)
                          .whereType<CameraEncoderProfile>(),
                      _config.encoderProfile,
                      CameraEncoderProfile.values,
                    ))
                      DropdownMenuItem(
                        value: profile,
                        child: Text(switch (profile) {
                          CameraEncoderProfile.baseline => 'Baseline',
                          CameraEncoderProfile.main => 'Main',
                          CameraEncoderProfile.high => 'High',
                        }, overflow: TextOverflow.ellipsis),
                      ),
                  ],
                  onChanged: (value) => _markDirty(
                    () => _config = _config.copyWith(encoderProfile: value),
                  ),
                ),
                const SizedBox(height: 16),
                GlassCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        'Frame rate (${_config.frameRate.round()} fps)',
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                      Builder(
                        builder: (context) {
                          final (min, max) = _sliderBounds(
                            _currentEncodingOptions?.frameRateRange,
                            1,
                            25,
                          );
                          return Slider(
                            key: const Key('SENC-008'),
                            value: _config.frameRate.clamp(min, max),
                            min: min,
                            max: max,
                            divisions: (max - min).round(),
                            onChanged: (value) => _markDirty(
                              () =>
                                  _config = _config.copyWith(frameRate: value),
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                GlassCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        'GOV (${_config.govLength.round()})',
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                      Builder(
                        builder: (context) {
                          final (min, max) = _sliderBounds(
                            _currentEncodingOptions?.govLengthRange,
                            10,
                            50,
                          );
                          return Slider(
                            key: const Key('SENC-009'),
                            value: _config.govLength.clamp(min, max),
                            min: min,
                            max: max,
                            divisions: (max - min).round(),
                            onChanged: (value) => _markDirty(
                              () =>
                                  _config = _config.copyWith(govLength: value),
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                GlassCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        'Quality (${_config.quality.round()})',
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                      Builder(
                        builder: (context) {
                          final (min, max) = _sliderBounds(
                            _currentEncodingOptions?.qualityRange,
                            1,
                            5,
                          );
                          return Slider(
                            key: const Key('SENC-010'),
                            value: _config.quality.clamp(min, max),
                            min: min,
                            max: max,
                            divisions: (max - min).round(),
                            onChanged: (value) => _markDirty(
                              () => _config = _config.copyWith(quality: value),
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  'Bitrate mode',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 8),
                DropdownButtonFormField<CameraBitrateMode>(
                  key: const Key('SENC-011'),
                  initialValue: _config.bitrateMode,
                  isExpanded: true,
                  items: [
                    const DropdownMenuItem(
                      value: CameraBitrateMode.vbr,
                      child: Text(
                        'VBR (Variable)',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (_currentEncodingOptions?.supportsCbr ?? true)
                      const DropdownMenuItem(
                        value: CameraBitrateMode.cbr,
                        child: Text(
                          'CBR (Constant)',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: (value) => _markDirty(
                    () => _config = _config.copyWith(bitrateMode: value),
                  ),
                ),
                const SizedBox(height: 16),
                GlassCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        'Bitrate (${_config.bitrateKbps.round()} kbps)',
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                      Builder(
                        builder: (context) {
                          final (min, max) = _sliderBounds(
                            _currentEncodingOptions?.bitrateRange,
                            32,
                            8192,
                          );
                          return Slider(
                            key: const Key('SENC-012'),
                            value: _config.bitrateKbps.clamp(min, max),
                            min: min,
                            max: max,
                            divisions: (max - min).round(),
                            onChanged: (value) => _markDirty(
                              () => _config = _config.copyWith(
                                bitrateKbps: value,
                              ),
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
