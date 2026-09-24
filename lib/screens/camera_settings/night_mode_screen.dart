import 'dart:async';
import 'dart:typed_data';

import 'package:camera_api/camera_api.dart';
import 'package:flutter/material.dart';

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

/// `CameraNightMode` <-> `NightVisionType` (`grey` = Infrared, `color` = Full
/// Color, `smart` = Smart).
NightVisionType _nightModeToType(CameraNightMode mode) => switch (mode) {
  CameraNightMode.infrared => NightVisionType.grey,
  CameraNightMode.fullColor => NightVisionType.color,
  CameraNightMode.smart => NightVisionType.smart,
};

CameraNightMode _typeToNightMode(NightVisionType type) => switch (type) {
  NightVisionType.grey => CameraNightMode.infrared,
  NightVisionType.color => CameraNightMode.fullColor,
  NightVisionType.smart => CameraNightMode.smart,
};

/// Night Mode: preview thumbnail plus Infrared/Smart/Full Color selection,
/// backed by `NightVisionClient` (`GetNightVisionType`/`SetNightVisionType`)
/// when this camera has a saved connection — falls back to local-only
/// `HomesController` state (via `simulateCameraSave`) otherwise, same as
/// before. LAN is always tried first for both load and save; a WAN retry
/// (`WanNightVisionClient`) only kicks in when the LAN call itself
/// fails/times out and `connection.thingName` is known, per
/// `.claude/rules/mobile-app-screen-conventions.md`'s LAN/WAN convention.
class NightModeScreen extends StatefulWidget {
  const NightModeScreen({
    super.key,
    required this.camera,
    required this.homesController,
  });

  static const routeName = 'night-mode';

  final Camera camera;
  final HomesController homesController;

  @override
  State<NightModeScreen> createState() => _NightModeScreenState();
}

class _NightModeScreenState extends State<NightModeScreen> {
  late CameraNightMode _mode = _camera.nightMode;
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

  /// Hardware/firmware capability flags from the camera's own
  /// `GetNightVisionType` response — null means "camera not verified yet",
  /// in which case every tile shows (same fallback reasoning as
  /// `_dummyTimezones` in camera_info_screen). Unlike Video Mode, no
  /// separate Options call exists for this — the capability flags ride
  /// along with the current-value response itself.
  late bool? _colorCapable = _camera.nightVisionColorCapable;
  late bool? _smartCapable = _camera.nightVisionSmartCapable;

  /// True only while a saved connection exists and its `GetNightVisionType`
  /// response hasn't landed yet — gates the Smart/Full Color tiles so they
  /// never render off a stale/guessed capability flag and then flicker once
  /// the real answer arrives. No connection means there's nothing to wait
  /// for, so this starts `false` and the tiles fall back to "show both"
  /// (see the `_smartCapable`/`_colorCapable` doc above).
  late bool _isLoading = _camera.connection != null;

  /// Which tiles the camera's own response explicitly ruled out — only
  /// populated once [_isLoading] is `false`, so this never flashes based on
  /// a stale or unverified guess.
  List<String> get _unsupportedNightModeFeatures => [
    if (_smartCapable == false) 'Smart',
    if (_colorCapable == false) 'Full Color',
  ];

  @override
  void initState() {
    super.initState();
    _loadRealNightMode();
  }

  Future<void> _loadRealNightMode() async {
    final connection = _camera.connection;
    if (connection == null) return;
    final thingName = connection.thingName;
    final result = await callPreferringKnownTransport(
      camera: _camera,
      thingName: thingName,
      lan: () async {
        final nuraeye = NuraeyeClient(connection);
        final result = await NightVisionClient(nuraeye).getNightVisionType();
        nuraeye.close();
        return result;
      },
      wan: () => WanNightVisionClient(thingName!).getNightVisionType(),
    );
    if (!mounted) return;
    if (result case CameraSuccess(:final value)) {
      setState(() {
        _mode = _typeToNightMode(value.type);
        _colorCapable = value.colorCapable;
        _smartCapable = value.smartCapable;
        _isLoading = false;
      });
      widget.homesController.updateCamera(
        widget.camera.id,
        (camera) => camera.copyWith(
          nightMode: _typeToNightMode(value.type),
          nightVisionColorCapable: value.colorCapable,
          nightVisionSmartCapable: value.smartCapable,
        ),
      );
    } else {
      setState(() => _isLoading = false);
    }
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
    await _loadRealNightMode();
  }

