import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:camera_api/camera_api.dart';

import 'camera_network.dart';
import 'package:path_provider/path_provider.dart';

import '../models/camera.dart';
import 'homes_controller.dart';
import 'transport_preference.dart';
import 'preview_key_store.dart';

/// Fetches [cameraId]'s live device information, network interface, and WAN
/// capability over LAN (`OnvifDeviceClient`/`CapabilitiesClient`) and
/// persists whatever succeeds via [HomesController.updateCamera]. Shared by
/// the scan setup flow (auto-sync right after a camera is added) and
/// [CameraInfoScreen]'s manual "Sync from camera" button, so both stay in
/// sync with the same fields/behavior.
///
/// **Device identity/info/timezone/health fall back to WAN**
/// (`WanDeviceIdentityClient`/`WanHealthClient`) when the LAN attempt above
/// fails and this camera is WAN-eligible — added after this previously
/// being LAN-only meant "Sync from camera" failed on every single field
/// whenever the phone was off the camera's LAN, which read as a permanent
/// error rather than the normal off-LAN case every other screen in this app
/// already handles via LAN-then-WAN fallback. Network info (MAC/local IP)
/// and capabilities have no WAN equivalent — network info is inherently
/// LAN-topology data, and every `GetCapabilities`-sourced field is LAN-only
/// per `IotCommandClient`'s own doc — so those two stay LAN-only, same as
/// before. Snapshot also stays LAN-only: `WanPreviewSnapshotClient`'s doc is
/// explicit its bytes must never be persisted as a kept thumbnail.
///
/// **Health** (`HealthClient`/`WanHealthClient`'s `GetDeviceHealth`, added
/// 2026-09-08 — closes the `ui-api-gap-audit` "Health section on Camera Info
/// is real client code, not wired" finding) persists reboot count, last
/// reboot time, uptime, and whether the camera's own clock is unsynced —
/// [Camera.healthConditionMessages] surfaces the last of those as a real
/// health condition, same as a storage failure.
///
/// Returns the human-readable failure reasons for whichever calls didn't
/// succeed (empty list = fully synced) — callers decide how to surface that.
///
/// **Cheap LAN reachability probe first** (`LiveStreamUriClient.checkReachable`
/// — the same unauthenticated, ~3s single round trip `pingCameraReachability`
/// already uses), rather than firing all 6 heavier ONVIF/REST calls blind
/// every time. When the phone is off this camera's LAN, this skips straight
/// to the WAN fallback below instead of eating each of those 6 calls' own
/// timeout first (previously the visible cause of "Sync from camera" taking
/// up to ~58s and surfacing a wall of per-field failures off-LAN: a ~10s LAN
/// burst always attempted first, then two *sequential* WAN calls at up to
/// ~24s each — `IotCommandClient`'s own one-shot retry on top of this
/// class's 12s timeout). The WAN fallback itself now also runs in parallel
/// (`Future.wait`) instead of sequentially, for the same reason.
Future<List<String>> syncCameraFromDevice({
  required HomesController homesController,
  required String cameraId,
  required CameraConnection connection,
}) async {
  final device = OnvifDeviceClient(
    connection,
    httpClient: CameraNetwork.clientFor(connection.host),
  );
  final nuraeye = NuraeyeClient(connection);
  try {
    // Known WAN (Camera.lastKnownWan) skips even the cheap probe below —
    // an instant decision beats a ~3s round trip when we already know the
    // answer from the live-view session that's been open on this camera.
    final knownWan = _findCamera(homesController, cameraId)?.lastKnownWan;
    final lanReachable = knownWan == true
        ? false
        : await LiveStreamUriClient(
            nuraeye,
          ).checkReachable(timeout: lanReachabilityProbeTimeout);
    // Free answer — record it so settings screens never rediscover the
    // transport by spending a real call's timeout on it.
    recordTransportFromProbe(
      connection.thingName,
      reachableOnLan: lanReachable,
    );

    final CameraResult<DeviceInformation> infoResult;
    final CameraResult<DeviceIdentity> identityResult;
    final CameraResult<NetworkInterfaceInfo> netResult;
    final CameraResult<CameraCapabilities> capsResult;
    final CameraResult<DeviceDateTime> dateTimeResult;
    final CameraResult<Uint8List> snapshotResult;
    final CameraResult<HealthStatus> healthResult;
    if (lanReachable) {
      final results = await Future.wait([
        device.getDeviceInformation(),
        device.getDeviceIdentity(),
        device.getNetworkInterfaceInfo(),
        CapabilitiesClient(nuraeye).getCapabilities(),
        device.getSystemDateAndTime(),
        SnapshotClient(connection).getSnapshot(),
        HealthClient(nuraeye).getHealth(),
      ]);
      infoResult = results[0] as CameraResult<DeviceInformation>;
      identityResult = results[1] as CameraResult<DeviceIdentity>;
      netResult = results[2] as CameraResult<NetworkInterfaceInfo>;
      capsResult = results[3] as CameraResult<CameraCapabilities>;
      dateTimeResult = results[4] as CameraResult<DeviceDateTime>;
      snapshotResult = results[5] as CameraResult<Uint8List>;
      healthResult = results[6] as CameraResult<HealthStatus>;
    } else {
      // Known unreachable on LAN — skip straight to the WAN fallback below
      // rather than waiting out each call's own LAN timeout first. Network
      // info/capabilities/snapshot have no WAN equivalent (see this
      // function's own doc), so those three stay a plain timeout.
      infoResult = const CameraTimeout<DeviceInformation>();
      identityResult = const CameraTimeout<DeviceIdentity>();
      netResult = const CameraTimeout<NetworkInterfaceInfo>();
      capsResult = const CameraTimeout<CameraCapabilities>();
      dateTimeResult = const CameraTimeout<DeviceDateTime>();
      snapshotResult = const CameraTimeout<Uint8List>();
      healthResult = const CameraTimeout<HealthStatus>();
    }

    final failures = <String>[];
    DeviceInformation? info;
    DeviceIdentity? identity;
    NetworkInterfaceInfo? net;
    CameraCapabilities? caps;
    String? timezone;
    String? thumbnailPath;
    HealthStatus? health;

    switch (identityResult) {
      case CameraSuccess(:final value):
        identity = value;
      case CameraFailure(:final reason):
        failures.add('name ($reason)');
      case CameraTimeout():
        failures.add('name (timed out)');
    }
    switch (infoResult) {
      case CameraSuccess(:final value):
        info = value;
      case CameraFailure(:final reason):
        failures.add('device info ($reason)');
      case CameraTimeout():
        failures.add('device info (timed out)');
    }
    switch (netResult) {
      case CameraSuccess(:final value):
        net = value;
      case CameraFailure(:final reason):
        failures.add('network info ($reason)');
      case CameraTimeout():
        failures.add('network info (timed out)');
    }
    switch (capsResult) {
      case CameraSuccess(:final value):
        caps = value;
      case CameraFailure(:final reason):
        failures.add('capabilities ($reason)');
      case CameraTimeout():
        failures.add('capabilities (timed out)');
    }
    switch (dateTimeResult) {
      case CameraSuccess(:final value):
        timezone = value.timezone;
      case CameraFailure(:final reason):
        failures.add('timezone ($reason)');
      case CameraTimeout():
        failures.add('timezone (timed out)');
    }
    switch (healthResult) {
      case CameraSuccess(:final value):
        health = value;
      case CameraFailure(:final reason):
        failures.add('health ($reason)');
      case CameraTimeout():
        failures.add('health (timed out)');
    }

    final wanThingName = connection.thingName;
    if (connection.wanCommandCapable != false &&
        wanThingName != null &&
        (info == null ||
            identity == null ||
            timezone == null ||
            health == null)) {
      final wan = WanDeviceIdentityClient(wanThingName);
      // Requested in parallel (previously sequential for the identity/info
      // pair — awaiting getDeviceInfo() before even starting
      // getDeviceIdentity() could double the worst-case wait, up to ~24s
      // each with IotCommandClient's own built-in one-shot retry on top of
      // this class's 12s timeout). Health added the same way, 2026-09-08.
      final needsInfo = info == null;
      final needsIdentity = identity == null || timezone == null;
      final needsHealth = health == null;
      final wanResults = await Future.wait([
        needsInfo ? wan.getDeviceInfo() : Future.value(null),
        needsIdentity ? wan.getDeviceIdentity() : Future.value(null),
        needsHealth
            ? WanHealthClient(wanThingName).getHealth()
            : Future.value(null),
      ]);
      final wanInfoResult = wanResults[0] as CameraResult<DeviceInformation>?;
      final wanIdentityResult =
          wanResults[1]
              as CameraResult<
                ({String name, String location, String timezone})
              >?;
      final wanHealthResult = wanResults[2] as CameraResult<HealthStatus>?;

      if (wanInfoResult case CameraSuccess(:final value)) {
        info = value;
        failures.removeWhere((f) => f.startsWith('device info'));
      }
      if (wanIdentityResult case CameraSuccess(:final value)) {
        if (identity == null) {
          identity = DeviceIdentity(name: value.name, location: value.location);
          failures.removeWhere((f) => f.startsWith('name'));
        }
        if (timezone == null) {
          timezone = value.timezone;
          failures.removeWhere((f) => f.startsWith('timezone'));
        }
      }
      if (wanHealthResult case CameraSuccess(:final value)) {
        health = value;
        failures.removeWhere((f) => f.startsWith('health'));
      }
    }

    switch (snapshotResult) {
      case CameraSuccess(:final value):
        thumbnailPath = await _saveSnapshotLocally(
          cameraId: cameraId,
          bytes: value,
          previousThumbnailUrl: _findCamera(
            homesController,
            cameraId,
          )?.thumbnailUrl,
        );
        if (thumbnailPath == null) {
          failures.add('snapshot (failed to save locally)');
        }
      case CameraFailure(:final reason):
        failures.add('snapshot ($reason)');
      case CameraTimeout():
        failures.add('snapshot (timed out)');
    }

    // Empty means factory-default (no name ever configured on this camera)
    // — leave the existing app-side name alone rather than blanking it.
    final realName = (identity != null && identity.name.isNotEmpty)
        ? identity.name
        : null;
    final realLocation = (identity != null && identity.location.isNotEmpty)
        ? identity.location
        : null;

    // Reachability ("ping") for [Camera.isOnline]: this camera is online if
    // *any* call above actually got a response, LAN or WAN — a single
    // failed call (e.g. one ONVIF service down) doesn't mean the whole
    // device is unreachable, but every one of them failing/timing out does.
    // Always written below, even when every call failed, so a camera that's
    // gone offline actually gets marked offline instead of the app trusting
    // whatever isOnline was set to at onboarding forever. Uses the resolved
    // values (LAN or WAN) rather than just the LAN results, so a camera
    // reachable only over WAN is correctly marked online instead of
    // "offline" just because it's off the phone's current LAN.
    final reachable =
        info != null ||
        identity != null ||
        net != null ||
        caps != null ||
        timezone != null ||
        health != null ||
        snapshotResult is CameraSuccess;

    homesController.updateCamera(
      cameraId,
      (current) => current.copyWith(
        isOnline: reachable,
        lastSeen: reachable ? DateTime.now() : null,
        name: realName,
        location: realLocation,
        manufacturer: info?.manufacturer,
        model: info?.model,
        firmwareVersion: info?.firmwareVersion,
        serialNumber: info?.serialNumber,
        hardwareId: info?.hardwareId,
        macAddress: net?.macAddress,
        ipAddress: net?.ipv4Address,
        // The device's serial number doubles as its AWS IoT thing
        // name/KVS stream name (OnvifDeviceClient.getSerialNumber's
        // doc) — this is what unlocks the WAN identity/live-view
        // clients for a camera onboarded via LAN.
        thingName: info?.serialNumber,
        wanLiveViewCapable: caps?.wanLiveViewCapable,
        wanCommandCapable: caps?.wanCommandCapable,
        sirenCapable: caps?.sirenCapable,
        spotlightCapable: caps?.spotlightCapable,
        warningCapable: caps?.warningCapable,
        // The camera's own POSIX-style TZ code (e.g. "IST-5:30"), not an
        // IANA name — CameraInfoScreen's timezone picker switches to the
        // camera's own GetSupportedTimezones catalog (same code
        // vocabulary) once a connection is available, so this is never
        // compared against IANA strings.
        timezone: timezone,
        thumbnailUrl: thumbnailPath,
        rebootCount: health?.rebootCount,
        lastRebootUtc: health?.lastRebootUtc,
        uptimeSeconds: health?.uptimeSeconds,
        clockSyncUncertain: health == null
            ? null
            : health.clockSyncState == ClockSyncState.uncertain,
      ),
    );

    // Opportunistic, once-per-camera fetch of the camera's WAN
    // preview-snapshot shared key (see PreviewKeyStore's doc) — needs a
    // reachable LAN connection and a resolved thingName, both of which this
    // sync either already has or just confirmed.
    final resolvedThingName = info?.serialNumber ?? connection.thingName;
    if (reachable && resolvedThingName != null) {
      await _fetchPreviewKeyIfNeeded(connection, resolvedThingName);
    }

    return failures;
  } finally {
    device.close();
    nuraeye.close();
  }
}

