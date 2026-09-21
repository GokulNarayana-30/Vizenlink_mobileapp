import 'package:camera_api/camera_api.dart';


/// `FR-NE-099`/`FR-MOB-096`/`FR-MOB-097` (new "Authentication" card): WAN counterpart to
/// `OnvifDeviceClient`'s `setDeviceName`/`setDeviceLocation`/`setTimeZone`/`setUserPassword` —
/// there is no WAN transport for ONVIF SOAP at all, so each method here instead calls the
/// matching `NuraeyeAwsIotCommand_Set*` action added specifically for this
/// (`nuraeye.c`'s `prvAwsIotMessageCallback`). Deliberately **not** an implementation of a
/// shared interface with `OnvifDeviceClient` — method signatures match structurally (same
/// params, same `CameraResult<void>` return) so callers can pick either at a single call site
/// (mirrors `imaging_settings_screen.dart`'s `_nightVision` selection between
/// `WanNightVisionClient`/`NightVisionClient`), without forcing a formal interface onto
/// `OnvifDeviceClient` for the sake of these four simple setters.
///
/// **Read-side added 2026-08-10** (`FR-NE-106`) — previously out of scope, reasoning being
/// `CameraInfoScreen`'s cache-first convention already shows the last-known value with no live
/// fetch required on screen open. Found to be a real gap during a Force-WAN audit: the *first*
/// live fetch (onboarding prefetch, or a cache-miss on a fresh camera) always went via LAN
/// `OnvifDeviceClient`, regardless of `isWan` — the exact same "Get always LAN" bug already fixed
/// for Options endpoints, just for a settings screen with no Options concept at all. One combined
/// [getDeviceIdentity] command (not three, unlike the three `set*` methods below) since the app
/// only ever needs all three fields together for this one screen — see the firmware-side command
/// doc in `nuraeye_types.h` for the full reasoning.
class WanDeviceIdentityClient {
  /// [iotCommandClient] is overridable for tests — defaults to a real [IotCommandClient] for
  /// [thingName].
  WanDeviceIdentityClient(String thingName, {IotCommandClient? iotCommandClient})
    : _iot = iotCommandClient ?? IotCommandClient(thingName);

  final IotCommandClient _iot;

  /// [retryOnTimeout] — pass `false` from a caller that polls on its own schedule (e.g. a
  /// reachability ping running every few seconds), where retrying doubles this call's worst-case
  /// latency to buy a second chance the next tick provides anyway.
  ///
  /// **Real bug fixed 2026-09-15**: [timeout] was declared here but never passed to
  /// [IotCommandClient.sendCommandWithResponse], so it silently fell through to that method's own
  /// 12s default — and, with the one-shot retry on top, took up to ~24s regardless of what a
  /// caller actually asked for. A reachability-ping caller requesting a short, single-attempt
  /// check had no way to actually get one, which (app-side) let a single slow WAN round trip
  /// overrun a short poll interval and trip an aggressive offline-backoff window for a camera
  /// that was actually fine.
  Future<CameraResult<({String name, String location, String timezone})>> getDeviceIdentity({
    Duration timeout = const Duration(seconds: 15),
    bool retryOnTimeout = true,
  }) async {
    try {
      final output = await _iot.sendCommandWithResponse(
        IotCommandClient.getDeviceIdentity,
        timeoutSeconds: timeout.inMilliseconds / 1000,
        retryOnTimeout: retryOnTimeout,
      );
      if (output == null) return const CameraTimeout();
      final name = output['name'];
      final location = output['location'];
      final timezone = output['timezone'];
      if (name is! String || location is! String || timezone is! String) {
        return CameraFailure('GetDeviceIdentity response missing fields: $output');
      }
      return CameraSuccess((name: name, location: location, timezone: timezone));
    } catch (e) {
      return CameraFailure(e.toString());
    }
  }