  void _onModeChanged(CameraNightMode? value) {
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
          final nuraeye = NuraeyeClient(connection);
          final result = await NightVisionClient(
            nuraeye,
          ).setNightVisionType(_nightModeToType(_mode));
          nuraeye.close();
          return result;
        },
        wan: () => WanNightVisionClient(
          thingName!,
        ).setNightVisionType(_nightModeToType(_mode)),
      );
      // Same reasoning as every other screen using this pattern — a Set that
      // succeeded on the camera can still miss its own 10s-timeout reply.
      succeeded =
          result is CameraSuccess ||
          await verifyAfterTimeout<NightVisionType>(
            fetchCurrent: () async {
              final nuraeye = NuraeyeClient(connection);
              final result = await NightVisionClient(
                nuraeye,
              ).getNightVisionType();
              nuraeye.close();
              if (result is CameraSuccess<NightVisionStatus>) {
                return CameraSuccess(result.value.type);
              }
              if (thingName == null) {
                return const CameraFailure<NightVisionType>(
                  'no WAN fallback available',
                );
              }
              final wanResult = await WanNightVisionClient(
                thingName,
              ).getNightVisionType();
              if (wanResult case CameraSuccess<NightVisionStatus>(
                :final value,
              )) {
                return CameraSuccess(value.type);
              }
              return const CameraFailure<NightVisionType>('timed out');
            },
            matchesExpected: (current) => current == _nightModeToType(_mode),
          );
    } else {
      succeeded = await simulateCameraSave();
    }

    if (!mounted) return;
    setState(() => _isSaving = false);
    if (succeeded) {
      widget.homesController.updateCamera(
        widget.camera.id,
        (camera) => camera.copyWith(nightMode: _mode),
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
    dialogKey: const Key('NIGHT-008'),
    discardKey: const Key('NIGHT-009'),
    saveKey: const Key('NIGHT-010'),
  );

  @override
  Widget build(BuildContext context) {
    return LeaveGuard(
      canLeave: _confirmLeave,
      child: GradientBackground(
        child: Scaffold(
          backgroundColor: Colors.transparent,
          appBar: AppBar(
            key: const Key('NIGHT-001'),
            title: const Text('Night Mode'),
            actions: [
              ReloadSettingsButton(
                settingsKey: const Key('NIGHT-012'),
                isBusy: _isLoading || _isSaving,
                onPressed: _reloadSettings,
              ),
              SettingsSaveButton(
                settingsKey: const Key('NIGHT-004'),
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
                    settingsKey: const Key('NIGHT-005'),
                    camera: _camera,
                    overrideBytes: _wanPreviewBytes,
                  ),
                  const SizedBox(height: 8),
                  RefreshPreviewButton(
                    settingsKey: const Key('NIGHT-007'),
                    isRefreshing: _isRefreshing,
                    onPressed: _refreshPreview,
                  ),
                ],
              ),
              scrollableChildren: [
                Row(
                  key: const Key('NIGHT-006'),
                  children: [
                    // Infrared (grey) is the baseline capability, always
                    // shown. Smart/Full Color are gated on the camera's own
                    // reported capability flags — never hardcoded — per
                    // .claude/rules/mobile-app-screen-conventions.md. Shows
                    // both when unverified (no connection yet, `null`).
                    for (final entry in [
                      (
                        CameraNightMode.infrared,
                        Icons.nightlight,
                        'Infrared',
                        true,
                      ),
                      (
                        CameraNightMode.smart,
                        Icons.auto_awesome,
                        'Smart',
                        _smartCapable != false,
                      ),
                      (
                        CameraNightMode.fullColor,
                        Icons.palette,
                        'Full Color',
                        _colorCapable != false,
                      ),
                    ])
                      if (entry.$4) ...[
                        Expanded(
                          child: ModeTile(
                            icon: entry.$2,
                            label: entry.$3,
                            selected: _mode == entry.$1,
                            onTap: () => _onModeChanged(entry.$1),
                          ),
                        ),
                        if (entry.$1 != CameraNightMode.fullColor)
                          const SizedBox(width: 12),
                      ],
                  ],
                ),
                if (!_isLoading &&
                    _unsupportedNightModeFeatures.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    'Not supported by this camera: '
                    '${_unsupportedNightModeFeatures.join(', ')}',
                    key: const Key('NIGHT-011'),
                    style: Theme.of(context).textTheme.bodySmall,
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
