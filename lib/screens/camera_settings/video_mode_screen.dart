import 'dart:async';
import 'dart:typed_data';

import 'package:camera_api/camera_api.dart';

import '../../app_state/camera_network.dart';
import 'package:flutter/material.dart';

import '../../app_state/camera_settings_cache.dart';
import '../../app_state/camera_sync.dart';
import '../../app_state/homes_controller.dart';
import '../../app_state/settings_save_verify.dart';
import '../../app_state/transport_preference.dart';
import '../../models/camera.dart';
import '../../widgets/camera_preview_thumbnail.dart';
import '../../widgets/fixed_preview_layout.dart';
import '../../widgets/gradient_background.dart';
import '../../widgets/mode_tile.dart';
import '../../widgets/navigation_leave_guard.dart';
import '../../widgets/refresh_preview_button.dart';
import '../../widgets/reload_settings_button.dart';
import '../../widgets/saving_overlay.dart';
import '../../widgets/settings_save_button.dart';

/// `CameraVideoMode` <-> ONVIF `IrCutFilter` wire values (`ON` = day, `OFF` =
/// night, `AUTO` = auto) — see `OnvifImagingClient.ImagingSettings
/// .irCutFilterMode`'s doc.
String _videoModeToIrCutFilter(CameraVideoMode mode) => switch (mode) {
  CameraVideoMode.day => 'ON',
  CameraVideoMode.night => 'OFF',
  CameraVideoMode.auto => 'AUTO',
};

CameraVideoMode? _irCutFilterToVideoMode(String? wireValue) =>
    switch (wireValue?.toUpperCase()) {
      'ON' => CameraVideoMode.day,
      'OFF' => CameraVideoMode.night,
      'AUTO' => CameraVideoMode.auto,
      _ => null,
    };

/// Video Mode: preview thumbnail plus Day/Auto/Night selection, backed by
/// ONVIF's `IrCutFilter` setting (`OnvifImagingClient`) when this camera has
/// a saved connection — falls back to local-only `HomesController` state
/// (via `simulateCameraSave`) otherwise, same as before. LAN is always tried
/// first for both load and save; a WAN retry (`WanImagingClient
/// .getDayNightMode`/`getImagingOptions`/`setDayNightMode`) only kicks in
/// when the LAN call itself fails/times out and `connection.thingName` is
/// known, per `.claude/rules/mobile-app-screen-conventions.md`'s LAN/WAN
/// convention.
class VideoModeScreen extends StatefulWidget {
  const VideoModeScreen({
    super.key,
    required this.camera,
    required this.homesController,
  });

  static const routeName = 'video-mode';

  final Camera camera;
  final HomesController homesController;

  @override
  State<VideoModeScreen> createState() => _VideoModeScreenState();
}

class _VideoModeScreenState extends State<VideoModeScreen> {
  late CameraVideoMode _mode = _camera.videoMode;
  bool _isDirty = false;
  bool _isSaving = false;
  bool _isRefreshing = false;
  bool _isLoading = false;
  int _previewReloadKey = 0;

  /// A transient WAN preview fetched when [_refreshPreview]'s LAN attempt
  /// fails — never persisted (see `fetchWanPreviewSnapshot`'s doc), just
  /// held here for as long as this screen is open. Cleared once a LAN
  /// refresh succeeds again, so the persisted (and now fresher) thumbnail
  /// takes back over.
  Uint8List? _wanPreviewBytes;

  /// The camera's own supported `IrCutFilter` values (`OnvifImagingClient
  /// .getImagingOptions`), fetched once a connection is available. Null
  /// means "camera not verified yet" — show every tile rather than none,
  /// same reasoning as `_dummyTimezones`'s fallback in camera_info_screen.
  List<String>? _irCutFilterModes;

  @override
  void initState() {
    super.initState();
    _loadRealVideoMode();
  }

  Future<void> _loadRealVideoMode() async {
    final connection = _camera.connection;
    if (connection == null) return;
    setState(() => _isLoading = true);
    final client = OnvifImagingClient(
      connection,
      httpClient: CameraNetwork.clientFor(connection.host),
    );
    final results = await Future.wait([
      client.getImagingSettings(),
      NetworkAnswerCache.getOrFetch(
        connection.host,
        'imagingOptions',
        fetch: client.getImagingOptions,
      ),
    ]);
    client.close();

    final settingsResult = results[0] as CameraResult<ImagingSettings>;
    final optionsResult = results[1] as CameraResult<ImagingOptions>;

    // Options/capability queries are LAN-only on a normal load — WAN
    // Options are only ever fetched as a recovery step right after a failed
    // WAN Set (see _save), not here — per
    // .claude/rules/mobile-app-screen-conventions.md item 4. Only the
    // current-value read gets a WAN fallback.
    final thingName = connection.thingName;
    String? wanMode;
    if (settingsResult is! CameraSuccess && thingName != null) {
      final wanResult = await WanImagingClient(thingName).getDayNightMode();
      if (wanResult case CameraSuccess(:final value)) wanMode = value;
    }
    if (!mounted) return;

    setState(() {
      if (settingsResult case CameraSuccess(:final value)) {
        final mode = _irCutFilterToVideoMode(value.irCutFilterMode);
        if (mode != null) _mode = mode;
      } else if (wanMode != null) {
        final mode = _irCutFilterToVideoMode(wanMode);
        if (mode != null) _mode = mode;
      }
      if (optionsResult case CameraSuccess(:final value)) {
        _irCutFilterModes = value.irCutFilterModes;
      }
      _isLoading = false;
    });

    if (settingsResult is CameraSuccess || wanMode != null) {
      widget.homesController.updateCamera(
        widget.camera.id,
        (camera) => camera.copyWith(videoMode: _mode),
      );
    }
  }