  /// `FR-NE-115`, added 2026-08-21: WAN mirror of `OnvifDeviceClient.getDeviceInformation()` —
  /// reuses the same [DeviceInformation] type both transports return, since the field set is
  /// identical either way. Closes the same "Get always LAN regardless of isWan" gap
  /// [getDeviceIdentity] closed above, this time for `CameraInfoScreen`'s "Device Information"
  /// card.
  Future<CameraResult<DeviceInformation>> getDeviceInfo({
    Duration timeout = const Duration(seconds: 15),
  }) async {
    try {
      final output = await _iot.sendCommandWithResponse(IotCommandClient.getDeviceInfo);
      if (output == null) return const CameraTimeout();
      final manufacturer = output['manufacturer'];
      final model = output['model'];
      final firmwareVersion = output['firmware_version'];
      final serialNumber = output['serial_number'];
      final hardwareId = output['hardware_id'];
      if (manufacturer is! String ||
          model is! String ||
          firmwareVersion is! String ||
          serialNumber is! String ||
          hardwareId is! String) {
        return CameraFailure('GetDeviceInfo response missing fields: $output');
      }
      return CameraSuccess(DeviceInformation(
        manufacturer: manufacturer,
        model: model,
        firmwareVersion: firmwareVersion,
        serialNumber: serialNumber,
        hardwareId: hardwareId,
      ));
    } catch (e) {
      return CameraFailure(e.toString());
    }
  }

  Future<CameraResult<void>> setDeviceName(
    String name, {
    Duration timeout = const Duration(seconds: 15),
  }) => _send(IotCommandClient.setCameraName, {'name': name});

  Future<CameraResult<void>> setDeviceLocation(
    String location, {
    Duration timeout = const Duration(seconds: 15),
  }) => _send(IotCommandClient.setCameraLocation, {'location': location});

  Future<CameraResult<void>> setTimeZone(
    String tz, {
    Duration timeout = const Duration(seconds: 15),
  }) => _send(IotCommandClient.setTimeZone, {'timezone': tz});

  /// See `OnvifDeviceClient.setUserPassword`'s doc — the same single-account-slot semantics
  /// apply over WAN. **Callers must update their own stored `CameraConnection.password` on
  /// success**, same caveat as the LAN client.
  Future<CameraResult<void>> setUserPassword(
    String username,
    String newPassword, {
    Duration timeout = const Duration(seconds: 15),
  }) => _send(IotCommandClient.setUserPassword, {
    'username': username,
    'new_password': newPassword,
  });

  /// `FR-NE-110`: WAN mirror of `OnvifDeviceClient.reboot` (`SystemReboot`) — no WAN transport
  /// exists for ONVIF SOAP at all, so this calls the identical `bsp_rebootAsync()` over MQTT
  /// instead. Same connectivity-gap caveat as the LAN method: a success response does not mean
  /// the device is back yet.
  Future<CameraResult<void>> reboot({Duration timeout = const Duration(seconds: 15)}) =>
      _send(IotCommandClient.reboot, const {});

  /// `FR-NE-110`: WAN mirror of `OnvifDeviceClient.factoryReset` (`SetSystemFactoryDefault`) —
  /// see [FactoryResetMode]'s doc for the Soft/Hard distinction. **[FactoryResetMode.hard] wipes
  /// WiFi credentials** — the caller must warn the user this camera will need full
  /// re-provisioning/re-onboarding, not just a reconnect. Note the WAN transport itself depends
  /// on that same network config, so a Hard reset issued over WAN is the one path that reliably
  /// severs the app's own ability to reach this camera again until it's re-onboarded on LAN.
  Future<CameraResult<void>> factoryReset(
    FactoryResetMode mode, {
    Duration timeout = const Duration(seconds: 15),
  }) => _send(IotCommandClient.factoryReset, {'mode': mode.wireValue});

  Future<CameraResult<void>> _send(int command, Map<String, dynamic> params) async {
    try {
      final output = await _iot.sendCommandWithResponse(command, params: params);
      if (output == null) return const CameraTimeout();
      return const CameraSuccess(null);
    } catch (e) {
      return CameraFailure(e.toString());
    }
  }
}
