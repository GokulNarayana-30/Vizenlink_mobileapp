import 'dart:math';

import 'iot_mqtt_transport.dart';

/// AWS IoT command channel — `mobile-app-android-3-video-image-pipeline/DESIGN.md` §7 item 1.
///
/// **2026-07-31 rewrite (superseded 2026-08-18, see below)**: this used to call AWS IoT directly
/// (SigV4-signed HTTPS publish + MQTT-over-WSS) using this app's own Cognito Identity
/// Pool-federated credentials. Real-device testing found AWS rejects those credentials for
/// `iot-data:Publish`/MQTT-over-WSS with `ForbiddenException`, regardless of IAM policy —
/// isolated by testing the identical role+policy with root/plain-IAM credentials (succeeded) vs.
/// the Cognito-federated session (failed); see
/// `kb/raw/2026-07-31-fix-iot-command-lambda-relay.md`. Went through
/// `cloud_backend/kvs_playback_lambda` (extended, not a second Lambda) instead for a while — same
/// Cognito ID token this app already uses everywhere else, no AWS credentials needed
/// client-side.
///
/// **2026-08-18: reverted back to direct MQTT.** A latency report (the relay's
/// `_publish_and_wait()` costs up to ~12s per command — a brand-new MQTT connection on every
/// single invocation) prompted re-testing the original restriction live; it no longer
/// reproduces (`kb/raw/2026-08-18-fix-direct-iot-mqtt-restored.md` — a real `GetVideoMode` round
/// trip over direct, persistent MQTT completed in 0.43s). See [IotMqttTransport] for the
/// connection itself; this class is now a thin command-catalog + retry wrapper over it, same
/// role `_post()` played over HTTP before.
///
/// **Moved into `camera_api` 2026-08-11** — [idTokenProvider] and related hooks used to default
/// to this app's own `AuthController`/`AwsConfig`; now they default to `WanAuth`'s static hooks
/// instead, so this package never imports anything app-specific. Set
/// `WanAuth.awsCredentialsProvider`/`WanAuth.awsIotEndpoint`/`WanAuth.awsRegion` once at app
/// startup — see `WanAuth`'s own doc.
class IotCommandClient {
  /// [transport] is overridable for tests — defaults to [IotMqttTransport.instance], the single
  /// shared, persistent MQTT connection every `IotCommandClient` in the app reuses.
  IotCommandClient(this.thingName, {IotTransport? transport})
    : _transport = transport ?? IotMqttTransport.instance;

  final String thingName;
  final IotTransport _transport;

  static String _newRequestId() =>
      '${DateTime.now().microsecondsSinceEpoch}-${Random().nextInt(1 << 32)}';

  // Renamed 2026-08-06 from startLiveStream/stopLiveStream/getStreamStatus — numeric command
  // values unchanged, symbol names only (unified with the new LAN CloudStreaming actions).
  static const startCloudStreaming = 0;
  static const stopCloudStreaming = 1;
  static const getVideoMode = 2;
  static const setVideoMode = 3;
  static const getCloudStreamingStatus = 4;
  static const getWDRMode = 7;
  static const setWDRMode = 8;
  static const setNightVisionType = 9;
  static const getNightVisionType = 10;

  /// `FR-NE-039`: `WanMirrorFlipClient`'s commands — hardware-verified in firmware since
  /// 2026-07-27 but never wired into the app until 2026-08-06.
  static const setMirrorFlip = 11;
  static const getMirrorFlip = 12;
  static const getImageSettings = 13;
  static const setImageSettings = 14;
  static const getImageSettingsOptions = 15;

  /// `FR-NE-076`: read-only factory-default imaging values (`FR-MOB-075`'s "Reset to Default"
  /// source) — distinct from [getImageSettings], which returns the *currently-applied* values.
  static const getImageDefaults = 16;