  /// Manual reload — re-fetches this screen's fields from the camera, for
  /// when a change made elsewhere (another client, the camera's own web UI)
  /// hasn't shown up here yet. Distinct from [_save] (pushes local edits).
  Future<void> _reloadSettings() async {
    if (_camera.connection == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No saved connection for this camera yet'),
        ),
      );
      return;
    }
    await _loadRealVideoMode();
  }

  void _onModeChanged(CameraVideoMode? value) {
    if (value == null) return;
    setState(() {
      _mode = value;
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
      // A failed LAN Apply/Set retries over WAN before surfacing an error
      // (or WAN is called directly when known — see Camera.lastKnownWan's
      // doc), per mobile-app-screen-conventions.md's LAN/WAN convention.
      final result = await callPreferringKnownTransport(
        camera: _camera,
        thingName: thingName,
        lan: () async {
          final client = OnvifImagingClient(
            connection,
            httpClient: CameraNetwork.clientFor(connection.host),
          );
          final result = await client.setImagingSettings(
            ImagingSettings(irCutFilterMode: _videoModeToIrCutFilter(_mode)),
          );
          client.close();
          return result;
        },
        wan: () => WanImagingClient(
          thingName!,
        ).setDayNightMode(_videoModeToIrCutFilter(_mode)),
      );
      // The ONVIF SetImagingSettings/WAN SetDayNightMode call this camera can
      // apply and still miss its own 10s-timeout reply with — re-read the
      // effective mode before reporting failure rather than assuming
      // rejection.
      succeeded =
          result is CameraSuccess ||
          await verifyAfterTimeout<String?>(
            fetchCurrent: () async {
              final client = OnvifImagingClient(
                connection,
                httpClient: CameraNetwork.clientFor(connection.host),
              );
              final result = await client.getImagingSettings();
              client.close();
              if (result is CameraSuccess<ImagingSettings>) {
                return CameraSuccess(result.value.irCutFilterMode);
              }
              if (thingName == null) {
                return const CameraFailure<String?>(
                  'no WAN fallback available',
                );
              }
              return WanImagingClient(thingName).getDayNightMode();
            },
            matchesExpected: (current) =>
                current == _videoModeToIrCutFilter(_mode),
          );
    } else {
      succeeded = await simulateCameraSave();
    }

    if (!mounted) return;
    setState(() => _isSaving = false);
    if (succeeded) {
      widget.homesController.updateCamera(
        widget.camera.id,
        (camera) => camera.copyWith(videoMode: _mode),
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

  Future<bool> _confirmLeave() => confirmDiscardOnLeave(
    context: context,
    isDirty: _isDirty,
    onSave: _save,
    isDirtyAfterSave: () => _isDirty,
    dialogKey: const Key('VIDMODE-008'),
    discardKey: const Key('VIDMODE-009'),
    saveKey: const Key('VIDMODE-010'),
  );

  @override
  Widget build(BuildContext context) {
    return LeaveGuard(
      canLeave: _confirmLeave,
      child: GradientBackground(
        child: Scaffold(
          backgroundColor: Colors.transparent,
          appBar: AppBar(
            key: const Key('VIDMODE-001'),
            title: const Text('Video Mode'),
            actions: [
              ReloadSettingsButton(
                settingsKey: const Key('VIDMODE-011'),
                isBusy: _isLoading || _isSaving,
                onPressed: _reloadSettings,
              ),
              SettingsSaveButton(
                settingsKey: const Key('VIDMODE-005'),
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
                    settingsKey: const Key('VIDMODE-003'),
                    camera: _camera,
                    overrideBytes: _wanPreviewBytes,
                  ),
                  const SizedBox(height: 8),
                  RefreshPreviewButton(
                    settingsKey: const Key('VIDMODE-007'),
                    isRefreshing: _isRefreshing,
                    onPressed: _refreshPreview,
                  ),
                ],
              ),
              scrollableChildren: [
                Row(
                  key: const Key('VIDMODE-004'),
                  children: [
                    for (final entry in [
                      (CameraVideoMode.day, Icons.wb_sunny, 'Day'),
                      (CameraVideoMode.auto, Icons.brightness_auto, 'Auto'),
                      (CameraVideoMode.night, Icons.nightlight_round, 'Night'),
                    ])
                      // Only render a mode this camera's own Options response
                      // actually reports — never a hardcoded fixed set, per
                      // .claude/rules/mobile-app-screen-conventions.md. Shows
                      // all three when unverified (no connection yet).
                      if (_irCutFilterModes == null ||
                          _irCutFilterModes!.contains(
                            _videoModeToIrCutFilter(entry.$1),
                          )) ...[
                        Expanded(
                          child: ModeTile(
                            icon: entry.$2,
                            label: entry.$3,
                            selected: _mode == entry.$1,
                            onTap: () => _onModeChanged(entry.$1),
                          ),
                        ),
                        if (entry.$1 != CameraVideoMode.night)
                          const SizedBox(width: 12),
                      ],
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
