import 'package:camera_api/camera_api.dart' hide RecordingScheduleWindow;
import 'package:camera_api/camera_api.dart'
    as wire
    show RecordingScheduleWindow;
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../app_state/homes_controller.dart';
import '../../app_state/settings_save_verify.dart';
import '../../app_state/transport_preference.dart';
import '../../models/camera.dart';
import '../../widgets/glass_card.dart';
import '../../widgets/gradient_background.dart';
import '../../widgets/navigation_leave_guard.dart';
import '../../widgets/reload_settings_button.dart';
import '../../widgets/saving_overlay.dart';
import '../../widgets/settings_save_button.dart';
import 'detections_screen.dart';

/// `RecordingStatus` <-> `RecordingMode` — `null` for [RecordingStatus.off],
/// which has no wire representation at all: `SETTINGS_API_GUIDE.md`'s own
/// "Recording Mode" entry is explicit that Off is a different concept
/// entirely — the separate Local Storage on/off toggle on
/// `storage_screen.dart` (`FR-CF-044`), not a fourth `RecordingMode` value.
///
/// This screen presents both as one radio group, so [_save] and [_loadReal]
/// keep them coherent: choosing Off disables Local Storage without touching
/// whatever `RecordingMode` is configured underneath (so turning storage
/// back on later resumes that mode rather than forcing reconfiguration);
/// choosing a real mode re-enables Local Storage first if it was off, then
/// sets that mode. On load, Off is shown whenever Local Storage is
/// confirmed disabled, regardless of what `RecordingMode` the camera
/// reports underneath — matching what's functionally true (no new footage
/// either way) over what's merely configured.
RecordingMode? _toWireMode(RecordingStatus status) => switch (status) {
  RecordingStatus.continuous => RecordingMode.continuous,
  RecordingStatus.scheduled => RecordingMode.scheduled,
  RecordingStatus.eventTriggered => RecordingMode.eventTriggered,
  RecordingStatus.off => null,
};

RecordingStatus _fromWireMode(RecordingMode mode) => switch (mode) {
  RecordingMode.continuous => RecordingStatus.continuous,
  RecordingMode.scheduled => RecordingStatus.scheduled,
  RecordingMode.eventTriggered => RecordingStatus.eventTriggered,
};

/// `RecordingScheduleDay` (this screen's Monday-first app enum) <->
/// `dayOfWeek` (the wire's `0`=Sunday..`6`=Saturday convention, per
/// `recording_mode_types.dart`'s own doc).
int _dayToWire(RecordingScheduleDay day) => switch (day) {
  RecordingScheduleDay.sunday => 0,
  RecordingScheduleDay.monday => 1,
  RecordingScheduleDay.tuesday => 2,
  RecordingScheduleDay.wednesday => 3,
  RecordingScheduleDay.thursday => 4,
  RecordingScheduleDay.friday => 5,
  RecordingScheduleDay.saturday => 6,
};

RecordingScheduleDay? _dayFromWire(int value) => switch (value) {
  0 => RecordingScheduleDay.sunday,
  1 => RecordingScheduleDay.monday,
  2 => RecordingScheduleDay.tuesday,
  3 => RecordingScheduleDay.wednesday,
  4 => RecordingScheduleDay.thursday,
  5 => RecordingScheduleDay.friday,
  6 => RecordingScheduleDay.saturday,
  _ => null,
};

List<wire.RecordingScheduleWindow> _scheduleToWire(
  List<RecordingScheduleWindow> windows,
) => [
  for (final w in windows)
    wire.RecordingScheduleWindow(
      dayOfWeek: _dayToWire(w.day),
      startMinute: w.startMinutes,
      endMinute: w.endMinutes,
    ),
];

/// Malformed entries (an unrecognized `dayOfWeek`) are dropped rather than
/// crashing the screen — same defensive posture as every other real
/// settings screen's wire-to-app mapping.
List<RecordingScheduleWindow> _scheduleFromWire(
  List<wire.RecordingScheduleWindow> windows,
) => [
  for (final w in windows)
    if (_dayFromWire(w.dayOfWeek) case final day?)
      RecordingScheduleWindow(
        day: day,
        startMinutes: w.startMinute,
        endMinutes: w.endMinute,
      ),
];

