import 'dart:typed_data';

import 'package:camera_api/camera_api.dart';
import 'package:flutter/material.dart';

import '../../app_state/camera_sync.dart';
import '../../app_state/homes_controller.dart';
import '../../app_state/settings_save_verify.dart';
import '../../app_state/transport_preference.dart';
import '../../models/camera.dart';
import '../../widgets/drawable_zone.dart';
import '../../widgets/fixed_preview_layout.dart';
import '../../widgets/glass_card.dart';
import '../../widgets/gradient_background.dart';
import '../../widgets/navigation_leave_guard.dart';
import '../../widgets/reload_settings_button.dart';
import '../../widgets/saving_overlay.dart';
import '../../widgets/settings_save_button.dart';

/// Person Detection: an enable toggle, confidence-threshold slider, a
/// loitering-duration slider, a detection-box overlay toggle, and up to 8
/// free-form polygon exclusion zones drawn over regions of the preview —
/// person detection ignores movement inside these zones (e.g. a street or a
/// neighbor's yard visible in frame) and still detects normally everywhere
/// else.
///
/// **Enable toggle, loitering duration, and bbox overlay are real**
/// (`EventPreferencesClient`/`LoiteringDurationClient`/`BboxOverlayClient`
/// over LAN, WAN counterparts via `callPreferringKnownTransport` — added
/// 2026-09-08, closing the `ui-api-gap-audit` findings for this screen).
/// Confidence threshold and exclusion zones stay local-only (persisted
/// through [HomesController], see `updateCamera`) — no camera API exists for
/// either yet, same as the note on `videoMode` in `lib/models/camera.dart`.
/// Loitering duration's bounds always come from
/// `CameraCapabilities.loiteringDurationMinSeconds`/`MaxSeconds`, never
/// hardcoded; the bbox overlay toggle hides (not disables) when the camera
/// reports `bboxOverlayCapable == false`, same hardware-gate convention
/// `audio_screen.dart`'s hasMicrophone/hasSpeaker checks use.
class PersonDetectionScreen extends StatefulWidget {
  const PersonDetectionScreen({
    super.key,
    required this.camera,
    required this.homesController,
  });

  static const routeName = 'person-detection';

  final Camera camera;
  final HomesController homesController;

  @override
  State<PersonDetectionScreen> createState() => _PersonDetectionScreenState();
}

class _PersonDetectionScreenState extends State<PersonDetectionScreen> {
  late bool _enabled = widget.camera.personDetectionEnabled;
  late double _confidence = widget.camera.personDetectionConfidence;
  late final List<PolygonZone> _zones = [...widget.camera.personDetectionZones];
  PolygonZone? _draftZone;
  int? _selectedZoneId;
  late int _nextZoneId =
      (_zones.isEmpty
          ? 0
          : _zones.map((zone) => zone.id).reduce((a, b) => a > b ? a : b)) +
      1;
  bool _isDirty = false;
  bool _isSaving = false;
  bool _isLoading = false;
  bool _isRefreshing = false;
  int _previewReloadKey = 0;
  Uint8List? _wanPreviewBytes;

  /// Loitering duration's real bounds (`CameraCapabilities.
  /// loiteringDurationMinSeconds`/`MaxSeconds`) — the slider is hidden until
  /// these have actually loaded (`_loiteringBoundsLoaded`), same convention
  /// `storage_screen.dart`'s clip-duration slider already uses.
  int _loiteringDurationMinSeconds = 0;
  int _loiteringDurationMaxSeconds = 0;
  bool get _loiteringBoundsLoaded =>
      _loiteringDurationMaxSeconds > _loiteringDurationMinSeconds;
  late int _loiteringDurationSeconds =
      widget.camera.loiteringDurationSeconds ?? 0;

  /// Whether the camera draws its AI bounding-box overlay — null means
  /// "not yet verified", same fallback reasoning `night_mode_screen.dart`'s
  /// `nightVisionColorCapable` already uses elsewhere in this app: every
  /// control shows until proven otherwise.
  bool? _bboxOverlayCapable;
  late bool _bboxOverlayEnabled = widget.camera.bboxOverlayEnabled ?? false;

  void _markDirty(VoidCallback update) {
    setState(() {
      update();
      _isDirty = true;
    });
  }

