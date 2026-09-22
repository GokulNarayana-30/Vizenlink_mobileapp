import 'package:camera_api/camera_api.dart';

import '../../app_state/camera_network.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../app_state/homes_controller.dart';
import '../../app_state/transport_preference.dart';
import '../../models/camera.dart';
import '../../theme/app_colors.dart';
import '../../widgets/glass_card.dart';
import '../../widgets/gradient_background.dart';
import '../../widgets/saving_overlay.dart';
import '../../widgets/settings_save_button.dart' show simulateCameraSave;
import '../dashboard/dashboard_screen.dart';

/// Danger Zone: Reboot, Reset Settings, and Factory Reset (all three require
/// the camera to be online, since they round-trip to the device) plus
/// Delete Camera (allowed while offline — it only removes the camera from
/// local app state via [HomesController.deleteCamera]). The three device
/// actions map onto exactly `OnvifDeviceClient`'s real surface —
/// `reboot()` and `factoryReset(FactoryResetMode.soft/.hard)` — retried over
/// `WanDeviceIdentityClient` if the LAN call fails and
/// `connection.thingName` is known, per
/// `.claude/rules/mobile-app-screen-conventions.md`'s LAN/WAN convention.
/// Falls back to `simulateCameraSave` (local-only) for a camera with no
/// saved connection yet.
class DangerZoneScreen extends StatefulWidget {
  const DangerZoneScreen({
    super.key,
    required this.camera,
    required this.homesController,
  });

  static const routeName = 'danger-zone';

  final Camera camera;
  final HomesController homesController;

  @override
  State<DangerZoneScreen> createState() => _DangerZoneScreenState();
}

class _DangerZoneScreenState extends State<DangerZoneScreen> {
  bool _isBusy = false;
  String _busyLabel = '';

  String get _homeId {
    return widget.homesController.value.homes
        .firstWhere((home) => home.cameras.any((c) => c.id == widget.camera.id))
        .id;
  }

