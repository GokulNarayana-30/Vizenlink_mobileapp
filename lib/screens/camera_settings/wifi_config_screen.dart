import 'package:camera_api/camera_api.dart';

import '../../app_state/camera_network.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:wifi_scan/wifi_scan.dart';

import '../../app_state/homes_controller.dart';
import '../../models/camera.dart';
import '../../widgets/glass_card.dart';
import '../../widgets/gradient_background.dart';
import '../../widgets/live_status_badges.dart' show barsForRssi;
import '../../widgets/reload_settings_button.dart';
import '../../widgets/saving_overlay.dart';
import '../../widgets/settings_save_button.dart' show simulateCameraSave;

/// Nearby-network scanning (`wifi_scan`, the phone's own Wi-Fi radio — not a
/// `camera_api` capability, see `NetworkInfoClient`'s doc) only works on
/// Android: Android ties scan results to a grantable location permission,
/// while iOS gives third-party apps no public API to enumerate nearby
/// networks at all (only the currently-connected SSID, and even that needs
/// a special entitlement this app doesn't have). `defaultTargetPlatform`
/// rather than `Platform.isAndroid` so this stays testable without
/// `dart:io`.
bool get _supportsNetworkScan =>
    defaultTargetPlatform == TargetPlatform.android;

/// A network's `capabilities` string (e.g. `"[WPA2-PSK-CCMP][ESS]"`) lists
/// its security protocols — an open network's is empty or lacks any of
/// these tokens.
bool _isSecured(String capabilities) =>
    RegExp('WEP|WPA|EAP', caseSensitive: false).hasMatch(capabilities);

IconData _signalIcon(int bars) => switch (bars) {
  0 => Icons.signal_cellular_0_bar,
  1 => Icons.signal_cellular_alt_1_bar,
  2 => Icons.signal_cellular_alt_2_bar,
  _ => Icons.signal_cellular_alt,
};

/// Configure Wi-Fi: shows the camera's *current* network (`NetworkInfoClient
/// .getWifiSsid`/`.getWifiSignalStrength`, LAN only — `NetworkInfoClient`
/// has no scan-for-nearby-networks capability, so unlike an earlier stub
/// version of this screen there's no network picker) and a form to switch
/// it to a new network (`NetworkInfoClient.setupWifi`). Falls back to
/// local-only `HomesController` state (`simulateCameraSave`) for a camera
/// with no saved connection yet, same as other settings screens.
class WifiConfigScreen extends StatefulWidget {
  const WifiConfigScreen({
    super.key,
    required this.camera,
    required this.homesController,
  });

  static const routeName = 'wifi-config';

  final Camera camera;
  final HomesController homesController;

  @override
  State<WifiConfigScreen> createState() => _WifiConfigScreenState();
}

class _WifiConfigScreenState extends State<WifiConfigScreen> {
  bool _loading = true;
  bool _isWireless = false;
  String? _currentSsid;
  int? _currentRssi;
  final _newSsidController = TextEditingController();
  final _newPasswordController = TextEditingController();
  bool _isConnecting = false;

  bool _scanning = false;
  List<WiFiAccessPoint> _nearbyNetworks = const [];
  String? _scanMessage;

  /// Looked up fresh from [HomesController] on every build (not
  /// [widget.camera] directly), matching every other camera-settings screen.
  Camera get _camera {
    for (final home in widget.homesController.value.homes) {
      for (final camera in home.cameras) {
        if (camera.id == widget.camera.id) return camera;
      }
    }
    return widget.camera;
  }

  String get _homeId {
    return widget.homesController.value.homes
        .firstWhere((home) => home.cameras.any((c) => c.id == widget.camera.id))
        .id;
  }

  @override
  void initState() {
    super.initState();
    _loadCurrentNetwork();
    if (_supportsNetworkScan) _scanNearbyNetworks();
  }

  @override
  void dispose() {
    _newSsidController.dispose();
    _newPasswordController.dispose();
    super.dispose();
  }

  Future<void> _loadCurrentNetwork() async {
    final connection = _camera.connection;
    if (connection == null) {
      setState(() => _loading = false);
      return;
    }

    final device = OnvifDeviceClient(
      connection,
      httpClient: CameraNetwork.clientFor(connection.host),
    );
    final netResult = await device.getNetworkInterfaceInfo();
    device.close();
    final isWireless = switch (netResult) {
      CameraSuccess(:final value) => value.isWireless,
      CameraFailure() || CameraTimeout() => false,
    };

    String? ssid;
    int? rssi;
    if (isWireless) {
      final infoClient = NetworkInfoClient(connection);
      final results = await Future.wait([
        infoClient.getWifiSsid(),
        infoClient.getWifiSignalStrength(),
      ]);
      infoClient.close();
      if (results[0] case CameraSuccess<String>(:final value)) ssid = value;
      if (results[1] case CameraSuccess<({int rssi, int snr})>(:final value)) {
        rssi = value.rssi;
      }
    }

    if (!mounted) return;
    setState(() {
      _isWireless = isWireless;
      _currentSsid = ssid;
      _currentRssi = rssi;
      _loading = false;
    });
  }