  /// `FR-NE-078` (NF12): audio recording on/off — implemented and hardware-verified in firmware
  /// since 2026-07-28 (`AUD-MQTT-01/02/03`, `TEST.md` §5.44), but never wired into the app —
  /// `WanAudioVolumeClient` incorrectly documented this as "LAN-only, no WAN mirror" until this
  /// gap was found 2026-08-11.
  static const setAudioRecording = 17;
  static const getAudioRecording = 18;

  /// `FR-NE-085`/`FR-NE-086` (NF14): speaker volume / microphone gain — implemented and
  /// hardware-verified in firmware since 2026-07-28 but never wired into the app until now
  /// (`AudioSettingsScreen` was LAN-only). Plain 0-100 percentages, no ONVIF/camera-capability
  /// backing, so no `Get*Options` counterpart is needed — see
  /// `.claude/rules/camera-firmware.md` § "NuraEye WAN service mirrors every ONVIF Options call".
  static const setSpeakerVolume = 23;
  static const getSpeakerVolume = 24;
  static const setMicGain = 25;
  static const getMicGain = 26;

  /// `FR-NE-087`, added 2026-08-21: local (SD card) storage status/enable — implemented in
  /// firmware since `FR-CF-044`'s original LAN-only build, never wired into the app until now
  /// (`FR-MOB-083`, no `StorageSettingsScreen` existed at all before this).
  static const getLocalStorageStatus = 27;
  static const setLocalStorageEnabled = 28;

  /// `FR-NE-093`/`FR-CF-138`: Full/Zone/None privacy mode — implemented in firmware, never wired
  /// into the app until now (`_PrivacyModeCard` was LAN-only).
  static const setPrivacyMode = 30;
  static const getPrivacyMode = 31;

  /// `FR-NE-106`: Get-side WAN mirror of `setCameraName`(32)/`setCameraLocation`(33)/
  /// `setTimeZone`(34) — added 2026-08-10 to close the one remaining Force-WAN gap that needed
  /// a firmware change (`CameraInfoScreen`'s Name/Location/Time Zone cards previously always
  /// read via LAN ONVIF regardless of `isWan`, since no WAN Get existed at all). One combined
  /// command, not three — see its firmware-side doc in `nuraeye_types.h`.
  static const getDeviceIdentity = 49;

  /// `FR-NE-115`, added 2026-08-21: WAN mirror of ONVIF `GetDeviceInformation` (manufacturer/
  /// model/firmware/serial/hardware ID — the *fixed* build/hardware identity, distinct from
  /// `getDeviceIdentity` above's user-configurable name/location/timezone). Closes the same
  /// "Get always LAN regardless of isWan" gap `getDeviceIdentity` closed for the identity card,
  /// this time for `CameraInfoScreen`'s "Device Information" card.
  static const getDeviceInfo = 66;

  /// `FR-NE-107`: WAN mirror of `AudioVolumeClient`'s `playTestSound`/`stopTestSound`/
  /// `isTestSoundPlaying` — added 2026-08-11, direct user instruction reversing the earlier
  /// LAN-only scoping decision.
  static const playTestSound = 50;
  static const stopTestSound = 51;
  static const getTestSoundStatus = 52;

  /// `FR-NE-099`: WAN mirrors for camera name/location/timezone (ONVIF `SetScopes`/
  /// `SetSystemDateAndTime`, previously LAN-only) and the camera's own local device-account
  /// password (ONVIF `SetUser`) — see `nuraeye_types.h`'s `NuraeyeAwsIotCommandEnum`.
  static const setCameraName = 32;
  static const setCameraLocation = 33;
  static const setTimeZone = 34;
  static const setUserPassword = 35;

  /// `FR-NE-100`: high-resolution-profile (Stream 0) video encoder settings — distinct from the
  /// pre-existing WAN-only `SetStreamQuality`/`GetStreamQuality` (command values 5/6, firmware
  /// `nuraeye.c` only, no Dart client), which target Stream 1's low-res mobile substream.
  static const getVideoEncoderSettings = 36;
  static const setVideoEncoderSettings = 37;
  static const getVideoEncoderSettingsOptions = 38;

