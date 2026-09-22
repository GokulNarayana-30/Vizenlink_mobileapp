import 'dart:async';
import 'dart:typed_data';

import 'package:camera_api/camera_api.dart';

import '../../app_state/camera_network.dart';
import 'package:flutter/material.dart';

import '../../app_state/camera_settings_cache.dart';
import '../../app_state/camera_sync.dart';
import '../../app_state/homes_controller.dart';
import '../../app_state/transport_preference.dart';
import '../../models/camera.dart';
import '../../widgets/drawable_zone.dart';
import '../../widgets/fixed_preview_layout.dart';
import '../../widgets/glass_card.dart';
import '../../widgets/gradient_background.dart';
import '../../widgets/mode_tile.dart';
import '../../widgets/navigation_leave_guard.dart';
import '../../widgets/reload_settings_button.dart';
import '../../widgets/saving_overlay.dart';
import '../../widgets/settings_save_button.dart';

/// `CameraPrivacyMode` <-> `PrivacyMode` (NuraEye `GetPrivacyMode`/
/// `SetPrivacyMode`).
PrivacyMode _toWirePrivacyMode(CameraPrivacyMode mode) => switch (mode) {
  CameraPrivacyMode.off => PrivacyMode.none,
  CameraPrivacyMode.full => PrivacyMode.full,
  CameraPrivacyMode.zone => PrivacyMode.zone,
};

CameraPrivacyMode _fromWirePrivacyMode(PrivacyMode mode) => switch (mode) {
  PrivacyMode.none => CameraPrivacyMode.off,
  PrivacyMode.full => CameraPrivacyMode.full,
  PrivacyMode.zone => CameraPrivacyMode.zone,
};

/// [DrawableZone.rect] is already fractional (0-1, top-left origin, Y-down —
/// see that class's doc) — exactly what `pixelRectToOnvifPolygon`/
/// `onvifPolygonToPixelRect` expect for a 1x1 "pixel" container, so no real
/// preview pixel size is needed for this conversion to be correct.
const _unitContainer = PixelSize(1, 1);

List<OnvifPoint> _zoneToPolygon(Rect rect) => pixelRectToOnvifPolygon(
  PixelRect(
    left: rect.left,
    top: rect.top,
    width: rect.width,
    height: rect.height,
  ),
  _unitContainer,
);

Rect _polygonToZoneRect(List<OnvifPoint> polygon) {
  final pixelRect = onvifPolygonToPixelRect(polygon, _unitContainer);
  return Rect.fromLTWH(
    pixelRect.left,
    pixelRect.top,
    pixelRect.width,
    pixelRect.height,
  );
}

/// Privacy Mode: Off / Full / Zone selector (PRIV-002). Full blocks the
/// entire feed; Zone reveals privacy zones — up to 8 draggable/resizable
/// mask rectangles drawn over regions of the preview (fewer if the camera's
/// own `getMaskOptions().maxMasks` reports a lower limit). Zones can be
/// configured any time but only take effect in Zone mode, so the zones
/// section is only shown then. Backed by real `camera_api` when the camera
/// has a saved connection: `PrivacyModeClient` for the mode, `MaskClient`
/// for the zones themselves (`getMasks`/`createMask`/`setMask`/`deleteMask`
/// — there's no bulk-update call, so Save diffs the zone list against
/// what's on the camera: new zones get `createMask`, edited zones get
/// `setMask` by their server-assigned token, removed zones get
/// `deleteMask`). Falls back to local-only `HomesController` state
/// (`simulateCameraSave`) for a camera with no saved connection yet. LAN is
/// always tried first for both load and save; a WAN retry
/// (`WanPrivacyModeClient`/`WanMaskClient`) only kicks in when the LAN call
/// itself fails/times out and `connection.thingName` is known, per
/// `.claude/rules/mobile-app-screen-conventions.md`'s LAN/WAN convention.
/// Per that same convention, WAN mask *Options* are never fetched on a
/// normal load — only current-value reads (mode, masks) get a WAN
/// fallback there.
class PrivacyModeScreen extends StatefulWidget {
  const PrivacyModeScreen({
    super.key,
    required this.camera,
    required this.homesController,
  });