/// Fetches the camera's shared preview-snapshot key (`GetPreviewKey`,
/// LAN-only) and caches it locally if it hasn't been already — see
/// [PreviewKeyStore]'s doc comment for the full picture. Best-effort:
/// failures are silently skipped, same reasoning as every other
/// non-critical field in [syncCameraFromDevice] — the next sync/reachability
/// check simply tries again since nothing gets cached on failure.
Future<void> _fetchPreviewKeyIfNeeded(
  CameraConnection connection,
  String thingName,
) async {
  if (await PreviewKeyStore.instance.hasSharedKey(thingName)) return;
  final nuraeye = NuraeyeClient(connection);
  try {
    final result = await nuraeye.call('GetPreviewKey');
    if (result case CameraSuccess(:final value)) {
      final keyBase64 = value['key'];
      if (keyBase64 is String) {
        await PreviewKeyStore.instance.storeSharedKey(
          thingName,
          base64Decode(keyBase64),
        );
      }
    }
  } finally {
    nuraeye.close();
  }
}

/// Fetches a fresh real snapshot for [cameraId] over LAN and persists it as
/// `Camera.thumbnailUrl` — the lighter-weight action behind every "Refresh
/// preview" button on the camera-settings screens (as opposed to
/// [syncCameraFromDevice]'s full device-info sync, which also refetches a
/// snapshot but alongside several other fields). Returns true on success.
Future<bool> refreshCameraSnapshot({
  required HomesController homesController,
  required String cameraId,
  required CameraConnection connection,
}) async {
  final client = SnapshotClient(connection);
  try {
    final result = await client.getSnapshot();
    // A successful snapshot fetch is a real, positive reachability signal —
    // always recorded. **A failure is deliberately NOT recorded as
    // offline** (changed from unconditional both-ways writes): this call is
    // LAN-only, with no WAN fallback, so treating its failure as "offline"
    // disagreed with pingCameraReachability's LAN-then-WAN check (which
    // does fall back) whenever the phone is off this camera's LAN but the
    // camera is still reachable over WAN — the two calls fighting over the
    // same flag produced a visible flicker (this timer flips it false,
    // pingCameraReachability's next tick flips it back true). Offline is
    // now exclusively pingCameraReachability's call to make; a failed
    // snapshot here just means no fresh thumbnail this round, reflected via
    // this function's own `bool` return, not the shared online/offline flag.
    final reachable = result is CameraSuccess;
    if (reachable) {
      homesController.updateCamera(
        cameraId,
        (current) => current.copyWith(isOnline: true, lastSeen: DateTime.now()),
      );
    }
    // Same opportunistic fetch syncCameraFromDevice does — this is a much
    // more frequently-successful LAN touchpoint (every manual "Refresh
    // preview" tap, not just onboarding/"Sync from camera"), so a camera
    // whose full sync never happened to land while reachable still gets its
    // WAN preview key fetched the first time this lighter call succeeds.
    final thingName = connection.thingName;
    if (reachable && thingName != null) {
      await _fetchPreviewKeyIfNeeded(connection, thingName);
    }
    if (result case CameraSuccess(:final value)) {
      final path = await _saveSnapshotLocally(
        cameraId: cameraId,
        bytes: value,
        previousThumbnailUrl: _findCamera(
          homesController,
          cameraId,
        )?.thumbnailUrl,
      );
      if (path != null) {
        homesController.updateCamera(
          cameraId,
          (current) => current.copyWith(thumbnailUrl: path),
        );
        return true;
      }
    }
    return false;
  } finally {
    client.close();
  }
}