  /// Options-parity audit (`kb/raw/2026-08-05-code-options-parity-rule-audit.md`),
  /// `.claude/rules/mobile-app-screen-conventions.md` § "LAN/WAN transport selection for settings screens" item 6.
  static const getStreamQualityOptions = 39;
  static const getImagingSettingsOptions = 40;
  static const getMaskConfigs = 41;
  static const setMaskConfig = 42;
  static const deleteMaskConfig = 43;
  static const getMaskOptions = 44;
  static const getOsdConfigs = 45;
  static const setOsdConfig = 46;
  static const getOsdOptions = 47;
  static const deleteOsdConfig = 48;

  /// `FR-NE-108`: end-to-end-encrypted, non-persisted WAN reference-snapshot preview — distinct
  /// from the persisted cloud-snapshot mechanism (`FR-NE-061`). See `WanPreviewSnapshotClient`.
  static const getPreviewSnapshot = 53;

  /// `FR-NE-109`: anti-flicker/power-line-frequency mode — no ONVIF-standard element (checked
  /// against the live schema), NuraEye-only on both transports, same shape as
  /// `getMirrorFlip`/`setMirrorFlip` above.
  static const getAntiFlickerMode = 54;
  static const setAntiFlickerMode = 55;

  /// `FR-NE-110`: `SystemReboot`/`SetSystemFactoryDefault` are real, standard ONVIF Device
  /// service actions with a full LAN path (`OnvifDeviceClient.reboot`/`factoryReset`) — these
  /// exist purely because ONVIF SOAP has no WAN transport in this stack, same reasoning as
  /// `setCameraName`/`getDeviceIdentity` above. See `WanDeviceIdentityClient.reboot`/
  /// `factoryReset`.
  static const reboot = 56;
  static const factoryReset = 57;

  /// `FR-CF-143`/`FR-NE-111`: per-event-type enable/disable — WAN mirror of the LAN
  /// `GetEventPreferences`/`SetEventPreferences` REST resource. No WAN "supported types"
  /// command — that list is a LAN-only `GetCapabilities` field, per the established
  /// Options/capability-reads-are-LAN-only convention. See `WanEventPreferencesClient`.
  static const getEventPreferences = 58;
  static const setEventPreferences = 59;

  /// `FR-CF-144`/`FR-NE-112`: per-detection-event response-action selection — WAN mirror of the
  /// LAN `GetEventResponseActions`/`SetEventResponseActions` REST resource. No WAN "supported
  /// deterrence options" command — that map is a LAN-only `GetCapabilities` field
  /// (`supportedEventDeterrenceOptions`), same convention. See `WanEventResponseActionsClient`.
  static const getEventResponseActions = 60;
  static const setEventResponseActions = 61;

  /// `FR-NE-082`/`083`: manual deterrence trigger — WAN mirror of the LAN `/nuraeye/deterrence`
  /// REST resource. No `duration_seconds` param (`FEAT-236`, 2026-08-14) — the camera applies
  /// its own persisted, per-action duration instead, see [getDeterrenceDurations]/
  /// [setDeterrenceDurations] below. No WAN "capabilities" command — `siren_capable`/
  /// `spotlight_capable`/`warning_capable` are a LAN-only `GetCapabilities` field, same
  /// Options/capability-reads-are-LAN-only convention as event preferences above. See
  /// `WanDeterrenceClient`.
  static const activateDeterrence = 20;
  static const deactivateDeterrence = 21;
  static const getDeterrenceStatus = 22;

  /// `FR-NE-113`: persisted, per-action auto-stop duration — WAN mirror of the LAN
  /// `GetDeterrenceDurations`/`SetDeterrenceDurations` REST resource (`FEAT-236`, 2026-08-14).
  /// Shared by both this manual trigger and the camera's own automatic detection response
  /// (`FR-CF-144`) — one configured duration per action, not per-trigger-path.
  static const getDeterrenceDurations = 62;
  static const setDeterrenceDurations = 63;