  void _addPoint() {
    if (_zones.length + (_draftZone == null ? 0 : 1) >= maxDrawableZones &&
        _draftZone == null) {
      return;
    }
    _markDirty(() {
      final draft = _draftZone ?? PolygonZone(id: _nextZoneId++, points: []);
      final stagger = polygonPointStagger * draft.points.length;
      final point = Offset(
        (polygonPointBaseOffset.dx + stagger).clamp(0.0, 1.0),
        (polygonPointBaseOffset.dy + stagger).clamp(0.0, 1.0),
      );
      _draftZone = draft.copyWith(points: [...draft.points, point]);
      _selectedZoneId = draft.id;
    });
  }

  void _finishZone() {
    final draft = _draftZone;
    if (draft == null || !draft.isClosed) return;
    _markDirty(() {
      _zones.add(draft);
      _draftZone = null;
    });
  }

  void _cancelDraftZone() {
    _markDirty(() {
      _draftZone = null;
      _selectedZoneId = null;
    });
  }

  void _updateVertex(int vertexIndex, Offset offset) {
    _markDirty(() {
      if (_draftZone != null) {
        final points = [..._draftZone!.points];
        points[vertexIndex] = offset;
        _draftZone = _draftZone!.copyWith(points: points);
        return;
      }
      final index = _zones.indexWhere((zone) => zone.id == _selectedZoneId);
      if (index == -1) return;
      final points = [..._zones[index].points];
      points[vertexIndex] = offset;
      _zones[index] = _zones[index].copyWith(points: points);
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
    if (_zones.isEmpty && _draftZone == null) return;
    _markDirty(() {
      _zones.clear();
      _draftZone = null;
      _selectedZoneId = null;
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

  @override
  void initState() {
    super.initState();
    _loadRealPersonDetection();
  }

  /// Fetches the enable flag, loitering-duration bounds/value, and
  /// bbox-overlay state from the real camera — LAN first, WAN fallback via
  /// [callPreferringKnownTransport]. No-op (silently) when this camera has
  /// no saved connection yet, same as every other real settings screen.
  Future<void> _loadRealPersonDetection() async {
    final connection = _camera.connection;
    if (connection == null) return;
    final thingName = connection.thingName;

    setState(() => _isLoading = true);
    final nuraeye = NuraeyeClient(connection);
    // Capabilities (bounds + the bbox-overlay capability flag) have no WAN
    // equivalent — every `GetCapabilities`-sourced field is LAN-only per
    // `IotCommandClient`'s own doc, same reasoning `camera_sync.dart`'s
    // `syncCameraFromDevice` already documents. LAN-only, no WAN fallback.
    final results = await Future.wait([
      CapabilitiesClient(nuraeye).getCapabilities(),
      callPreferringKnownTransport(
        camera: _camera,
        thingName: thingName,
        lan: () => EventPreferencesClient(nuraeye).getEventPreferences(),
        wan: () => WanEventPreferencesClient(thingName!).getEventPreferences(),
      ),
      callPreferringKnownTransport(
        camera: _camera,
        thingName: thingName,
        lan: () => LoiteringDurationClient(nuraeye).getLoiteringDuration(),
        wan: () =>
            WanLoiteringDurationClient(thingName!).getLoiteringDuration(),
      ),
      callPreferringKnownTransport(
        camera: _camera,
        thingName: thingName,
        lan: () => BboxOverlayClient(nuraeye).isBboxOverlayEnabled(),
        wan: () => WanBboxOverlayClient(thingName!).isBboxOverlayEnabled(),
      ),
    ]);
    nuraeye.close();
    if (!mounted) return;

    final capsResult = results[0] as CameraResult<CameraCapabilities>;
    final enabledResult = results[1] as CameraResult<Map<String, bool>>;
    final loiteringResult = results[2] as CameraResult<int>;
    final bboxResult = results[3] as CameraResult<bool>;

    bool? enabled;
    int? loiteringSeconds;
    bool? bboxEnabled;
    setState(() {
      if (capsResult case CameraSuccess(:final value)) {
        _loiteringDurationMinSeconds = value.loiteringDurationMinSeconds;
        _loiteringDurationMaxSeconds = value.loiteringDurationMaxSeconds;
        _bboxOverlayCapable = value.bboxOverlayCapable;
      }
      if (enabledResult case CameraSuccess(:final value)) {
        enabled = value['PersonDetected'];
        if (enabled != null) _enabled = enabled!;
      }
      if (loiteringResult case CameraSuccess(:final value)) {
        loiteringSeconds = value;
        _loiteringDurationSeconds = value;
      }
      if (bboxResult case CameraSuccess(:final value)) {
        bboxEnabled = value;
        _bboxOverlayEnabled = value;
      }
      // Real bug, guarded against: if the bounds loaded but the actual
      // duration fetch above failed/timed out, `_loiteringDurationSeconds`
      // could still be sitting at its pre-bounds-known default (0) — below
      // a real camera's min bound. `Slider` asserts `value` is within
      // `min`/`max`, so displaying it unclamped here would crash the whole
      // screen the moment bounds load without the value itself loading too.
      if (_loiteringBoundsLoaded) {
        _loiteringDurationSeconds = _loiteringDurationSeconds.clamp(
          _loiteringDurationMinSeconds,
          _loiteringDurationMaxSeconds,
        );
      }
      _isLoading = false;
    });
    widget.homesController.updateCamera(
      widget.camera.id,
      (camera) => camera.copyWith(
        personDetectionEnabled: enabled,
        loiteringDurationSeconds: loiteringSeconds,
        bboxOverlayEnabled: bboxEnabled,
      ),
    );
  }

  /// Manual reload — re-fetches this screen's real fields from the camera,
  /// for when a change made elsewhere (another client, the camera's own web
  /// UI) hasn't shown up here yet. Distinct from [_save] (pushes local
  /// edits).
  Future<void> _reloadSettings() async {
    if (_camera.connection == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No saved connection for this camera yet'),
        ),
      );
      return;
    }
    await _loadRealPersonDetection();
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
    // LAN/WAN convention.
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
      // Only push fields that actually changed from the last
      // camera-confirmed value — mobile-app-screen-conventions.md's Apply
      // convention (see audio_screen.dart's own `_save` for the same
      // pattern). Confidence and zones have no camera API yet, so they
      // always stay local-only.
      final thingName = connection.thingName;
      final enabledChanged = _enabled != _camera.personDetectionEnabled;
      final loiteringChanged =
          _loiteringBoundsLoaded &&
          _loiteringDurationSeconds != _camera.loiteringDurationSeconds;
      final bboxChanged =
          _bboxOverlayCapable != false &&
          _bboxOverlayEnabled != _camera.bboxOverlayEnabled;

      final nuraeye = NuraeyeClient(connection);
      final results = <CameraResult<void>>[];
      if (enabledChanged) {
        var result = await callPreferringKnownTransport(
          camera: _camera,
          thingName: thingName,
          lan: () => EventPreferencesClient(
            nuraeye,
          ).setEventPreferences({'PersonDetected': _enabled}),
          wan: () => WanEventPreferencesClient(
            thingName!,
          ).setEventPreferences({'PersonDetected': _enabled}),
        );
        if (result is! CameraSuccess) {
          // Same "camera applied it, reply was just lost" case
          // privacy_mode_screen.dart's mask verify handles — SetXxx here has
          // no retry on the same transport before the LAN/WAN fallback.
          final verified = await verifyAfterTimeout<Map<String, bool>>(
            fetchCurrent: () => callPreferringKnownTransport(
              camera: _camera,
              thingName: thingName,
              lan: () => EventPreferencesClient(nuraeye).getEventPreferences(),
              wan: () =>
                  WanEventPreferencesClient(thingName!).getEventPreferences(),
            ),
            matchesExpected: (current) => current['PersonDetected'] == _enabled,
          );
          if (verified) result = const CameraSuccess(null);
        }
        results.add(result);
      }
      if (loiteringChanged) {
        var result = await callPreferringKnownTransport(
          camera: _camera,
          thingName: thingName,
          lan: () => LoiteringDurationClient(
            nuraeye,
          ).setLoiteringDuration(_loiteringDurationSeconds),
          wan: () => WanLoiteringDurationClient(
            thingName!,
          ).setLoiteringDuration(_loiteringDurationSeconds),
        );
        if (result is! CameraSuccess) {
          final verified = await verifyAfterTimeout<int>(
            fetchCurrent: () => callPreferringKnownTransport(
              camera: _camera,
              thingName: thingName,
              lan: () =>
                  LoiteringDurationClient(nuraeye).getLoiteringDuration(),
              wan: () =>
                  WanLoiteringDurationClient(thingName!).getLoiteringDuration(),
            ),
            matchesExpected: (current) => current == _loiteringDurationSeconds,
          );
          if (verified) result = const CameraSuccess(null);
        }
        results.add(result);
      }
      if (bboxChanged) {
        var result = await callPreferringKnownTransport(
          camera: _camera,
          thingName: thingName,
          lan: () => BboxOverlayClient(
            nuraeye,
          ).setBboxOverlayEnabled(_bboxOverlayEnabled),
          wan: () => WanBboxOverlayClient(
            thingName!,
          ).setBboxOverlayEnabled(_bboxOverlayEnabled),
        );
        if (result is! CameraSuccess) {
          final verified = await verifyAfterTimeout<bool>(
            fetchCurrent: () => callPreferringKnownTransport(
              camera: _camera,
              thingName: thingName,
              lan: () => BboxOverlayClient(nuraeye).isBboxOverlayEnabled(),
              wan: () =>
                  WanBboxOverlayClient(thingName!).isBboxOverlayEnabled(),
            ),
            matchesExpected: (current) => current == _bboxOverlayEnabled,
          );
          if (verified) result = const CameraSuccess(null);
        }
        results.add(result);
      }
      nuraeye.close();
      succeeded = results.every((r) => r is CameraSuccess);
    } else {
      succeeded = await simulateCameraSave();
    }

    if (!mounted) return;
    setState(() => _isSaving = false);
    if (succeeded) {
      widget.homesController.updateCamera(
        widget.camera.id,
        (camera) => camera.copyWith(
          personDetectionEnabled: _enabled,
          personDetectionConfidence: _confidence,
          personDetectionZones: [..._zones],
          loiteringDurationSeconds: _loiteringBoundsLoaded
              ? _loiteringDurationSeconds
              : null,
          bboxOverlayEnabled: _bboxOverlayCapable != false
              ? _bboxOverlayEnabled
              : null,
        ),
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
    dialogKey: const Key('PERSON-013'),
    discardKey: const Key('PERSON-014'),
    saveKey: const Key('PERSON-015'),
  );

  @override
  Widget build(BuildContext context) {
    final totalZones = _zones.length + (_draftZone == null ? 0 : 1);

    return LeaveGuard(
      canLeave: _confirmLeave,
      child: GradientBackground(
        child: Scaffold(
          backgroundColor: Colors.transparent,
          appBar: AppBar(
            key: const Key('PERSON-001'),
            title: const Text('Person Detection'),
            actions: [
              ReloadSettingsButton(
                settingsKey: const Key('PERSON-017'),
                isBusy: _isLoading || _isSaving,
                onPressed: _reloadSettings,
              ),
              SettingsSaveButton(
                settingsKey: const Key('PERSON-002'),
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
                  _PersonPreview(
                    key: ValueKey(_previewReloadKey),
                    settingsKey: const Key('PERSON-006'),
                    camera: _camera,
                    zones: _zones,
                    draftZone: _draftZone,
                    selectedZoneId: _selectedZoneId,
                    onVertexChanged: _updateVertex,
                    overrideBytes: _wanPreviewBytes,
                  ),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton.icon(
                      key: const Key('PERSON-007'),
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
                GlassCard(
                  padding: EdgeInsets.zero,
                  child: SwitchListTile(
                    key: const Key('PERSON-003'),
                    title: const Text('Person detection'),
                    value: _enabled,
                    onChanged: (value) => _markDirty(() => _enabled = value),
                  ),
                ),
                const SizedBox(height: 12),
                GlassCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        'Confidence threshold (${_confidence.round()})',
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                      Slider(
                        key: const Key('PERSON-004'),
                        value: _confidence,
                        min: 0,
                        max: 100,
                        divisions: 100,
                        onChanged: _enabled
                            ? (value) => _markDirty(() => _confidence = value)
                            : null,
                      ),
                    ],
                  ),
                ),
                if (_loiteringBoundsLoaded) ...[
                  const SizedBox(height: 12),
                  GlassCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          'Alert after lingering for '
                          '(${_loiteringDurationSeconds}s)',
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                        Text(
                          'How long someone has to stay in frame before a '
                          'Loitering event fires — independent of whether '
                          'person detection above is on',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        Slider(
                          key: const Key('PERSON-016'),
                          value: _loiteringDurationSeconds.toDouble(),
                          min: _loiteringDurationMinSeconds.toDouble(),
                          max: _loiteringDurationMaxSeconds.toDouble(),
                          divisions:
                              _loiteringDurationMaxSeconds -
                              _loiteringDurationMinSeconds,
                          onChanged: (value) => _markDirty(
                            () => _loiteringDurationSeconds = value.round(),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                if (_bboxOverlayCapable != false) ...[
                  const SizedBox(height: 12),
                  GlassCard(
                    padding: EdgeInsets.zero,
                    child: SwitchListTile(
                      key: const Key('PERSON-018'),
                      title: const Text('Show detection box on video'),
                      subtitle: const Text(
                        'Draws the AI\'s detection box on the live feed and '
                        'recordings',
                      ),
                      value: _bboxOverlayEnabled,
                      onChanged: (value) =>
                          _markDirty(() => _bboxOverlayEnabled = value),
                    ),
                  ),
                ],
                const SizedBox(height: 24),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Exclusion zones ($totalZones/$maxDrawableZones)',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                    TextButton.icon(
                      key: const Key('PERSON-008'),
                      onPressed: totalZones < maxDrawableZones
                          ? _addPoint
                          : null,
                      icon: const Icon(Icons.add, size: 18),
                      label: const Text('Add point'),
                    ),
                  ],
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Text(
                    'Excludes person detection inside these areas (e.g. a '
                    'street or neighbor\'s yard) — detection still runs '
                    'normally everywhere else.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                if (_draftZone != null) ...[
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          key: const Key('PERSON-009'),
                          onPressed: _draftZone!.isClosed ? _finishZone : null,
                          icon: const Icon(Icons.check, size: 18),
                          label: Text(
                            _draftZone!.isClosed
                                ? 'Finish zone'
                                : 'Add ${minPolygonPoints - _draftZone!.points.length} more point(s)',
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      OutlinedButton(
                        onPressed: _cancelDraftZone,
                        child: const Text('Cancel'),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 8),
                if (_zones.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Text(
                      'No exclusion zones yet. Tap "Add point" to start '
                      'outlining a region to ignore (3+ points, then Finish '
                      'zone).',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  )
                else
                  GlassCard(
                    padding: EdgeInsets.zero,
                    child: Column(
                      key: const Key('PERSON-010'),
                      children: [
                        for (var i = 0; i < _zones.length; i++)
                          PolygonZoneListTile(
                            label: 'Zone ${i + 1}',
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
                        key: const Key('PERSON-011'),
                        onPressed: _selectedZoneId != null && _draftZone == null
                            ? _deleteSelectedZone
                            : null,
                        icon: const Icon(Icons.delete_outline, size: 18),
                        label: const Text('Delete selected'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: OutlinedButton.icon(
                        key: const Key('PERSON-012'),
                        onPressed: totalZones > 0 ? _clearAllZones : null,
                        icon: const Icon(Icons.clear_all, size: 18),
                        label: const Text('Clear all'),
                      ),
                    ),
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

class _PersonPreview extends StatelessWidget {
  const _PersonPreview({
    super.key,
    required this.settingsKey,
    required this.camera,
    required this.zones,
    required this.draftZone,
    required this.selectedZoneId,
    required this.onVertexChanged,
    this.overrideBytes,
  });

  final Key settingsKey;
  final Camera camera;
  final List<PolygonZone> zones;
  final PolygonZone? draftZone;
  final int? selectedZoneId;
  final void Function(int vertexIndex, Offset offset) onVertexChanged;
  final Uint8List? overrideBytes;

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
              Positioned.fill(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final areaSize = constraints.biggest;
                    return Stack(
                      clipBehavior: Clip.hardEdge,
                      children: [
                        for (final zone in zones)
                          PolygonOverlay(
                            key: ValueKey(zone.id),
                            zone: zone,
                            areaSize: areaSize,
                            selected: zone.id == selectedZoneId,
                            onVertexChanged: (index, offset) =>
                                onVertexChanged(index, offset),
                          ),
                        if (draftZone != null)
                          PolygonOverlay(
                            key: ValueKey(draftZone!.id),
                            zone: draftZone!,
                            areaSize: areaSize,
                            selected: true,
                            onVertexChanged: onVertexChanged,
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