/// Order-insensitive — a Set followed by a Get has no guarantee the camera
/// echoes windows back in the order they were sent.
bool _scheduleListEquals(
  List<RecordingScheduleWindow> a,
  List<wire.RecordingScheduleWindow> b,
) {
  if (a.length != b.length) return false;
  final remaining = List.of(_scheduleToWire(a));
  for (final entry in b) {
    final index = remaining.indexWhere(
      (w) =>
          w.dayOfWeek == entry.dayOfWeek &&
          w.startMinute == entry.startMinute &&
          w.endMinute == entry.endMinute,
    );
    if (index == -1) return false;
    remaining.removeAt(index);
  }
  return true;
}

const _modeLabels = {
  RecordingStatus.continuous: 'Continuous',
  RecordingStatus.scheduled: 'Scheduled',
  RecordingStatus.eventTriggered: 'Event-Triggered',
  RecordingStatus.off: 'Off',
};

const _modeDescriptions = {
  RecordingStatus.continuous: 'Records around the clock',
  RecordingStatus.scheduled: 'Records only during the windows set below',
  RecordingStatus.eventTriggered: 'Records when a detection fires',
  RecordingStatus.off: 'No new footage is recorded',
};

const _dayLabels = {
  RecordingScheduleDay.monday: 'Monday',
  RecordingScheduleDay.tuesday: 'Tuesday',
  RecordingScheduleDay.wednesday: 'Wednesday',
  RecordingScheduleDay.thursday: 'Thursday',
  RecordingScheduleDay.friday: 'Friday',
  RecordingScheduleDay.saturday: 'Saturday',
  RecordingScheduleDay.sunday: 'Sunday',
};

String _formatMinutes(int minutes) {
  final time = TimeOfDay(hour: minutes ~/ 60, minute: minutes % 60);
  final hour = time.hourOfPeriod == 0 ? 12 : time.hourOfPeriod;
  final minute = time.minute.toString().padLeft(2, '0');
  final period = time.period == DayPeriod.am ? 'AM' : 'PM';
  return '$hour:$minute $period';
}

/// Local recording-mode settings: Continuous / Scheduled / Event-Triggered /
/// Off, with a day/time schedule editor (Scheduled) and a warning if
/// Event-Triggered has no detection type enabled on this camera yet.
/// Persisted through [HomesController.updateCamera] — see the note on
/// `videoMode` in `lib/models/camera.dart`. Reached directly from camera
/// settings (not nested under Video & Display).
class RecordingScreen extends StatefulWidget {
  const RecordingScreen({
    super.key,
    required this.camera,
    required this.homesController,
  });

  static const routeName = 'recording';

  final Camera camera;
  final HomesController homesController;

  @override
  State<RecordingScreen> createState() => _RecordingScreenState();
}

class _RecordingScreenState extends State<RecordingScreen> {
  Camera get _camera => widget.camera;

  RecordingStatus _mode = RecordingStatus.off;
  List<RecordingScheduleWindow> _scheduleWindows = [];
  bool _isDirty = false;
  bool _isSaving = false;

  /// True only while a saved connection exists and its own
  /// `GetRecordingMode`/`GetCapabilities` responses haven't landed yet —
  /// same "don't render off a stale/guessed value" reasoning as every other
  /// real settings screen's `_isLoading`.
  bool _isLoading = false;

  /// This SKU's supported modes (`CapabilitiesClient.getCapabilities()`,
  /// LAN-only — options/capability queries never go over WAN except as
  /// Set-failure recovery, per the screen-conventions rule). Null means
  /// "not verified yet" — every mode shows in that case, same fallback
  /// reasoning as `_dummyTimezones`/`_colorCapable` elsewhere. Off is never
  /// gated by this list — it isn't a wire mode at all (see `_toWireMode`).
  List<RecordingMode>? _supportedModes;

  /// `CameraCapabilities.maxRecordingScheduleWindows` — caps "Add window".
  /// Defaults to this firmware's fixed compile-time bound (see that field's
  /// own doc) until the real capabilities response lands.
  int _maxScheduleWindows = 14;

  bool get _hasAnyDetectionEnabled =>
      _camera.motionDetectionEnabled ||
      _camera.intrusionDetectionEnabled ||
      _camera.lineCrossingEnabled ||
      _camera.personDetectionEnabled ||
      _camera.vehicleDetectionEnabled;

  List<RecordingStatus> get _availableModes {
    final supported = _supportedModes;
    return [
      for (final status in RecordingStatus.values)
        if (status == _mode ||
            status == RecordingStatus.off ||
            supported == null ||
            supported.contains(_toWireMode(status)))
          status,
    ];
  }

  @override
  void initState() {
    super.initState();
    _mode = _camera.recordingStatus;
    _scheduleWindows = [..._camera.recordingScheduleWindows];
    _loadReal();
  }