  Future<bool> _confirm({
    required String title,
    required String message,
    required String confirmLabel,
  }) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(confirmLabel),
          ),
        ],
      ),
    );
    return confirmed ?? false;
  }

  Future<void> _reboot() async {
    final confirmed = await _confirm(
      title: 'Reboot camera?',
      message: 'The camera will reboot. Settings and recordings are kept.',
      confirmLabel: 'Reboot',
    );
    if (!confirmed) return;

    setState(() {
      _isBusy = true;
      _busyLabel = 'Rebooting…';
    });

    final connection = widget.camera.connection;
    final bool succeeded;
    if (connection != null) {
      final thingName = connection.thingName;
      // Skips the LAN attempt entirely when this camera's last confirmed
      // transport was WAN — see Camera.lastKnownWan's doc.
      final preferWan = widget.camera.lastKnownWan == true && thingName != null;
      var ok = false;
      if (!preferWan) {
        final client = OnvifDeviceClient(
          connection,
          httpClient: CameraNetwork.clientFor(connection.host),
        );
        final result = await client.reboot();
        client.close();
        ok = result is CameraSuccess;
      }
      if (!ok && thingName != null) {
        final wanResult = await WanDeviceIdentityClient(thingName).reboot();
        ok = wanResult is CameraSuccess;
      }
      succeeded = ok;
    } else {
      succeeded = await simulateCameraSave();
    }

    if (!mounted) return;
    setState(() => _isBusy = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          succeeded
              ? 'Camera is rebooting'
              : 'Failed to reboot camera. Try again.',
        ),
      ),
    );
  }

  /// Shared `OnvifDeviceClient.factoryReset`/`WanDeviceIdentityClient.
  /// factoryReset` call behind [_resetSettings]/[_factoryResetHard] — same
  /// LAN-first-with-WAN-retry pattern as [_reboot].
  Future<void> _factoryReset(
    FactoryResetMode mode, {
    required String busyLabel,
    required String successMessage,
    required String failureMessage,
  }) async {
    setState(() {
      _isBusy = true;
      _busyLabel = busyLabel;
    });

    final connection = widget.camera.connection;
    final bool succeeded;
    if (connection != null) {
      final thingName = connection.thingName;
      final result = await callPreferringKnownTransport(
        camera: widget.camera,
        thingName: thingName,
        lan: () async {
          final client = OnvifDeviceClient(
            connection,
            httpClient: CameraNetwork.clientFor(connection.host),
          );
          final result = await client.factoryReset(mode);
          client.close();
          return result;
        },
        wan: () => WanDeviceIdentityClient(thingName!).factoryReset(mode),
      );
      succeeded = result is CameraSuccess;
    } else {
      succeeded = await simulateCameraSave();
    }

    if (!mounted) return;
    setState(() => _isBusy = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(succeeded ? successMessage : failureMessage)),
    );
  }

  Future<void> _resetSettings() async {
    final confirmed = await _confirm(
      title: 'Reset settings?',
      message:
          'This erases all camera settings (imaging, masks, OSD, and more) '
          'and restores factory defaults. Wi-Fi stays connected — the '
          'camera remains reachable on this network afterward. This cannot '
          'be undone.',
      confirmLabel: 'Erase & Reset',
    );
    if (!confirmed) return;
    await _factoryReset(
      FactoryResetMode.soft,
      busyLabel: 'Resetting…',
      successMessage: 'Camera settings have been reset to factory defaults',
      failureMessage: 'Failed to reset camera. Try again.',
    );
  }

  Future<void> _factoryResetHard() async {
    final confirmed = await _confirm(
      title: 'Factory reset camera?',
      message:
          'This erases ALL settings, including Wi-Fi credentials. The '
          'camera will disconnect from this network and need to be fully '
          're-onboarded (Wi-Fi re-entered, re-scanned) before it can be '
          'used again. This cannot be undone.',
      confirmLabel: 'Erase Everything',
    );
    if (!confirmed) return;
    await _factoryReset(
      FactoryResetMode.hard,
      busyLabel: 'Factory resetting…',
      successMessage:
          'Camera has been factory reset — reconnect it to the network to '
          'use it again',
      failureMessage: 'Failed to factory reset camera. Try again.',
    );
  }

  Future<void> _deleteCamera() async {
    final confirmed = await _confirm(
      title: 'Delete camera?',
      message:
          '"${widget.camera.name}" will be removed from this home. '
          'This cannot be undone.',
      confirmLabel: 'Delete',
    );
    if (!confirmed) return;

    widget.homesController.deleteCamera(_homeId, widget.camera.id);
    if (!mounted) return;
    context.go(DashboardScreen.routeName);
  }

  @override
  Widget build(BuildContext context) {
    final isOnline = widget.camera.isOnline;

    return GradientBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          key: const Key('DANGER-001'),
          title: const Text('Danger Zone'),
        ),
        body: SavingOverlay(
          isSaving: _isBusy,
          label: _busyLabel,
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(
                key: const Key('DANGER-003'),
                'These actions are destructive and, in most cases, cannot '
                'be undone. Proceed with care.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 16),
              GlassCard(
                padding: EdgeInsets.zero,
                child: Column(
                  children: [
                    _DangerTile(
                      settingsKey: const Key('DANGER-004'),
                      icon: Icons.restart_alt,
                      label: 'Soft Reset',
                      description: isOnline
                          ? 'Reboots the camera. Settings and recordings '
                                'are kept.'
                          : 'Camera is offline — reconnect it to reboot.',
                      enabled: isOnline && !_isBusy,
                      onTap: _reboot,
                    ),
                    const Divider(height: 1),
                    _DangerTile(
                      settingsKey: const Key('DANGER-005'),
                      icon: Icons.settings_backup_restore,
                      label: 'Reset Settings',
                      description: isOnline
                          ? 'Erases camera settings and restores factory '
                                'defaults. Wi-Fi stays connected. This '
                                'cannot be undone.'
                          : 'Camera is offline — reconnect it to reset.',
                      enabled: isOnline && !_isBusy,
                      onTap: _resetSettings,
                    ),
                    const Divider(height: 1),
                    _DangerTile(
                      settingsKey: const Key('DANGER-007'),
                      icon: Icons.report_problem_outlined,
                      label: 'Factory Reset',
                      description: isOnline
                          ? 'Erases everything, including Wi-Fi '
                                'credentials — the camera disconnects from '
                                'this network and needs full re-onboarding. '
                                'This cannot be undone.'
                          : 'Camera is offline — reconnect it to reset.',
                      enabled: isOnline && !_isBusy,
                      onTap: _factoryResetHard,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              GlassCard(
                padding: EdgeInsets.zero,
                child: _DangerTile(
                  settingsKey: const Key('DANGER-006'),
                  icon: Icons.delete_forever_outlined,
                  label: 'Delete Camera',
                  description:
                      'Removes this camera from your home. This cannot be '
                      'undone.',
                  enabled: !_isBusy,
                  onTap: _deleteCamera,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DangerTile extends StatelessWidget {
  const _DangerTile({
    required this.settingsKey,
    required this.icon,
    required this.label,
    required this.description,
    required this.enabled,
    required this.onTap,
  });

  final Key settingsKey;
  final IconData icon;
  final String label;
  final String description;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = enabled ? AppColors.offline : Theme.of(context).disabledColor;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        key: settingsKey,
        onTap: enabled ? onTap : null,
        child: ListTile(
          leading: Icon(icon, color: color),
          title: Text(
            label,
            style: TextStyle(
              fontFamily: 'Manrope',
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
          subtitle: Text(description),
        ),
      ),
    );
  }
}