/// Per-camera WAN-fallback backoff state for [pingCameraReachability] — the
/// Dashboard's reachability timer calls this for every camera on every
/// ~15s tick. Without this, a camera that's neither reachable on LAN nor
/// actually answering on WAN incurs a full WAN round trip (`~10s`, since
/// `IotCommandClient` has its own built-in one-shot retry on top of this
/// call's own 5s timeout) every single cycle, indefinitely, for as long as
/// the Dashboard stays open — real-world impact: with even one or two
/// cameras stuck in that state, the app can feel constantly laggy while
/// nothing ever actually recovers. After [_wanBackoffThreshold] consecutive
/// WAN failures for a camera, skip the WAN attempt for [_wanBackoffDuration]
/// before trying again instead of paying full cost every cycle. Module-level
/// (not per-`HomesController`) since this is purely a rate-limit on outbound
/// calls, not app state that needs to survive a restart or be shared beyond
/// this process.
final _wanFailureStreak = <String, int>{};
final _wanBackoffUntil = <String, DateTime>{};
const _wanBackoffThreshold = 2;
const _wanBackoffDuration = Duration(minutes: 2);

/// Cameras with a [pingCameraReachability] call currently in flight — real
/// bug found 2026-09-15: the Dashboard's reachability timer fires every
/// ~15s regardless of whether the previous tick's call for that same camera
/// has finished yet. A LAN timeout (3s) plus a slow WAN fallback (5s timeout
/// with `IotCommandClient`'s own one-shot retry on top, so up to ~10s) can
/// exceed 15s under real network conditions, letting two calls for the same
/// camera run concurrently — whichever finishes second then wins
/// `homesController.updateCamera`'s write regardless of which one actually
/// reflects current reality, an unpredictable last-write-wins race. Guarded
/// here (module-level, alongside the backoff maps above) rather than in
/// `dashboard_screen.dart`, so any other future caller gets the same
/// protection for free.
final _pingInFlight = <String>{};