  /// Manual reload — re-fetches the current network info from the camera,
  /// for when a change made elsewhere (another client, the camera's own web
  /// UI) hasn't shown up here yet.
  Future<void> _reloadSettings() async {
    if (_camera.connection == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No saved connection for this camera yet'),
        ),
      );
      return;
    }
    setState(() => _loading = true);
    await _loadCurrentNetwork();
  }

  /// Scans for nearby Wi-Fi networks with the *phone's* own radio (Android
  /// only — see [_supportsNetworkScan]). `startScan` only triggers an async
  /// OS-level scan and returns once that request is accepted, not once
  /// results are ready — the short delay before reading them back is the
  /// standard `wifi_scan` usage pattern, not a fixed guess at total scan
  /// time.
  Future<void> _scanNearbyNetworks() async {
    setState(() => _scanning = true);

    final canStart = await WiFiScan.instance.canStartScan();
    if (canStart == CanStartScan.yes) {
      await WiFiScan.instance.startScan();
      await Future<void>.delayed(const Duration(seconds: 2));
    }

    final canGet = await WiFiScan.instance.canGetScannedResults();
    if (!mounted) return;
    if (canGet != CanGetScannedResults.yes) {
      setState(() {
        _scanning = false;
        _nearbyNetworks = const [];
        _scanMessage = switch ((canStart, canGet)) {
          (CanStartScan.noLocationPermissionDenied, _) ||
          (_, CanGetScannedResults.noLocationPermissionDenied) =>
            'Location permission is required to scan for networks. Enable '
                'it for this app in system settings.',
          (CanStartScan.noLocationServiceDisabled, _) ||
          (
            _,
            CanGetScannedResults.noLocationServiceDisabled,
          ) => 'Turn on location services to scan for networks.',
          (CanStartScan.notSupported, _) ||
          (
            _,
            CanGetScannedResults.notSupported,
          ) => 'Wi-Fi scanning isn\'t supported on this device.',
          _ => 'Couldn\'t scan for nearby networks.',
        };
      });
      return;
    }

    final results = await WiFiScan.instance.getScannedResults();
    if (!mounted) return;
    setState(() {
      _scanning = false;
      _nearbyNetworks = results;
      _scanMessage = results.isEmpty ? 'No nearby networks found.' : null;
    });
  }

  void _selectNearbyNetwork(WiFiAccessPoint network) {
    setState(() {
      _newSsidController.text = network.ssid;
      _newPasswordController.clear();
    });
  }

  Future<void> _connect() async {
    final ssid = _newSsidController.text.trim();
    if (ssid.isEmpty) return;
    setState(() => _isConnecting = true);

    final connection = _camera.connection;
    final bool succeeded;
    if (connection != null) {
      final infoClient = NetworkInfoClient(connection);
      final result = await infoClient.setupWifi(
        ssid: ssid,
        psk: _newPasswordController.text,
      );
      infoClient.close();
      succeeded = result is CameraSuccess;
    } else {
      succeeded = await simulateCameraSave();
    }

    if (!mounted) return;
    setState(() => _isConnecting = false);
    if (succeeded) {
      widget.homesController.updateCameraWifi(_homeId, widget.camera.id, ssid);
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            _isWireless
                ? 'Wi-Fi settings sent — the camera will attempt to connect '
                      'to $ssid'
                : 'Wi-Fi credentials saved. The camera will use them next '
                      'time it connects to Wi-Fi.',
          ),
        ),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Failed to update Wi-Fi settings. Try again.'),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return GradientBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          key: const Key('WIFI-001'),
          title: const Text('Configure Wi-Fi'),
          actions: [
            ReloadSettingsButton(
              settingsKey: const Key('WIFI-017'),
              isBusy: _loading || _isConnecting,
              onPressed: _reloadSettings,
            ),
          ],
        ),
        body: SavingOverlay(
          isSaving: _isConnecting,
          label: 'Connecting…',
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (_loading)
                const Padding(
                  key: Key('WIFI-002'),
                  padding: EdgeInsets.symmetric(vertical: 32),
                  child: Center(
                    child: Column(
                      children: [
                        CircularProgressIndicator(),
                        SizedBox(height: 12),
                        Text('Loading network info…'),
                      ],
                    ),
                  ),
                )
              else ...[
                if (_isWireless)
                  GlassCard(
                    padding: EdgeInsets.zero,
                    child: ListTile(
                      key: const Key('WIFI-010'),
                      leading: Icon(
                        _signalIcon(barsForRssi(_currentRssi ?? -100)),
                        color: colorScheme.onSurfaceVariant,
                      ),
                      title: Text(_currentSsid ?? 'Unknown network'),
                      subtitle: const Text('Current Wi-Fi network'),
                    ),
                  )
                else if (_camera.connection != null)
                  GlassCard(
                    padding: EdgeInsets.zero,
                    child: ListTile(
                      key: const Key('WIFI-011'),
                      leading: Icon(
                        Icons.lan_outlined,
                        color: colorScheme.onSurfaceVariant,
                      ),
                      title: const Text('Connected via Ethernet'),
                      subtitle: const Text(
                        'Wi-Fi credentials entered below are saved for the '
                        'next time this camera switches to Wi-Fi.',
                      ),
                    ),
                  ),
                const SizedBox(height: 16),
                if (_supportsNetworkScan) ...[
                  GlassCard(
                    padding: EdgeInsets.zero,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  'Nearby networks',
                                  style: Theme.of(
                                    context,
                                  ).textTheme.titleMedium,
                                ),
                              ),
                              IconButton(
                                key: const Key('WIFI-015'),
                                tooltip: 'Scan again',
                                onPressed: _scanning
                                    ? null
                                    : _scanNearbyNetworks,
                                icon: _scanning
                                    ? const SizedBox(
                                        width: 16,
                                        height: 16,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                        ),
                                      )
                                    : const Icon(Icons.refresh),
                              ),
                            ],
                          ),
                        ),
                        if (_scanning && _nearbyNetworks.isEmpty)
                          const Padding(
                            key: Key('WIFI-012'),
                            padding: EdgeInsets.symmetric(vertical: 16),
                            child: Center(child: CircularProgressIndicator()),
                          )
                        else if (_nearbyNetworks.isNotEmpty)
                          Column(
                            key: const Key('WIFI-013'),
                            children: [
                              for (final network in _nearbyNetworks)
                                _NearbyNetworkTile(
                                  network: network,
                                  onTap: () => _selectNearbyNetwork(network),
                                ),
                            ],
                          )
                        else if (_scanMessage != null)
                          Padding(
                            key: const Key('WIFI-014'),
                            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                            child: Text(
                              _scanMessage!,
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                ] else
                  Padding(
                    key: const Key('WIFI-016'),
                    padding: const EdgeInsets.only(bottom: 16),
                    child: Text(
                      'Network scanning isn\'t available on iOS — enter the '
                      'network name manually below.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                GlassCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        'Change Wi-Fi network',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        key: const Key('WIFI-007'),
                        controller: _newSsidController,
                        decoration: const InputDecoration(
                          labelText: 'Network name',
                          prefixIcon: Icon(Icons.wifi),
                        ),
                        onChanged: (_) => setState(() {}),
                      ),
                      const SizedBox(height: 16),
                      TextField(
                        key: const Key('WIFI-008'),
                        controller: _newPasswordController,
                        obscureText: true,
                        decoration: const InputDecoration(
                          labelText: 'Password',
                          prefixIcon: Icon(Icons.lock_outline),
                        ),
                        onChanged: (_) => setState(() {}),
                      ),
                      const SizedBox(height: 16),
                      FilledButton(
                        key: const Key('WIFI-009'),
                        onPressed: _newSsidController.text.trim().isNotEmpty
                            ? _connect
                            : null,
                        child: const Text('Connect'),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _NearbyNetworkTile extends StatelessWidget {
  const _NearbyNetworkTile({required this.network, required this.onTap});

  final WiFiAccessPoint network;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: ListTile(
          leading: Icon(
            _signalIcon(barsForRssi(network.level)),
            color: colorScheme.onSurfaceVariant,
          ),
          title: Text(network.ssid.isEmpty ? '(hidden network)' : network.ssid),
          trailing: _isSecured(network.capabilities)
              ? Icon(
                  Icons.lock_outline,
                  size: 18,
                  color: colorScheme.onSurfaceVariant,
                )
              : null,
        ),
      ),
    );
  }
}
