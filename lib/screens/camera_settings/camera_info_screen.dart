import 'package:camera_api/camera_api.dart';

import '../../app_state/camera_network.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../app_state/camera_settings_cache.dart';
import '../../app_state/camera_sync.dart';
import '../../app_state/homes_controller.dart';
import '../../app_state/settings_save_verify.dart';
import '../../app_state/transport_preference.dart';
import '../../models/camera.dart';
import '../../models/home.dart';
import '../../widgets/glass_card.dart';
import '../../widgets/gradient_background.dart';
import '../../widgets/gradient_button.dart';
import '../../widgets/live_status_badges.dart' show formatBitrate;
import '../../widgets/navigation_leave_guard.dart';
import '../../widgets/password_form_field.dart';
import '../../widgets/saving_overlay.dart';
import 'wifi_config_screen.dart';

const _unassignedRoomLabel = 'Unassigned';

/// User's choice in the unsaved-changes leave-confirmation dialog.
enum _LeaveChoice { save, discard }

/// Fallback timezone options — shown when this camera has no saved
/// connection yet, its firmware predates `GetSupportedTimezones` (see
/// `NetworkInfoClient.getSupportedTimezones`'s doc), or the catalog fetch
/// hasn't succeeded yet (retried via "Sync from camera" —
/// see [_CameraInfoScreenState._loadCameraTimezones]). Deliberately IANA-style
/// labels, not POSIX codes: since these aren't camera-verified, Save leaves
/// them local-only rather than guessing a POSIX string to push to the
/// device (see `_confirmAndSave`).
const _dummyTimezones = [
  'UTC',
  'America/New_York',
  'America/Chicago',
  'America/Denver',
  'America/Los_Angeles',
  'Europe/London',
  'Europe/Berlin',
  'Asia/Kolkata',
  'Asia/Tokyo',
  'Australia/Sydney',
];

/// Reformats a camera-reported timezone name like "India Standard Time -
/// Kolkata (UTC+05:30)" into a shorter "IST-Kolkata (UTC +5:30)" form. The
/// abbreviation is the initials of each word in the region name — matches
/// every example this catalog has returned so far ("China Standard Time" ->
/// CST, "Greenwich Mean Time" -> GMT, "Eastern Time" -> ET). Falls back to
/// the original string unmodified for anything that doesn't match the
/// expected shape (e.g. the bare "Coordinated Universal Time (UTC)" entry,
/// or a future firmware build changing the format) rather than showing a
/// mangled result.
String _formatTimezoneLabel(String name) {
  final match = RegExp(
    r'^(.+) - (.+) \(UTC([+-])(\d{1,2}):(\d{2})\)$',
  ).firstMatch(name);
  if (match == null) return name;
  final abbreviation = match
      .group(1)!
      .split(' ')
      .where((word) => word.isNotEmpty)
      .map((word) => word[0])
      .join();
  final city = match.group(2)!;
  final sign = match.group(3)!;
  final hour = int.parse(match.group(4)!);
  final minute = match.group(5)!;
  return '$abbreviation-$city (UTC $sign$hour:$minute)';
}

/// Camera Info: editable name and home/room location, read-only
/// device-info fields sourced from the [Camera] model (stub data until a
/// real CCTV protocol/backend exists — see CLAUDE.md), and a password
/// change dialog.
class CameraInfoScreen extends StatefulWidget {
  const CameraInfoScreen({
    super.key,
    required this.camera,
    required this.homesController,
  });

  static const routeName = 'info';

  final Camera camera;
  final HomesController homesController;

  @override
  State<CameraInfoScreen> createState() => _CameraInfoScreenState();
}

class _CameraInfoScreenState extends State<CameraInfoScreen> {
  late final TextEditingController _nameController;
  late final TextEditingController _locationController;
  late final String _originalHomeId;
  late String _homeId;
  late String? _room;
  late String _timezone;
  bool _isDirty = false;
  bool _syncing = false;
  bool _saving = false;

  /// The camera's own curated timezone list (`code` is the POSIX string
  /// `OnvifDeviceClient.setTimeZone` expects), fetched once a connection is
  /// available. Null means "use the [_dummyTimezones] fallback" — either no
  /// connection yet, or the camera's firmware predates this call.
  List<TimezoneOption>? _cameraTimezones;