/// Cheap reachability-only probe for [cameraId] — updates `isOnline`/
/// `lastSeen`, via a single unauthenticated LAN round trip
/// (`LiveStreamUriClient.checkReachable()`'s `areYouNuraeyeDevice`) instead of
/// fetching a full snapshot image. Meant to run on a much tighter timer
/// (e.g. the Dashboard's short-interval online/offline check) than the
/// heavier, image-fetching [refreshCameraSnapshot] — polling every camera's
/// full snapshot every few seconds would waste bandwidth for no benefit
/// beyond the reachability bit this already gets for a fraction of the
/// cost. **The periodic/automatic path that's allowed to write `isOnline:
/// false`** — [refreshCameraSnapshot] only ever writes `true` (see its own
/// doc) since, unlike this function and [syncCameraFromDevice], it has no
/// WAN fallback; disagreeing on that point between the two produced a
/// visible online/offline flicker.
///
/// Falls back to a cheap WAN read (`WanDeviceIdentityClient.getDeviceIdentity`
/// — a real round trip, but the smallest one available on that transport)
/// when the LAN probe fails and this camera has a known `thingName` —
/// otherwise a camera that's simply off the phone's current LAN (not
/// actually offline) would be wrongly marked offline, same reasoning as
/// live view's own LAN-then-WAN transport selection
/// (`STREAMING_GUIDE.md` §1). See [_wanFailureStreak]/[_wanBackoffUntil]'s
/// doc for why that fallback is itself rate-limited after repeated failures.
Future<void> pingCameraReachability({
  required HomesController homesController,
  required String cameraId,
  required CameraConnection connection,
}) async {
  if (!_pingInFlight.add(cameraId)) return;
  try {
    // `null` means "couldn't determine" — distinct from a definite `false`.
    // Only a real probe result is ever written to `isOnline`; see the backoff
    // branch below for why that distinction matters.
    bool? reachable;

    // A camera the live-view session already confirmed is WAN-only isn't on
    // this phone's LAN, so the LAN probe below can only ever burn its full 3s
    // timeout before failing. `syncCameraFromDevice` already skips it on the
    // same signal — this function paying it on every 15s tick (real bug,
    // 2026-09-15) was a third of the ping's total latency for nothing.
    final knownWan = _findCamera(homesController, cameraId)?.lastKnownWan;
    if (knownWan != true) {
      final nuraeye = NuraeyeClient(connection);
      try {
        reachable = await LiveStreamUriClient(
          nuraeye,
        ).checkReachable(timeout: lanReachabilityProbeTimeout);
      } finally {
        nuraeye.close();
      }
      recordTransportFromProbe(
        connection.thingName,
        reachableOnLan: reachable == true,
      );
    }

    if (reachable == true) {
      _wanFailureStreak.remove(cameraId);
      _wanBackoffUntil.remove(cameraId);
    } else {
      final thingName = connection.thingName;
      final backoffUntil = _wanBackoffUntil[cameraId];
      final inBackoff =
          backoffUntil != null && DateTime.now().isBefore(backoffUntil);
      if (thingName == null) {
        // No WAN path at all for this camera, so the LAN probe's `false` is
        // the whole answer — a definite offline, not an unknown.
        reachable = false;
      } else if (inBackoff) {
        // Real bug fixed 2026-09-15: this used to leave `reachable` at
        // `false`, so the rate-limit on *outbound calls* got reported to the
        // user as "camera offline" — for the full 2-minute window, without a
        // single attempt to verify it. Two slow WAN pings were enough to
        // trip it, which is exactly what the ignored-timeout bug in
        // `WanDeviceIdentityClient.getDeviceIdentity` made routine. Backoff
        // now means "don't know", leaving the last confirmed state on screen.
        reachable = null;
      } else {
        final result = await WanDeviceIdentityClient(thingName)
            .getDeviceIdentity(
              timeout: const Duration(seconds: 5),
              // This function is itself the poll — the next tick is only ~15s
              // away and is a better second chance than doubling this call's
              // worst case to retry inline.
              retryOnTimeout: false,
            );
        reachable = result is CameraSuccess;
        if (reachable) {
          _wanFailureStreak.remove(cameraId);
          _wanBackoffUntil.remove(cameraId);
        } else {
          final streak = (_wanFailureStreak[cameraId] ?? 0) + 1;
          _wanFailureStreak[cameraId] = streak;
          if (streak >= _wanBackoffThreshold) {
            _wanBackoffUntil[cameraId] = DateTime.now().add(
              _wanBackoffDuration,
            );
          }
        }
      }
    }

    final probed = reachable;
    if (probed == null) return;
    final current = _findCamera(homesController, cameraId);
    if (current == null || current.isOnline == probed) return;
    homesController.updateCamera(
      cameraId,
      (camera) => camera.copyWith(
        isOnline: probed,
        lastSeen: probed ? DateTime.now() : null,
      ),
    );
  } finally {
    _pingInFlight.remove(cameraId);
  }
}