  Future<void> _loadReal() async {
    final connection = _camera.connection;
    if (connection == null) return;
    setState(() => _isLoading = true);

    final nuraeye = NuraeyeClient(connection);
    final results = await Future.wait([
      RecordingModeClient(nuraeye).getMode(),
      CapabilitiesClient(nuraeye).getCapabilities(),
      LocalStorageClient(nuraeye).getStatus(),
    ]);
    nuraeye.close();

    var modeResult = results[0] as CameraResult<RecordingModeStatus>;
    final capsResult = results[1] as CameraResult<CameraCapabilities>;
    var storageResult = results[2] as CameraResult<LocalStorageStatus>;

    final thingName = connection.thingName;
    if (modeResult is! CameraSuccess && thingName != null) {
      modeResult = await WanRecordingModeClient(thingName).getMode();
    }
    if (storageResult is! CameraSuccess && thingName != null) {
      storageResult = await WanLocalStorageClient(thingName).getStatus();
    }

    if (!mounted) return;
    setState(() {
      _isLoading = false;
      if (modeResult case CameraSuccess(:final value)) {
        _mode = _fromWireMode(value.mode);
        _scheduleWindows = _scheduleFromWire(value.schedule);
      }
      // Off shown whenever storage is confirmed disabled, regardless of
      // what RecordingMode the camera reports underneath — see this
      // class's own doc comment for why. A storage-status fetch failure
      // leaves whatever _mode the RecordingMode fetch above already set.
      if (storageResult case CameraSuccess(:final value)) {
        if (!value.enabled) {
          _mode = RecordingStatus.off;
        } else if (_mode == RecordingStatus.off) {
          // Storage is on but _mode was never set from a real RecordingMode
          // fetch (e.g. that call failed) — Off would be a lie here, since
          // Off's whole meaning is "storage is disabled". Fall back to the
          // camera's default rather than show a state that isn't true.
          _mode = RecordingStatus.continuous;
        }
      }
      if (capsResult case CameraSuccess(:final value)) {
        _supportedModes = value.supportedRecordingModes;
        _maxScheduleWindows = value.maxRecordingScheduleWindows;
      }
    });
  }

  void _markDirty(VoidCallback update) {
    setState(() {
      update();
      _isDirty = true;
    });
  }

  bool _overlaps(RecordingScheduleWindow a, RecordingScheduleWindow b) {
    if (a.day != b.day) return false;
    return a.startMinutes < b.endMinutes && b.startMinutes < a.endMinutes;
  }