  static const routeName = 'privacy-mode';

  final Camera camera;
  final HomesController homesController;

  @override
  State<PrivacyModeScreen> createState() => CameraPrivacyModeScreenState();
}

class CameraPrivacyModeScreenState extends State<PrivacyModeScreen> {
  late CameraPrivacyMode _mode = _camera.privacyMode;
  late final List<DrawableZone> _zones = [..._camera.privacyZones];
  int? _selectedZoneId;
  late int _nextZoneId =
      (_zones.isEmpty
          ? 0
          : _zones.map((zone) => zone.id).reduce((a, b) => a > b ? a : b)) +
      1;
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

  /// Server-assigned mask token for each zone that already exists on the
  /// camera — a zone id with no entry here is new (never saved), so Save
  /// knows to `createMask` for it instead of `setMask`.
  final Map<int, String> _maskTokenByZoneId = {};

  /// The camera's own mask capability envelope (`getMaskOptions`) — null
  /// means "camera not verified yet". Used for the real `maxMasks` limit and
  /// the `type`/`color` fields every `createMask`/`setMask` call needs.
  MaskOptions? _maskOptions;

  int get _maxZones => (_maskOptions != null && _maskOptions!.maxMasks > 0)
      ? (_maskOptions!.maxMasks < maxDrawableZones
            ? _maskOptions!.maxMasks
            : maxDrawableZones)
      : maxDrawableZones;

  @override
  void initState() {
    super.initState();
    _loadRealPrivacy();
  }

  Future<void> _loadRealPrivacy({bool forceRefresh = false}) async {
    final connection = _camera.connection;
    if (connection == null) return;
    setState(() => _isLoading = true);
    final nuraeye = NuraeyeClient(connection);
    final maskClient = MaskClient(
      connection,
      httpClient: CameraNetwork.clientFor(connection.host),
      endpoint: CameraNetwork.media2EndpointFor(connection.host),
    );
    final thingName = connection.thingName;
    // Skips the LAN mode/masks attempt entirely when this camera's last
    // confirmed transport was WAN — see Camera.lastKnownWan's doc. Options
    // stays LAN-only regardless (see this class's doc comment).
    final preferWan = _camera.lastKnownWan == true && thingName != null;

    CameraResult<PrivacyMode> modeResult;
    CameraResult<List<MaskEntry>> masksResult;
    final CameraResult<MaskOptions> optionsResult;
    if (preferWan) {
      optionsResult = await NetworkAnswerCache.getOrFetch(
        connection.host,
        'maskOptions',
        fetch: maskClient.getMaskOptions,
        forceRefresh: forceRefresh,
      );
      modeResult = const CameraTimeout<PrivacyMode>();
      masksResult = const CameraTimeout<List<MaskEntry>>();
    } else {
      final results = await Future.wait([
        PrivacyModeClient(nuraeye).getPrivacyMode(),
        maskClient.getMasks(),
        NetworkAnswerCache.getOrFetch(
          connection.host,
          'maskOptions',
          fetch: maskClient.getMaskOptions,
          forceRefresh: forceRefresh,
        ),
      ]);
      modeResult = results[0] as CameraResult<PrivacyMode>;
      masksResult = results[1] as CameraResult<List<MaskEntry>>;
      optionsResult = results[2] as CameraResult<MaskOptions>;
    }
    nuraeye.close();
    CameraNetwork.rememberMedia2Endpoint(
      connection.host,
      maskClient.resolvedEndpoint,
    );
    maskClient.close();

    // Options are LAN-only on a normal load (see this class's doc comment)
    // — only the current-value reads (mode, masks) fall back to WAN here,
    // in parallel (previously sequential).
    if (thingName != null) {
      final needsMode = modeResult is! CameraSuccess;
      final needsMasks = masksResult is! CameraSuccess;
      if (needsMode || needsMasks) {
        final wanResults = await Future.wait([
          needsMode
              ? WanPrivacyModeClient(thingName).getPrivacyMode()
              : Future.value(null),
          needsMasks ? WanMaskClient(thingName).getMasks() : Future.value(null),
        ]);
        if (needsMode) {
          modeResult = wanResults[0] as CameraResult<PrivacyMode>;
        }
        if (needsMasks) {
          masksResult = wanResults[1] as CameraResult<List<MaskEntry>>;
        }
      }
    }
    if (!mounted) return;

    setState(() {
      if (modeResult case CameraSuccess(:final value)) {
        _mode = _fromWirePrivacyMode(value);
      }
      if (masksResult case CameraSuccess(:final value)) {
        _zones.clear();
        _maskTokenByZoneId.clear();
        _selectedZoneId = null;
        var nextId = 0;
        for (final mask in value) {
          final id = nextId++;
          _zones.add(
            DrawableZone(id: id, rect: _polygonToZoneRect(mask.polygon)),
          );
          _maskTokenByZoneId[id] = mask.token;
        }
        _nextZoneId = nextId;
      }
      if (optionsResult case CameraSuccess(:final value)) {
        _maskOptions = value;
      }
      _isLoading = false;
    });

    widget.homesController.updateCamera(
      widget.camera.id,
      (camera) =>
          camera.copyWith(privacyMode: _mode, privacyZones: [..._zones]),
    );
  }