/// Transient WAN preview fetch for a single "Refresh preview" attempt, used
/// as a fallback once [refreshCameraSnapshot]'s LAN attempt fails.
/// `WanPreviewSnapshotClient`'s own doc is explicit that the returned bytes
/// must never be persisted (no gallery save, no cache file — and
/// deliberately not written to `Camera.thumbnailUrl` here either) since this
/// is a live decrypted frame for on-screen display only, not a kept
/// snapshot. Callers should hold the bytes in local widget state only, for
/// as long as that screen wants to keep showing them. Returns null if this
/// camera has no `thingName` yet, or the WAN fetch itself fails (no local
/// preview key registered with this camera yet, camera unreachable, decrypt
/// failure, etc — all indistinguishable to a caller that just wants bytes
/// or nothing).
Future<Uint8List?> fetchWanPreviewSnapshot({
  required CameraConnection connection,
}) async {
  final thingName = connection.thingName;
  if (thingName == null) return null;
  final result = await WanPreviewSnapshotClient(thingName).getPreviewSnapshot();
  switch (result) {
    case CameraSuccess(:final value):
      return value;
    case CameraFailure(:final reason):
      // Swallowed to null for the UI (just shows a generic "failed to
      // refresh" snackbar), but logged — the most likely reason ("No
      // preview key generated/registered yet") is otherwise invisible and
      // easy to mistake for a generic failure.
      // ignore: avoid_print
      print('[WanPreview] getPreviewSnapshot failed: $reason');
      return null;
    case CameraTimeout():
      // ignore: avoid_print
      print('[WanPreview] getPreviewSnapshot timed out');
      return null;
  }
}