  Future<void> _openWindowDialog({RecordingScheduleWindow? editing}) async {
    var day = editing?.day ?? RecordingScheduleDay.monday;
    var start = editing?.startMinutes ?? 8 * 60;
    var end = editing?.endMinutes ?? 18 * 60;
    String? error;

    final result = await showDialog<RecordingScheduleWindow>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: Text(editing == null ? 'Add window' : 'Edit window'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              DropdownButtonFormField<RecordingScheduleDay>(
                key: const Key('REC-008-day'),
                initialValue: day,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Day'),
                items: [
                  for (final d in RecordingScheduleDay.values)
                    DropdownMenuItem(
                      value: d,
                      child: Text(
                        _dayLabels[d]!,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: (value) => setDialogState(() => day = value ?? day),
              ),
              const SizedBox(height: 12),
              ListTile(
                key: const Key('REC-008-start'),
                contentPadding: EdgeInsets.zero,
                title: const Text('Start time'),
                trailing: Text(_formatMinutes(start)),
                onTap: () async {
                  final picked = await showTimePicker(
                    context: dialogContext,
                    initialTime: TimeOfDay(
                      hour: start ~/ 60,
                      minute: start % 60,
                    ),
                  );
                  if (picked != null) {
                    setDialogState(
                      () => start = picked.hour * 60 + picked.minute,
                    );
                  }
                },
              ),
              ListTile(
                key: const Key('REC-008-end'),
                contentPadding: EdgeInsets.zero,
                title: const Text('End time'),
                trailing: Text(_formatMinutes(end)),
                onTap: () async {
                  final picked = await showTimePicker(
                    context: dialogContext,
                    initialTime: TimeOfDay(hour: end ~/ 60, minute: end % 60),
                  );
                  if (picked != null) {
                    setDialogState(
                      () => end = picked.hour * 60 + picked.minute,
                    );
                  }
                },
              ),
              if (error != null) ...[
                const SizedBox(height: 8),
                Text(
                  error!,
                  style: TextStyle(
                    color: Theme.of(dialogContext).colorScheme.error,
                  ),
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                if (end <= start) {
                  setDialogState(
                    () => error = 'End time must be after start time',
                  );
                  return;
                }
                final candidate = RecordingScheduleWindow(
                  day: day,
                  startMinutes: start,
                  endMinutes: end,
                );
                final conflicts = _scheduleWindows.any(
                  (w) => w != editing && _overlaps(w, candidate),
                );
                if (conflicts) {
                  setDialogState(
                    () => error =
                        'This overlaps another window on ${_dayLabels[day]}',
                  );
                  return;
                }
                Navigator.of(dialogContext).pop(candidate);
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );

    if (result == null) return;
    _markDirty(() {
      if (editing != null) _scheduleWindows.remove(editing);
      _scheduleWindows.add(result);
    });
  }

  /// Sets Local Storage enabled/disabled — the wire counterpart of Off — and
  /// verifies against a re-read on a timeout the same way [_setRecordingMode]
  /// does. Returns `true` only once the camera's own state confirms [enabled].
  Future<bool> _setStorageEnabled(
    CameraConnection connection,
    bool enabled,
  ) async {
    final thingName = connection.thingName;
    final result = await callPreferringKnownTransport(
      camera: _camera,
      thingName: thingName,
      lan: () {
        final nuraeye = NuraeyeClient(connection);
        final result = LocalStorageClient(nuraeye).setEnabled(enabled);
        return result.whenComplete(nuraeye.close);
      },
      wan: () => WanLocalStorageClient(thingName!).setEnabled(enabled),
    );
    if (result is CameraSuccess) return true;
    return verifyAfterTimeout<LocalStorageStatus>(
      fetchCurrent: () => callPreferringKnownTransport(
        camera: _camera,
        thingName: thingName,
        lan: () {
          final nuraeye = NuraeyeClient(connection);
          final result = LocalStorageClient(nuraeye).getStatus();
          return result.whenComplete(nuraeye.close);
        },
        wan: () => WanLocalStorageClient(thingName!).getStatus(),
      ),
      matchesExpected: (current) => current.enabled == enabled,
    );
  }

  /// Sets the recording mode + schedule and verifies against a re-read on a
  /// timeout — `SetRecordingMode` has no retry on the same transport before
  /// the LAN/WAN fallback [callPreferringKnownTransport] already does.
  Future<bool> _setRecordingMode(
    CameraConnection connection,
    RecordingMode wireMode,
  ) async {
    final thingName = connection.thingName;
    final wireSchedule = _scheduleToWire(_scheduleWindows);
    final result = await callPreferringKnownTransport(
      camera: _camera,
      thingName: thingName,
      lan: () {
        final nuraeye = NuraeyeClient(connection);
        final result = RecordingModeClient(
          nuraeye,
        ).setMode(wireMode, schedule: wireSchedule);
        return result.whenComplete(nuraeye.close);
      },
      wan: () => WanRecordingModeClient(
        thingName!,
      ).setMode(wireMode, schedule: wireSchedule),
    );
    if (result is CameraSuccess) return true;
    return verifyAfterTimeout<RecordingModeStatus>(
      fetchCurrent: () => callPreferringKnownTransport(
        camera: _camera,
        thingName: thingName,
        lan: () {
          final nuraeye = NuraeyeClient(connection);
          final result = RecordingModeClient(nuraeye).getMode();
          return result.whenComplete(nuraeye.close);
        },
        wan: () => WanRecordingModeClient(thingName!).getMode(),
      ),
      matchesExpected: (current) =>
          current.mode == wireMode &&
          (wireMode != RecordingMode.scheduled ||
              _scheduleListEquals(_scheduleWindows, current.schedule)),
    );
  }

  Future<void> _save() async {
    final connection = _camera.connection;
    setState(() => _isSaving = true);

    final bool succeeded;
    final wireMode = _toWireMode(_mode);
    if (connection == null) {
      succeeded = await simulateCameraSave();
    } else if (wireMode == null) {
      // Off: disable Local Storage, deliberately without touching whatever
      // RecordingMode is configured underneath — see this class's own doc
      // comment for why (turning storage back on later should resume that
      // mode, not force reconfiguration).
      succeeded = await _setStorageEnabled(connection, false);
    } else {
      // A real mode implies storage should be on — re-enable it first if it
      // was off (best-effort: a failure here still attempts the mode Set
      // below rather than giving up early, since the mode Set's own failure
      // path already tells the user to try again).
      await _setStorageEnabled(connection, true);
      succeeded = await _setRecordingMode(connection, wireMode);
    }

    if (!mounted) return;
    setState(() => _isSaving = false);
    if (succeeded) {
      widget.homesController.updateCamera(
        widget.camera.id,
        (camera) => camera.copyWith(
          recordingStatus: _mode,
          recordingScheduleWindows: _scheduleWindows,
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

  void _openDetectionsScreen() {
    final location = GoRouterState.of(context).matchedLocation;
    final parent = location.substring(0, location.lastIndexOf('/'));
    context.push('$parent/${DetectionsScreen.routeName}', extra: widget.camera);
  }

  Future<bool> _confirmLeave() => confirmDiscardOnLeave(
    context: context,
    isDirty: _isDirty,
    onSave: _save,
    isDirtyAfterSave: () => _isDirty,
    dialogKey: const Key('REC-011'),
    discardKey: const Key('REC-012'),
    saveKey: const Key('REC-013'),
  );

  @override
  Widget build(BuildContext context) {
    final showSchedule = _mode == RecordingStatus.scheduled;
    final showEventTriggeredWarning =
        _mode == RecordingStatus.eventTriggered && !_hasAnyDetectionEnabled;

    return LeaveGuard(
      canLeave: _confirmLeave,
      child: GradientBackground(
        child: Scaffold(
          backgroundColor: Colors.transparent,
          appBar: AppBar(
            key: const Key('REC-001'),
            title: const Text('Recording'),
            actions: [
              ReloadSettingsButton(
                settingsKey: const Key('REC-019'),
                isBusy: _isLoading || _isSaving,
                onPressed: _loadReal,
              ),
              SettingsSaveButton(
                settingsKey: const Key('REC-002'),
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
                GlassCard(
                  padding: EdgeInsets.zero,
                  child: RadioGroup<RecordingStatus>(
                    groupValue: _mode,
                    onChanged: (value) =>
                        _markDirty(() => _mode = value ?? _mode),
                    child: Column(
                      key: const Key('REC-003'),
                      children: [
                        for (final mode in _availableModes)
                          RadioListTile<RecordingStatus>(
                            value: mode,
                            title: Text(_modeLabels[mode]!),
                            subtitle: Text(_modeDescriptions[mode]!),
                          ),
                      ],
                    ),
                  ),
                ),
                if (showEventTriggeredWarning) ...[
                  const SizedBox(height: 12),
                  GlassCard(
                    key: const Key('REC-009'),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          Icons.warning_amber_rounded,
                          color: Theme.of(context).colorScheme.error,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'No detection is set up on this camera yet, '
                                'so Event-Triggered recording won\'t capture '
                                'anything.',
                              ),
                              TextButton(
                                key: const Key('REC-010'),
                                onPressed: _openDetectionsScreen,
                                style: TextButton.styleFrom(
                                  padding: EdgeInsets.zero,
                                  alignment: Alignment.centerLeft,
                                ),
                                child: const Text('Set up detection'),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                if (showSchedule) ...[
                  const SizedBox(height: 24),
                  Text(
                    'Schedule',
                    key: const Key('REC-005'),
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
                  for (final window in _scheduleWindows) ...[
                    GlassCard(
                      padding: EdgeInsets.zero,
                      child: ListTile(
                        key: Key(
                          'REC-006-${window.day.name}-${window.startMinutes}',
                        ),
                        title: Text(_dayLabels[window.day]!),
                        subtitle: Text(
                          '${_formatMinutes(window.startMinutes)} – '
                          '${_formatMinutes(window.endMinutes)}',
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: const Icon(Icons.edit_outlined),
                              onPressed: () =>
                                  _openWindowDialog(editing: window),
                            ),
                            IconButton(
                              icon: const Icon(Icons.delete_outline),
                              onPressed: () => _markDirty(
                                () => _scheduleWindows.remove(window),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],
                  OutlinedButton.icon(
                    key: const Key('REC-007'),
                    // Never a hardcoded cap — built from the camera's own
                    // CameraCapabilities.maxRecordingScheduleWindows
                    // (a fixed-size buffer camera-side, not dynamically
                    // sized), same "no hardcoded values" convention every
                    // other real settings screen follows.
                    onPressed: _scheduleWindows.length >= _maxScheduleWindows
                        ? null
                        : () => _openWindowDialog(),
                    icon: const Icon(Icons.add),
                    label: Text(
                      _scheduleWindows.length >= _maxScheduleWindows
                          ? 'Add window (max $_maxScheduleWindows reached)'
                          : 'Add window',
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