  /// Manual reload — re-fetches mode/masks from the camera and force-refreshes
  /// the cached mask options (bypassing `MaskClient.getMaskOptions`'s
  /// process-lifetime cache, since this is exactly the explicit user-requested
  /// case that cache's own doc calls out), for when a change made elsewhere
  /// (another client, the camera's own web UI) hasn't shown up here yet.
  Future<void> _reloadSettings() async {
    if (_camera.connection == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No saved connection for this camera yet'),
        ),
      );
      return;
    }
    await _loadRealPrivacy(forceRefresh: true);
  }

  void _markDirty(VoidCallback update) {
    setState(() {
      update();
      _isDirty = true;
    });
  }

  void _addZone() {
    if (_zones.length >= _maxZones) return;
    final offset = 0.03 * (_zones.length % 4);
    _addZoneAt(
      Rect.fromLTWH(
        0.1 + offset,
        0.1 + offset,
        defaultZoneSize.dx,
        defaultZoneSize.dy,
      ),
    );
  }

  /// Shared by [_addZone] (PRIV-006's fixed default position) and
  /// [ZoneDrawSurface]'s draw-directly-on-the-preview gesture (PRIV-014),
  /// which computes its own [rect] from where the user drew.
  void _addZoneAt(Rect rect) {
    if (_zones.length >= _maxZones) return;
    final id = _nextZoneId++;
    _markDirty(() {
      _zones.add(DrawableZone(id: id, rect: rect));
      _selectedZoneId = id;
    });
  }

  void _selectZone(int id) {
    setState(() => _selectedZoneId = id);
  }

  void _deleteZone(int id) {
    _markDirty(() {
      _zones.removeWhere((zone) => zone.id == id);
      if (_selectedZoneId == id) _selectedZoneId = null;
    });
  }

  void _deleteSelectedZone() {
    final id = _selectedZoneId;
    if (id == null) return;
    _deleteZone(id);
  }

  void _clearAllZones() {
    if (_zones.isEmpty) return;
    _markDirty(() {
      _zones.clear();
      _selectedZoneId = null;
    });
  }

  void _updateZoneRect(int id, Rect rect) {
    _markDirty(() {
      final index = _zones.indexWhere((zone) => zone.id == id);
      if (index == -1) return;
      _zones[index] = _zones[index].copyWith(rect: rect);
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
      final modeResult = await callPreferringKnownTransport(
        camera: _camera,
        thingName: thingName,
        lan: () async {
          final nuraeye = NuraeyeClient(connection);
          final result = await PrivacyModeClient(
            nuraeye,
          ).setPrivacyMode(_toWirePrivacyMode(_mode));
          nuraeye.close();
          return result;
        },
        wan: () => WanPrivacyModeClient(
          thingName!,
        ).setPrivacyMode(_toWirePrivacyMode(_mode)),
      );

      final maskClient = MaskClient(
        connection,
        httpClient: CameraNetwork.clientFor(connection.host),
        endpoint: CameraNetwork.media2EndpointFor(connection.host),
      );
      final wanMaskClient = thingName != null ? WanMaskClient(thingName) : null;
      // Skips each LAN mask attempt below entirely when this camera's last
      // confirmed transport was WAN — see Camera.lastKnownWan's doc.
      final preferWan = _camera.lastKnownWan == true && wanMaskClient != null;
      // ONVIF masks have no bulk-update call — diff the zone list against
      // what's already on the camera (tracked in _maskTokenByZoneId).
      final maskType = _maskOptions != null && _maskOptions!.types.isNotEmpty
          ? _maskOptions!.types.first
          : 'Color';
      final maskColor =
          _maskOptions != null && _maskOptions!.colorList.isNotEmpty
          ? _maskOptions!.colorList.first
          : null;
      var masksOk = true;

      final currentZoneIds = _zones.map((zone) => zone.id).toSet();
      final removedZoneIds = _maskTokenByZoneId.keys
          .where((id) => !currentZoneIds.contains(id))
          .toList();
      for (final id in removedZoneIds) {
        final token = _maskTokenByZoneId[id]!;
        CameraResult<void>? result;
        if (!preferWan) result = await maskClient.deleteMask(token);
        if (result is! CameraSuccess && wanMaskClient != null) {
          result = await wanMaskClient.deleteMask(token);
        }
        if (result is CameraSuccess) {
          _maskTokenByZoneId.remove(id);
        } else {
          masksOk = false;
        }
      }

      for (final zone in _zones) {
        final polygon = _zoneToPolygon(zone.rect);
        final existingToken = _maskTokenByZoneId[zone.id];
        if (existingToken != null) {
          CameraResult<void>? result;
          if (!preferWan) {
            result = await maskClient.setMask(
              token: existingToken,
              polygon: polygon,
              enabled: true,
              type: maskType,
              color: maskColor,
            );
          }
          if (result is! CameraSuccess && wanMaskClient != null) {
            result = await wanMaskClient.setMask(
              token: existingToken,
              polygon: polygon,
              enabled: true,
              type: maskType,
              color: maskColor,
            );
          }
          if (result is! CameraSuccess) masksOk = false;
        } else {
          CameraResult<String>? result;
          if (!preferWan) {
            result = await maskClient.createMask(
              polygon: polygon,
              enabled: true,
              type: maskType,
              color: maskColor,
            );
          }
          // WAN's setMask (not a separate createMask) handles creation too
          // — an empty/omitted token creates a new mask, per its own doc.
          if (result is! CameraSuccess && wanMaskClient != null) {
            result = await wanMaskClient.setMask(
              polygon: polygon,
              enabled: true,
              type: maskType,
              color: maskColor,
            );
          }
          if (result case CameraSuccess(:final value)) {
            _maskTokenByZoneId[zone.id] = value;
          } else {
            masksOk = false;
          }
        }
      }
      CameraNetwork.rememberMedia2Endpoint(
        connection.host,
        maskClient.resolvedEndpoint,
      );
      maskClient.close();

      succeeded = modeResult is CameraSuccess && masksOk;
    } else {
      succeeded = await simulateCameraSave();
    }

    if (!mounted) return;
    setState(() => _isSaving = false);
    if (succeeded) {
      widget.homesController.updateCamera(
        widget.camera.id,
        (camera) =>
            camera.copyWith(privacyMode: _mode, privacyZones: [..._zones]),
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
    dialogKey: const Key('PRIV-011'),
    discardKey: const Key('PRIV-012'),
    saveKey: const Key('PRIV-013'),
  );

  @override
  Widget build(BuildContext context) {
    return LeaveGuard(
      canLeave: _confirmLeave,
      child: GradientBackground(
        child: Scaffold(
          backgroundColor: Colors.transparent,
          appBar: AppBar(
            key: const Key('PRIV-001'),
            title: const Text('Privacy Mode'),
            actions: [
              ReloadSettingsButton(
                settingsKey: const Key('PRIV-015'),
                isBusy: _isLoading || _isSaving,
                onPressed: _reloadSettings,
              ),
              SettingsSaveButton(
                settingsKey: const Key('PRIV-010'),
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
                  _PrivacyPreview(
                    key: ValueKey(_previewReloadKey),
                    settingsKey: const Key('PRIV-004'),
                    camera: _camera,
                    overrideBytes: _wanPreviewBytes,
                    mode: _mode,
                    zones: _zones,
                    maxZones: _maxZones,
                    selectedZoneId: _selectedZoneId,
                    onZoneSelected: _selectZone,
                    onZoneRectChanged: _updateZoneRect,
                    onZoneDrawn: _addZoneAt,
                  ),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton.icon(
                      key: const Key('PRIV-005'),
                      onPressed: _isRefreshing ? null : _refreshPreview,
                      icon: _isRefreshing
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.refresh, size: 18),
                      label: const Text('Refresh preview'),
                    ),
                  ),
                ],
              ),
              scrollableChildren: [
                Row(
                  key: const Key('PRIV-002'),
                  children: [
                    Expanded(
                      child: ModeTile(
                        icon: Icons.visibility_outlined,
                        label: 'Off',
                        selected: _mode == CameraPrivacyMode.off,
                        onTap: () =>
                            _markDirty(() => _mode = CameraPrivacyMode.off),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: ModeTile(
                        icon: Icons.visibility_off,
                        label: 'Full',
                        selected: _mode == CameraPrivacyMode.full,
                        onTap: () =>
                            _markDirty(() => _mode = CameraPrivacyMode.full),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: ModeTile(
                        icon: Icons.crop_square,
                        label: 'Zone',
                        selected: _mode == CameraPrivacyMode.zone,
                        onTap: () =>
                            _markDirty(() => _mode = CameraPrivacyMode.zone),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Text(key: const Key('PRIV-003'), switch (_mode) {
                    CameraPrivacyMode.off =>
                      'Privacy mode is off — the camera streams and '
                          'records normally.',
                    CameraPrivacyMode.full =>
                      'This camera stops streaming and recording video '
                          'and audio entirely until a different mode is '
                          'selected.',
                    CameraPrivacyMode.zone =>
                      'Only the privacy zones below are masked — the rest '
                          'of the feed streams and records normally.',
                  }, style: Theme.of(context).textTheme.bodySmall),
                ),
                if (_mode == CameraPrivacyMode.zone) ...[
                  const SizedBox(height: 24),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Privacy zones (${_zones.length}/$_maxZones)',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ),
                      TextButton.icon(
                        key: const Key('PRIV-006'),
                        onPressed: _zones.length < _maxZones ? _addZone : null,
                        icon: const Icon(Icons.add, size: 18),
                        label: const Text('Add zone'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  if (_zones.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Text(
                        'No privacy zones yet. Tap "Add zone", or drag '
                        'directly on the preview above, to mask a region.',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    )
                  else
                    GlassCard(
                      padding: EdgeInsets.zero,
                      child: Column(
                        key: const Key('PRIV-007'),
                        children: [
                          for (var i = 0; i < _zones.length; i++)
                            ZoneListTile(
                              label: 'Zone ${i + 1}',
                              icon: Icons.crop_square,
                              selected: _zones[i].id == _selectedZoneId,
                              onTap: () => _selectZone(_zones[i].id),
                              onDelete: () => _deleteZone(_zones[i].id),
                              isLast: i == _zones.length - 1,
                            ),
                        ],
                      ),
                    ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          key: const Key('PRIV-008'),
                          onPressed: _selectedZoneId != null
                              ? _deleteSelectedZone
                              : null,
                          icon: const Icon(Icons.delete_outline, size: 18),
                          label: const Text('Delete selected'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: OutlinedButton.icon(
                          key: const Key('PRIV-009'),
                          onPressed: _zones.isNotEmpty ? _clearAllZones : null,
                          icon: const Icon(Icons.clear_all, size: 18),
                          label: const Text('Clear all'),
                        ),
                      ),
                    ],
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

class _PrivacyPreview extends StatelessWidget {
  const _PrivacyPreview({
    super.key,
    required this.settingsKey,
    required this.camera,
    this.overrideBytes,
    required this.mode,
    required this.zones,
    required this.maxZones,
    required this.selectedZoneId,
    required this.onZoneSelected,
    required this.onZoneRectChanged,
    required this.onZoneDrawn,
  });

  final Key settingsKey;
  final Camera camera;

  /// See `CameraPreviewThumbnail.overrideBytes`'s doc — same
  /// never-persisted transient-frame contract.
  final Uint8List? overrideBytes;
  final CameraPrivacyMode mode;
  final List<DrawableZone> zones;
  final int maxZones;
  final int? selectedZoneId;
  final ValueChanged<int> onZoneSelected;
  final void Function(int id, Rect rect) onZoneRectChanged;
  final ValueChanged<Rect> onZoneDrawn;

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      padding: EdgeInsets.zero,
      borderRadius: 20,
      child: AspectRatio(
        aspectRatio: 16 / 9,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: Stack(
            key: settingsKey,
            children: [
              CameraImage(camera: camera, overrideBytes: overrideBytes),
              if (mode == CameraPrivacyMode.full)
                const Positioned.fill(child: _FullBlackoutOverlay())
              else
                Positioned.fill(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final areaSize = constraints.biggest;
                      return Stack(
                        clipBehavior: Clip.hardEdge,
                        children: [
                          ZoneDrawSurface(
                            key: const Key('PRIV-014'),
                            areaSize: areaSize,
                            enabled:
                                mode == CameraPrivacyMode.zone &&
                                zones.length < maxZones,
                            onZoneDrawn: onZoneDrawn,
                          ),
                          // Real bug fix: zones only take effect in Zone
                          // mode (per this widget's own doc comment), but
                          // these overlays used to render unconditionally —
                          // they stayed visible and draggable on the preview
                          // even while Privacy Mode was Off, which reads as
                          // "the camera is masking regions" when it isn't.
                          if (mode == CameraPrivacyMode.zone)
                            for (final zone in zones)
                              ZoneOverlay(
                                key: ValueKey(zone.id),
                                rect: zone.rect,
                                areaSize: areaSize,
                                selected: zone.id == selectedZoneId,
                                icon: Icons.visibility_off,
                                onTap: () => onZoneSelected(zone.id),
                                onRectChanged: (rect) =>
                                    onZoneRectChanged(zone.id, rect),
                              ),
                        ],
                      );
                    },
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Full opaque blackout shown over the preview when Privacy Mode is set to
/// Full — the entire feed is blocked, so the preview reflects that instead
/// of still showing the camera image underneath.
class _FullBlackoutOverlay extends StatelessWidget {
  const _FullBlackoutOverlay();

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Colors.black,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.visibility_off,
              color: Colors.white.withValues(alpha: 0.6),
              size: 32,
            ),
            const SizedBox(height: 8),
            Text(
              'Privacy Mode: Full',
              style: TextStyle(
                fontFamily: 'Manrope',
                fontWeight: FontWeight.w600,
                color: Colors.white.withValues(alpha: 0.8),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