Camera? _findCamera(HomesController homesController, String cameraId) {
  for (final home in homesController.value.homes) {
    for (final camera in home.cameras) {
      if (camera.id == cameraId) return camera;
    }
  }
  return null;
}

/// Writes a real camera snapshot to a fresh, uniquely-named file under the
/// app's documents directory, deleting the previous local snapshot (if any)
/// so they don't accumulate. A fresh filename per sync — rather than
/// overwriting the same path — sidesteps `Image.file`'s path-keyed cache
/// never refreshing when the same path's bytes change underneath it.
/// Returns null (caller falls back to whatever `thumbnailUrl` already was)
/// on any I/O failure.
Future<String?> _saveSnapshotLocally({
  required String cameraId,
  required Uint8List bytes,
  required String? previousThumbnailUrl,
}) async {
  try {
    final dir = await getApplicationDocumentsDirectory();
    final snapshotsDir = Directory('${dir.path}/camera_snapshots');
    if (!await snapshotsDir.exists()) {
      await snapshotsDir.create(recursive: true);
    }
    final file = File(
      '${snapshotsDir.path}/$cameraId-${DateTime.now().millisecondsSinceEpoch}.jpg',
    );
    await file.writeAsBytes(bytes);

    if (previousThumbnailUrl != null &&
        !previousThumbnailUrl.startsWith('http://') &&
        !previousThumbnailUrl.startsWith('https://')) {
      final previousFile = File(previousThumbnailUrl);
      if (await previousFile.exists()) await previousFile.delete();
    }
    return file.path;
  } on Exception {
    return null;
  }
}