  /// The camera's current state from [HomesController], looked up fresh on
  /// every build rather than [widget.camera] directly — needed so
  /// [_syncFromCamera]'s live-fetched fields actually show up after a
  /// sync, since [widget.camera] itself stays the snapshot passed in when
  /// this screen was opened. Falls back to [widget.camera] if the camera
  /// was deleted from underneath this screen.
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
    _nameController = TextEditingController(text: widget.camera.name);
    _nameController.addListener(_markDirty);
    _locationController = TextEditingController(
      text: widget.camera.location ?? '',
    );
    _locationController.addListener(_markDirty);
    _originalHomeId = _homeContainingCamera(widget.camera.id).id;
    _homeId = _originalHomeId;
    _room = widget.camera.room;
    _timezone = widget.camera.timezone;
    _loadCameraTimezones();
  }

  /// Loads the camera's real timezone catalog if it has a saved connection.
  /// Leaves [_cameraTimezones] as null (picker shows [_dummyTimezones]) if
  /// there's no connection yet or the call fails — also called from
  /// [_syncFromCamera] so the user has a real retry path instead of being
  /// stuck on the fallback list for the rest of the screen's life.
  Future<void> _loadCameraTimezones() async {
    final connection = _camera.connection;
    if (connection == null) return;
    final client = NetworkInfoClient(connection);
    final result = await NetworkAnswerCache.getOrFetch(
      connection.host,
      'supportedTimezones',
      fetch: client.getSupportedTimezones,
    );
    client.close();
    if (!mounted) return;
    if (result case CameraSuccess(:final value)) {
      setState(() => _cameraTimezones = value);
    }
  }

  @override
  void dispose() {
    _nameController.removeListener(_markDirty);
    _nameController.dispose();
    _locationController.removeListener(_markDirty);
    _locationController.dispose();
    super.dispose();
  }

  void _markDirty() {
    if (!_isDirty) setState(() => _isDirty = true);
  }

  Home _homeContainingCamera(String cameraId) {
    return widget.homesController.value.homes.firstWhere(
      (home) => home.cameras.any((camera) => camera.id == cameraId),
    );
  }

  void _onHomeChanged(String? newHomeId) {
    if (newHomeId == null || newHomeId == _homeId) return;
    setState(() {
      _homeId = newHomeId;
      _room = null;
      _isDirty = true;
    });
  }

  void _onRoomChanged(String? newRoom) {
    setState(() {
      _room = newRoom;
      _isDirty = true;
    });
  }

  void _onTimezoneChanged(String? newTimezone) {
    if (newTimezone == null) return;
    setState(() {
      _timezone = newTimezone;
      _isDirty = true;
    });
  }

  /// Returns the human-readable reason for each device push that failed
  /// (name and/or timezone) — empty means everything that needed to reach
  /// the camera did, or nothing needed to.
  Future<List<String>> _commitChanges() async {
    final failures = <String>[];
    final connection = _camera.connection;

    // Compared against [_camera] (the live, current HomesController value),
    // not [widget.camera] — [widget.camera] is a fixed snapshot from when
    // this screen was first pushed and never updates after a successful
    // in-screen save. Comparing against it meant a *second* Save in the
    // same screen visit (e.g. name saved once, then only timezone changed)
    // kept re-detecting the already-saved name/room/timezone as "changed"
    // against their pre-first-save values and re-pushing them for no
    // reason — a real report: changing only the timezone was also sending
    // a redundant `setDeviceName` with the same name already saved a
    // moment earlier, adding a full extra round trip's delay.
    final newName = _nameController.text.trim();
    if (newName.isNotEmpty && newName != _camera.name) {
      // Pushed to the device (ONVIF SetScopes) whenever a connection is
      // known, keeping the app's label and the camera's own reported name
      // in sync — only falls back to a local-only rename for a camera that
      // predates credential capture and so has nothing to push to.
      if (connection != null) {
        // LAN failed — retry over WAN before surfacing an error, per
        // mobile-app-screen-conventions.md's LAN/WAN convention (a LAN
        // Apply/Set failure should automatically retry over WAN, not just
        // fail outright) — or WAN is called directly when this camera's
        // last confirmed transport was WAN (Camera.lastKnownWan's doc).
        final wanThingName = connection.thingName;
        final wanEligible =
            connection.wanCommandCapable != false && wanThingName != null;
        final result = await callPreferringKnownTransport(
          camera: _camera,
          thingName: wanEligible ? wanThingName : null,
          lan: () async {
            final client = OnvifDeviceClient(
              connection,
              httpClient: CameraNetwork.clientFor(connection.host),
            );
            final result = await client.setDeviceName(newName);
            client.close();
            return result;
          },
          wan: () =>
              WanDeviceIdentityClient(wanThingName!).setDeviceName(newName),
        );
        // SetScopes (LAN) / the WAN equivalent can land on the camera with
        // only its reply lost to a timeout — re-read before reporting
        // failure, same reasoning as every other screen using this pattern.
        final nameVerified =
            result is! CameraSuccess &&
            await verifyAfterTimeout<String>(
              fetchCurrent: () async {
                final client = OnvifDeviceClient(
                  connection,
                  httpClient: CameraNetwork.clientFor(connection.host),
                );
                final lanResult = await client.getDeviceIdentity();
                client.close();
                if (lanResult case CameraSuccess(:final value)) {
                  return CameraSuccess(value.name);
                }
                if (wanThingName == null) {
                  return const CameraFailure<String>(
                    'no WAN fallback available',
                  );
                }
                final wanResult = await WanDeviceIdentityClient(
                  wanThingName,
                ).getDeviceIdentity();
                if (wanResult case CameraSuccess(:final value)) {
                  return CameraSuccess(value.name);
                }
                return const CameraFailure<String>('timed out');
              },
              matchesExpected: (current) => current == newName,
            );
        switch (result) {
          case CameraSuccess():
            widget.homesController.renameCamera(
              _originalHomeId,
              widget.camera.id,
              newName,
            );
          case _ when nameVerified:
            widget.homesController.renameCamera(
              _originalHomeId,
              widget.camera.id,
              newName,
            );
          case CameraFailure(:final reason):
            failures.add('name ($reason)');
          case CameraTimeout():
            failures.add('name (timed out)');
        }
      } else {
        widget.homesController.renameCamera(
          _originalHomeId,
          widget.camera.id,
          newName,
        );
      }
    }

    final newLocation = _locationController.text.trim();
    if (newLocation != (_camera.location ?? '')) {
      // Real gap fixed 2026-09-15: `OnvifDeviceClient`/`WanDeviceIdentityClient
      // .setDeviceLocation` existed with no UI calling it anywhere — mirrors
      // the name push above exactly (same ONVIF `SetScopes` mechanism,
      // LAN-then-WAN convention, local-only fallback with no connection).
      if (connection != null) {
        final wanThingName = connection.thingName;
        final wanEligible =
            connection.wanCommandCapable != false && wanThingName != null;
        final result = await callPreferringKnownTransport(
          camera: _camera,
          thingName: wanEligible ? wanThingName : null,
          lan: () async {
            final client = OnvifDeviceClient(
              connection,
              httpClient: CameraNetwork.clientFor(connection.host),
            );
            final result = await client.setDeviceLocation(newLocation);
            client.close();
            return result;
          },
          wan: () => WanDeviceIdentityClient(
            wanThingName!,
          ).setDeviceLocation(newLocation),
        );
        final locationVerified =
            result is! CameraSuccess &&
            await verifyAfterTimeout<String>(
              fetchCurrent: () async {
                final client = OnvifDeviceClient(
                  connection,
                  httpClient: CameraNetwork.clientFor(connection.host),
                );
                final lanResult = await client.getDeviceIdentity();
                client.close();
                if (lanResult case CameraSuccess(:final value)) {
                  return CameraSuccess(value.location);
                }
                if (wanThingName == null) {
                  return const CameraFailure<String>(
                    'no WAN fallback available',
                  );
                }
                final wanResult = await WanDeviceIdentityClient(
                  wanThingName,
                ).getDeviceIdentity();
                if (wanResult case CameraSuccess(:final value)) {
                  return CameraSuccess(value.location);
                }
                return const CameraFailure<String>('timed out');
              },
              matchesExpected: (current) => current == newLocation,
            );
        switch (result) {
          case CameraSuccess():
            widget.homesController.updateCamera(
              widget.camera.id,
              (camera) => camera.copyWith(location: newLocation),
            );
          case _ when locationVerified:
            widget.homesController.updateCamera(
              widget.camera.id,
              (camera) => camera.copyWith(location: newLocation),
            );
          case CameraFailure(:final reason):
            failures.add('location ($reason)');
          case CameraTimeout():
            failures.add('location (timed out)');
        }
      } else {
        widget.homesController.updateCamera(
          widget.camera.id,
          (camera) => camera.copyWith(location: newLocation),
        );
      }
    }

    if (_homeId != _originalHomeId || _room != _camera.room) {
      widget.homesController.moveCameraToHome(
        fromHomeId: _originalHomeId,
        toHomeId: _homeId,
        cameraId: widget.camera.id,
        room: _room,
      );
    }

    if (_timezone != _camera.timezone) {
      // Only push to the real camera when this code came from its own
      // verified catalog (_cameraTimezones) — never send a POSIX string
      // guessed from the [_dummyTimezones] fallback. In that fallback case,
      // stay local-only, same as home/room.
      if (_cameraTimezones != null && connection != null) {
        // LAN failed — retry over WAN before surfacing an error, same
        // convention as the name push above (or WAN is called directly
        // when known — see Camera.lastKnownWan's doc).
        final wanThingName = connection.thingName;
        final wanEligible =
            connection.wanCommandCapable != false && wanThingName != null;
        final result = await callPreferringKnownTransport(
          camera: _camera,
          thingName: wanEligible ? wanThingName : null,
          lan: () async {
            final client = OnvifDeviceClient(
              connection,
              httpClient: CameraNetwork.clientFor(connection.host),
            );
            final result = await client.setTimeZone(_timezone);
            client.close();
            return result;
          },
          wan: () =>
              WanDeviceIdentityClient(wanThingName!).setTimeZone(_timezone),
        );
        // No LAN getTimeZone exists — verify over WAN only, when reachable.
        final timezoneVerified =
            result is! CameraSuccess &&
            wanThingName != null &&
            await verifyAfterTimeout<String>(
              fetchCurrent: () => WanDeviceIdentityClient(wanThingName)
                  .getDeviceIdentity()
                  .then(
                    (r) => switch (r) {
                      CameraSuccess(:final value) => CameraSuccess<String>(
                        value.timezone,
                      ),
                      _ => const CameraFailure<String>('timed out'),
                    },
                  ),
              matchesExpected: (current) => current == _timezone,
            );
        switch (result) {
          case CameraSuccess():
            widget.homesController.updateCameraTimezone(
              _homeId,
              widget.camera.id,
              _timezone,
            );
          case _ when timezoneVerified:
            widget.homesController.updateCameraTimezone(
              _homeId,
              widget.camera.id,
              _timezone,
            );
          case CameraFailure(:final reason):
            failures.add('timezone ($reason)');
          case CameraTimeout():
            failures.add('timezone (timed out)');
        }
      } else {
        widget.homesController.updateCameraTimezone(
          _homeId,
          widget.camera.id,
          _timezone,
        );
      }
    }

    if (mounted) setState(() => _isDirty = false);
    return failures;
  }

  Future<void> _confirmAndSave() async {
    final shouldSave = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const Key('CAMINFO-022'),
        title: const Text('Save changes?'),
        content: const Text(
          'This will update the camera\'s name, home/room, and timezone.',
        ),
        actions: [
          TextButton(
            key: const Key('CAMINFO-023'),
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('CAMINFO-024'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (shouldSave != true || !mounted) return;
    setState(() => _saving = true);
    final failures = await _commitChanges();
    if (!mounted) return;
    setState(() => _saving = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          failures.isEmpty
              ? 'Changes saved'
              : 'Some changes saved, but ${failures.join(', ')} failed on '
                    'the camera',
        ),
      ),
    );
  }

  /// Called when the user tries to leave the screen with unsaved edits.
  /// Returns true if the pop should proceed (either nothing to save, or the
  /// user explicitly chose to discard).
  Future<bool> _confirmDiscardOnLeave() async {
    if (!_isDirty) return true;
    final choice = await showDialog<_LeaveChoice>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const Key('CAMINFO-025'),
        title: const Text('Unsaved changes'),
        content: const Text(
          'You have unsaved changes. Save them before leaving?',
        ),
        actions: [
          TextButton(
            key: const Key('CAMINFO-026'),
            onPressed: () =>
                Navigator.of(dialogContext).pop(_LeaveChoice.discard),
            child: const Text('Discard'),
          ),
          FilledButton(
            key: const Key('CAMINFO-027'),
            onPressed: () => Navigator.of(dialogContext).pop(_LeaveChoice.save),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (choice == _LeaveChoice.save) {
      _commitChanges();
      return true;
    }
    return choice == _LeaveChoice.discard;
  }

  /// "3d 4h" / "4h 12m" / "42m" — coarse-grained on purpose, this is a
  /// health indicator (has the camera been unusually stable/unstable), not
  /// a precise clock.
  String _formatUptime(int seconds) {
    final duration = Duration(seconds: seconds);
    final days = duration.inDays;
    final hours = duration.inHours % 24;
    final minutes = duration.inMinutes % 60;
    if (days > 0) return '${days}d ${hours}h';
    if (hours > 0) return '${hours}h ${minutes}m';
    return '${minutes}m';
  }

  String _formatEpoch(int epochSeconds) {
    final t = DateTime.fromMillisecondsSinceEpoch(
      epochSeconds * 1000,
    ).toLocal();
    final hour12 = t.hour % 12 == 0 ? 12 : t.hour % 12;
    final period = t.hour < 12 ? 'AM' : 'PM';
    return '${t.month}/${t.day}/${t.year} '
        '$hour12:${t.minute.toString().padLeft(2, '0')} $period';
  }

  Future<void> _openModifyPasswordDialog() async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => _ModifyPasswordDialog(
        key: const Key('CAMINFO-016'),
        camera: _camera,
        homesController: widget.homesController,
      ),
    );
  }

  /// Fetches this camera's live device info/network/capabilities/timezone
  /// and a fresh snapshot over LAN, persisting whatever succeeds via
  /// [syncCameraFromDevice] (shared with the scan setup flow's auto-sync).
  /// Only available once a `CameraConnection` has been saved for this camera
  /// (see [Camera.connection]'s doc) — cameras added before onboarding
  /// captured credentials, or whose scan setup form hasn't actually
  /// connected yet, have nothing to sync from.
  Future<void> _syncFromCamera() async {
    final connection = _camera.connection;
    if (connection == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No saved connection for this camera yet'),
        ),
      );
      return;
    }

    setState(() => _syncing = true);
    final failures = await syncCameraFromDevice(
      homesController: widget.homesController,
      cameraId: widget.camera.id,
      connection: connection,
    );
    // Also (re)fetch the camera's own timezone catalog here — this is the
    // retry path for a connection that wasn't available yet at initState,
    // or a getSupportedTimezones call that failed transiently the first
    // time. Without this, a failed initial fetch left the picker stuck on
    // _dummyTimezones for the rest of the screen's life with no way for the
    // user to force a real retry.
    await _loadCameraTimezones();

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          failures.isEmpty
              ? 'Synced with camera'
              : 'Synced with camera, but ${failures.join(', ')} failed',
        ),
      ),
    );
    setState(() => _syncing = false);
  }

  @override
  Widget build(BuildContext context) {
    final homes = widget.homesController.value.homes;
    final selectedHome = homes.firstWhere((home) => home.id == _homeId);
    final rooms = selectedHome.rooms;

    return LeaveGuard(
      canLeave: _confirmDiscardOnLeave,
      child: GradientBackground(
        child: Scaffold(
          backgroundColor: Colors.transparent,
          appBar: AppBar(
            key: const Key('CAMINFO-001'),
            title: const Text('Camera Info'),
            actions: [
              TextButton(
                key: const Key('CAMINFO-002'),
                onPressed: (_isDirty && !_saving) ? _confirmAndSave : null,
                child: _saving
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Save'),
              ),
            ],
          ),
          body: SavingOverlay(
            isSaving: _saving,
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (_camera.healthConditionMessages.isNotEmpty) ...[
                  _SectionHeader('Health'),
                  const SizedBox(height: 8),
                  GlassCard(
                    padding: EdgeInsets.zero,
                    child: Column(
                      children: [
                        for (final (index, message)
                            in _camera.healthConditionMessages.indexed)
                          _InfoRow(
                            settingsKey: Key('CAMINFO-031-$index'),
                            icon: Icons.warning_amber_rounded,
                            label: message,
                            value: '',
                            isLast:
                                index ==
                                _camera.healthConditionMessages.length - 1,
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),
                ],
                if (_camera.uptimeSeconds != null) ...[
                  _SectionHeader('Device Health'),
                  const SizedBox(height: 8),
                  GlassCard(
                    padding: EdgeInsets.zero,
                    child: Column(
                      children: [
                        _InfoRow(
                          settingsKey: const Key('CAMINFO-034'),
                          icon: Icons.timer_outlined,
                          label: 'Uptime',
                          value: _formatUptime(_camera.uptimeSeconds!),
                          isLast:
                              _camera.lastRebootUtc == null &&
                              _camera.rebootCount == null,
                        ),
                        if (_camera.lastRebootUtc != null)
                          _InfoRow(
                            settingsKey: const Key('CAMINFO-035'),
                            icon: Icons.restart_alt,
                            label: 'Last reboot',
                            value: _formatEpoch(_camera.lastRebootUtc!),
                            isLast: _camera.rebootCount == null,
                          ),
                        if (_camera.rebootCount != null)
                          _InfoRow(
                            settingsKey: const Key('CAMINFO-036'),
                            icon: Icons.history,
                            label: 'Reboot count',
                            value: '${_camera.rebootCount}',
                            isLast: true,
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),
                ],
                _SectionHeader('Device Identity'),
                const SizedBox(height: 8),
                GlassCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      TextField(
                        key: const Key('CAMINFO-003'),
                        controller: _nameController,
                        maxLength: kMaxDeviceNameLength,
                        decoration: const InputDecoration(
                          labelText: 'Camera name',
                        ),
                        textInputAction: TextInputAction.done,
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        key: const Key('CAMINFO-037'),
                        controller: _locationController,
                        decoration: const InputDecoration(
                          labelText: 'Camera-reported location',
                          helperText:
                              'The camera\'s own ONVIF location label — '
                              'separate from this app\'s Home/Room below',
                        ),
                        textInputAction: TextInputAction.done,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  key: const Key('CAMINFO-032'),
                  onPressed: _syncing ? null : _syncFromCamera,
                  icon: _syncing
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.sync),
                  label: Text(_syncing ? 'Syncing…' : 'Sync from camera'),
                ),
                const SizedBox(height: 8),
                GlassCard(
                  padding: EdgeInsets.zero,
                  child: Column(
                    children: [
                      _InfoRow(
                        settingsKey: const Key('CAMINFO-011'),
                        icon: Icons.precision_manufacturing_outlined,
                        label: 'Manufacturer',
                        value: _camera.manufacturer,
                      ),
                      _InfoRow(
                        settingsKey: const Key('CAMINFO-033'),
                        icon: Icons.camera_outlined,
                        label: 'Model',
                        value: _camera.model,
                      ),
                      _InfoRow(
                        settingsKey: const Key('CAMINFO-013'),
                        icon: Icons.tag,
                        label: 'Serial number',
                        value: _camera.serialNumber,
                      ),
                      _InfoRow(
                        settingsKey: const Key('CAMINFO-014'),
                        icon: Icons.fingerprint,
                        label: 'Hardware ID',
                        value: _camera.hardwareId,
                      ),
                      _InfoRow(
                        settingsKey: const Key('CAMINFO-012'),
                        icon: Icons.system_update_outlined,
                        label: 'Firmware version',
                        value: _camera.firmwareVersion,
                        isLast: true,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),
                _SectionHeader('Network & Connectivity'),
                const SizedBox(height: 8),
                GlassCard(
                  padding: EdgeInsets.zero,
                  child: Column(
                    children: [
                      _InfoRow(
                        settingsKey: const Key('CAMINFO-008'),
                        icon: Icons.wifi,
                        label: 'Wi-Fi network',
                        value: _camera.wifiNetwork,
                      ),
                      _InfoRow(
                        settingsKey: const Key('CAMINFO-009'),
                        icon: Icons.signal_cellular_alt,
                        label: 'Signal strength',
                        value: '${_camera.signalStrength} / 4',
                      ),
                      _InfoRow(
                        settingsKey: const Key('CAMINFO-030'),
                        icon: Icons.speed_outlined,
                        label: 'Network speed',
                        value: formatBitrate(_camera.networkSpeedKbps),
                      ),
                      _InfoRow(
                        settingsKey: const Key('CAMINFO-010'),
                        icon: Icons.memory,
                        label: 'MAC address',
                        value: _camera.macAddress,
                      ),
                      _InfoRow(
                        settingsKey: const Key('CAMINFO-028'),
                        icon: Icons.lan_outlined,
                        label: 'IP address',
                        value: _camera.ipAddress,
                        isLast: true,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  key: const Key('CAMINFO-029'),
                  onPressed: () => context.push(
                    '${GoRouterState.of(context).matchedLocation}/${WifiConfigScreen.routeName}',
                    extra: _camera,
                  ),
                  icon: const Icon(Icons.wifi_outlined),
                  label: const Text('Configure Wi-Fi'),
                ),
                const SizedBox(height: 24),
                _SectionHeader('Location'),
                const SizedBox(height: 8),
                GlassCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      DropdownButtonFormField<String>(
                        key: const Key('CAMINFO-004'),
                        initialValue: _homeId,
                        isExpanded: true,
                        decoration: const InputDecoration(labelText: 'Home'),
                        items: [
                          for (final home in homes)
                            DropdownMenuItem(
                              value: home.id,
                              child: Text(
                                home.name,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                        ],
                        onChanged: _onHomeChanged,
                      ),
                      const SizedBox(height: 16),
                      DropdownButtonFormField<String?>(
                        key: const Key('CAMINFO-005'),
                        initialValue: _room,
                        isExpanded: true,
                        decoration: const InputDecoration(labelText: 'Room'),
                        items: [
                          const DropdownMenuItem<String?>(
                            value: null,
                            child: Text(
                              _unassignedRoomLabel,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          for (final room in rooms)
                            DropdownMenuItem<String?>(
                              value: room,
                              child: Text(
                                room,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                        ],
                        onChanged: _onRoomChanged,
                      ),
                      const SizedBox(height: 16),
                      Builder(
                        builder: (context) {
                          final cameraTimezones = _cameraTimezones;
                          final codes = cameraTimezones != null
                              ? [for (final tz in cameraTimezones) tz.code]
                              : _dummyTimezones;
                          return DropdownButtonFormField<String>(
                            key: const Key('CAMINFO-006'),
                            initialValue: codes.contains(_timezone)
                                ? _timezone
                                : codes.first,
                            isExpanded: true,
                            decoration: const InputDecoration(
                              labelText: 'Timezone',
                            ),
                            items: cameraTimezones != null
                                ? [
                                    for (final tz in cameraTimezones)
                                      DropdownMenuItem(
                                        value: tz.code,
                                        child: Text(
                                          _formatTimezoneLabel(tz.name),
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                  ]
                                : [
                                    for (final zone in _dummyTimezones)
                                      DropdownMenuItem(
                                        value: zone,
                                        child: Text(
                                          zone,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                  ],
                            onChanged: _onTimezoneChanged,
                          );
                        },
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),
                _SectionHeader('Recording'),
                const SizedBox(height: 8),
                GlassCard(
                  padding: EdgeInsets.zero,
                  child: Column(
                    children: [
                      _InfoRow(
                        settingsKey: const Key('CAMINFO-007'),
                        icon: Icons.fiber_manual_record,
                        label: 'Recording status',
                        value: _recordingStatusLabel(_camera.recordingStatus),
                        isLast: true,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),
                _SectionHeader('Security'),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  key: const Key('CAMINFO-015'),
                  onPressed: _openModifyPasswordDialog,
                  icon: const Icon(Icons.lock_outline),
                  label: const Text('Modify Password'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _recordingStatusLabel(RecordingStatus status) {
    switch (status) {
      case RecordingStatus.continuous:
        return 'Continuous';
      case RecordingStatus.scheduled:
        return 'Scheduled';
      case RecordingStatus.eventTriggered:
        return 'Event-triggered';
      case RecordingStatus.off:
        return 'Off';
    }
  }
}

/// Section label above a group of related fields (e.g. "Device Identity",
/// "Network & Connectivity").
class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Text(
      label,
      style: Theme.of(context).textTheme.labelLarge?.copyWith(
        fontWeight: FontWeight.w700,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
        letterSpacing: 0.5,
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({
    required this.settingsKey,
    required this.icon,
    required this.label,
    required this.value,
    this.isLast = false,
  });

  final Key settingsKey;
  final IconData icon;
  final String label;
  final String value;
  final bool isLast;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Container(
      key: settingsKey,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: isLast
          ? null
          : BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: colorScheme.outlineVariant.withValues(alpha: 0.4),
                ),
              ),
            ),
      child: Row(
        children: [
          Icon(icon, size: 20, color: colorScheme.onSurfaceVariant),
          const SizedBox(width: 12),
          Expanded(
            child: Text(label, style: Theme.of(context).textTheme.bodyMedium),
          ),
          Text(
            value,
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}

/// Change-password dialog: current, new, confirm password + Cancel/Save.
/// Real `camera_api` call (`OnvifDeviceClient.setUserPassword`, the camera's
/// single WSSE-digest device account — not the app-level Cognito account
/// [ChangePasswordScreen] changes), retried over
/// `WanDeviceIdentityClient.setUserPassword` if the LAN call fails and
/// `connection.thingName` is known, per
/// `.claude/rules/mobile-app-screen-conventions.md`'s LAN/WAN convention.
/// "Current password" is checked against the saved `CameraConnection
/// .password` locally before attempting anything — the ONVIF request itself
/// authenticates via WSSE digest using that same saved password regardless,
/// so this is purely a user-facing "did you type the right one" check, not
/// something sent on the wire.
class _ModifyPasswordDialog extends StatefulWidget {
  const _ModifyPasswordDialog({
    super.key,
    required this.camera,
    required this.homesController,
  });

  final Camera camera;
  final HomesController homesController;

  @override
  State<_ModifyPasswordDialog> createState() => _ModifyPasswordDialogState();
}

class _ModifyPasswordDialogState extends State<_ModifyPasswordDialog> {
  final _formKey = GlobalKey<FormState>();
  final _currentController = TextEditingController();
  final _newController = TextEditingController();
  final _confirmController = TextEditingController();
  bool _isSubmitting = false;
  String? _errorText;

  @override
  void dispose() {
    _currentController.dispose();
    _newController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;

    final connection = widget.camera.connection;
    if (connection == null) {
      setState(() => _errorText = 'This camera has no saved connection yet.');
      return;
    }
    if (_currentController.text != connection.password) {
      setState(() => _errorText = 'Current password is incorrect.');
      return;
    }

    setState(() {
      _isSubmitting = true;
      _errorText = null;
    });

    final newPassword = _newController.text;
    final thingName = connection.thingName;
    final result = await callPreferringKnownTransport(
      camera: widget.camera,
      thingName: thingName,
      lan: () async {
        final lanClient = OnvifDeviceClient(
          connection,
          httpClient: CameraNetwork.clientFor(connection.host),
        );
        final result = await lanClient.setUserPassword(
          connection.username,
          newPassword,
        );
        lanClient.close();
        return result;
      },
      wan: () => WanDeviceIdentityClient(
        thingName!,
      ).setUserPassword(connection.username, newPassword),
    );
    // Deliberately no verify-after-timeout here, unlike name/location/
    // timezone above — there is no safe way to "read back" a password to
    // confirm it changed, and guessing wrong in either direction is worse
    // than the plain timeout message: reporting success on a change that
    // didn't land leaves the saved credential wrong with no visible sign,
    // and there's no get call to check against in the first place.

    if (!mounted) return;
    switch (result) {
      case CameraSuccess():
        widget.homesController.updateCameraPassword(
          widget.camera.id,
          newPassword,
        );
        Navigator.of(context).pop();
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Password updated')));
      case CameraFailure(:final reason):
        setState(() {
          _isSubmitting = false;
          _errorText = reason;
        });
      case CameraTimeout():
        setState(() {
          _isSubmitting = false;
          _errorText = 'Camera did not respond. Try again.';
        });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24),
      child: GlassCard(
        padding: const EdgeInsets.all(24),
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Modify Password',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 16),
                PasswordFormField(
                  key: const Key('CAMINFO-017'),
                  controller: _currentController,
                  labelText: 'Current password',
                  textInputAction: TextInputAction.next,
                  validator: (value) => (value == null || value.isEmpty)
                      ? 'Enter the current password'
                      : null,
                ),
                const SizedBox(height: 16),
                PasswordFormField(
                  key: const Key('CAMINFO-018'),
                  controller: _newController,
                  labelText: 'New password',
                  textInputAction: TextInputAction.next,
                  validator: (value) => (value == null || value.length < 8)
                      ? 'New password must be at least 8 characters'
                      : null,
                ),
                const SizedBox(height: 16),
                PasswordFormField(
                  key: const Key('CAMINFO-019'),
                  controller: _confirmController,
                  labelText: 'Confirm password',
                  textInputAction: TextInputAction.done,
                  onFieldSubmitted: (_) => _save(),
                  validator: (value) => value != _newController.text
                      ? 'Passwords do not match'
                      : null,
                ),
                if (_errorText != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    _errorText!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
                const SizedBox(height: 24),
                GradientButton(
                  key: const Key('CAMINFO-021'),
                  onPressed: _isSubmitting ? null : _save,
                  child: _isSubmitting
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            valueColor: AlwaysStoppedAnimation(Colors.white),
                          ),
                        )
                      : const Text('Save'),
                ),
                const SizedBox(height: 8),
                TextButton(
                  key: const Key('CAMINFO-020'),
                  onPressed: _isSubmitting
                      ? null
                      : () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