  /// Camera-reported min/max range for each duration/count key (`FEAT-236`, 2026-08-15) — WAN
  /// mirror of the LAN `GET /nuraeye/deterrence/durations/options` REST resource.
  static const getDeterrenceDurationOptions = 64;

  /// `FR-HLT-009` (Stage 3, first slice), 2026-08-25 — WAN mirror of the LAN
  /// `GET /nuraeye/health` REST resource. Read-only, no matching Set command.
  static const getDeviceHealth = 70;

  /// `FR-CF-150`/`FR-NE-121`: loitering-detection dwell threshold, in whole seconds — WAN
  /// mirror of the LAN `GET`/`POST /nuraeye/events/loitering-duration` REST resource. Valid
  /// range comes from `CameraCapabilities.loitering_duration_min_seconds`/`max_seconds` (fixed
  /// compile-time bounds, not camera-reported per-value — no separate Options command, same as
  /// `RecordingsClient`'s clip-duration setting).
  static const setLoiteringDuration = 71;
  static const getLoiteringDuration = 72;

  /// `FR-CF-151`/`FR-NE-123`: whether the camera draws the AI detection bounding-box overlay
  /// (OSD burn-in) on the video stream — WAN mirror of the LAN `GET`/`POST
  /// /nuraeye/events/bbox-overlay` REST resource. Independent of detection/alerts themselves;
  /// no separate Options command — gate the UI on `CameraCapabilities.bboxOverlayCapable`
  /// instead (a fixed build-time flag, not a per-value camera-reported range).
  static const setBboxOverlayEnabled = 73;
  static const getBboxOverlayEnabled = 74;

  /// `FR-CF-152`: WAN recorded-clip playback over a dedicated KVS stream (`<thingName>-playback`)
  /// — see `WanClipPlaybackClient`. `getRecordings`/`getRecordingDates` (80/81) are the MQTT
  /// counterparts of LAN `GET /nuraeye/recordings`(`/dates`) — see `WanRecordingsClient`.
  static const startClipPlayback = 75;
  static const seekClipPlayback = 76;
  static const pauseClipPlayback = 77;
  static const resumeClipPlayback = 78;
  static const stopClipPlayback = 79;
  static const getRecordings = 80;
  static const getRecordingDates = 81;

  /// `StopCloudStreaming` stays fire-and-forget (older command shape, predates `FR-NE-053`'s
  /// request/response pattern) — [token] is optional: omitting it falls back to the camera's
  /// legacy blunt "stop every quality" behavior (`bsp_camera_setCloudStreaming(false)`).
  Future<void> sendStopCloudStreaming({int? token}) => _transport.publish(thingName, {
    'command': stopCloudStreaming,
    if (token != null) 'params': {'token': token},
  });

  /// `FR-CF-154` (2026-09-14): unlike `StopCloudStreaming`, `StartCloudStreaming` now requires
  /// `params.quality` and replies with the viewer's lease token — switched to request/response so
  /// the app can read that token back, matching `GetCloudStreamingStatus`'s existing shape.
  Future<Map<String, dynamic>?> sendStartCloudStreaming(String quality) =>
      sendCommandWithResponse(startCloudStreaming, params: {'quality': quality});

  /// [isRetry] is set by the one-shot retry below, or (2026-09-15) by
  /// [sendCommandWithResponse]'s own `retryOnTimeout: false` opt-out — the only two callers
  /// allowed to pass it explicitly; every other caller should leave it at the default.
  ///
  /// **One-shot retry on no reply within [timeout], added 2026-08-08 (originally for the Lambda
  /// relay's HTTP 504, carried forward 2026-08-18 for the direct-MQTT transport's equivalent
  /// "no reply" case)**: confirmed via direct testing (`GetMirrorFlip` read-back immediately
  /// after a reported app-side timeout) that the camera routinely applies a `Set*` command
  /// correctly even when the reply itself goes missing — transient session/subscribe jitter, not
  /// a stuck camera. A second attempt is a real second chance, not a repeat of the same failure,
  /// so one retry is worth it before surfacing an error to the user. Every `Wan*Client` gets this
  /// for free since they all route through this method. A genuine camera-side failure
  /// (`status != "ok"`) is a different, non-retried case — only a bare timeout (no reply at all)
  /// is worth retrying.
  Future<Map<String, dynamic>?> _publishAndWait(
    int command, {
    Map<String, dynamic>? params,
    Duration timeout = const Duration(seconds: 12),
    bool isRetry = false,
  }) async {
    final requestId = _newRequestId();
    final reply = await _transport.publishAndWait(thingName, {
      'command': command,
      'request_id': requestId,
      if (params != null) 'params': params,
    }, timeout: timeout);

    if (reply == null) {
      if (isRetry) {
        throw Exception('No response from camera (timed out)');
      }
      return _publishAndWait(command, params: params, timeout: timeout, isRetry: true);
    }
    if (reply['status'] != 'ok') {
      throw Exception('Command $command failed on camera');
    }
    return reply;
  }

  /// Generic request/response path for any `NuraeyeAwsIotCommand` that replies on the response
  /// topic (`nuraeye.c`'s `prvPublishMqttResponse()`) — added for `FR-MOB-068` (Night Vision Type
  /// over WAN, `getNightVisionType`/`setNightVisionType` above) but not specific to it. Used for
  /// `GetCloudStreamingStatus` (`FR-NE-068`) too — the app and firmware are the only two parties
  /// that need to agree on what a command number means (`nuraeye_types.h`'s
  /// `NuraeyeAwsIotCommandEnum`), so one generic path covers every command.
  /// [timeoutSeconds], if given, overrides the default ~12s wait for the camera's reply — for a
  /// command known to legitimately take longer (e.g. [getPreviewSnapshot]'s on-device capture +
  /// RSA-2048 encrypt), not a general escape hatch.
  ///
  /// [retryOnTimeout] (default `true`) opts out of the one-shot retry documented on
  /// [_publishAndWait]. Only pass `false` from a caller that already polls on its own schedule —
  /// e.g. a reachability ping, where the retry doubles worst-case latency to buy a second chance
  /// the next tick provides anyway. Every user-initiated Get/Set should keep the retry: for
  /// those, a missing reply is a one-shot failure the user would otherwise have to notice and
  /// redo manually.
  Future<Map<String, dynamic>?> sendCommandWithResponse(
    int command, {
    Map<String, dynamic>? params,
    double? timeoutSeconds,
    bool retryOnTimeout = true,
  }) async {
    final reply = await _publishAndWait(
      command,
      params: params,
      timeout: timeoutSeconds != null
          ? Duration(milliseconds: (timeoutSeconds * 1000).round())
          : const Duration(seconds: 12),
      // `isRetry: true` on the first attempt makes the no-reply path in _publishAndWait throw
      // immediately instead of scheduling the retry — same branch, no duplicate logic.
      isRetry: !retryOnTimeout,
    );
    if (reply == null) return null; // genuine timeout — no reply arrived at all
    // [AI Fix] Get/Set response asymmetry (see `.claude/rules/cloud-components.md` — the exact
    // rule BUG-006 established for the old Lambda relay, which used to enforce this same
    // defaulting server-side): every Get* reply carries an `output` object, but every Set*/
    // Delete* success reply omits it entirely (`nuraeye.c`'s `prvPublishMqttResponse(request_id,
    // success, NULL)`) — real, hardware-confirmed here too, not just historically: a Set command
    // over the direct-MQTT transport got its reply in well under a second, but every caller's
    // `output == null` timeout check couldn't tell that apart from no reply ever arriving. Default
    // to an empty map on any successful reply with no `output` key, so only a genuine "no reply"
    // is ever reported as null.
    return (reply['output'] as Map<String, dynamic>?) ?? const {};
  }
}
