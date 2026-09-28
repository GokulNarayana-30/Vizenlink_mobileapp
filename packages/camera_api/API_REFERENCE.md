# camera_api — API Reference

`camera_api` is a pure-Dart package (**zero `package:flutter` dependency**) that is the sole
network-access layer for talking to a NuraEye/VizenLink IP camera, over both LAN and WAN (AWS
IoT). It has no UI logic of its own — it is meant to be consumed by a Flutter app's business
logic layer (or, in principle, by any other pure-Dart tool, such as an in-app agent's tool
registry). Every method that talks to the network is asynchronous and returns a typed
[`CameraResult<T>`](#result-type) rather than throwing — see that section for the pattern every
caller uses.

This file is organized by **client class** (mechanical params/returns, no decision logic). If
you know *which camera setting* you're implementing but not yet *which client* is correct for
it — settings that sound alike or overlap across LAN/WAN (e.g. Day/Night mode vs. Night Vision
Type), which capability/support flag gates a given setting (e.g. `wdrSupported`,
`hasMicrophone`, `wanCommandCapable` — there are over a dozen of these across the package, each
gating a different client), or why a `Wan*Client` call is failing (every WAN call requires the
user to be signed in via `auth_api`, checked before any capability flag) — see
[SETTINGS_API_GUIDE.md](SETTINGS_API_GUIDE.md) first.

## Folder layout

```
lib/
  camera_api.dart              — public barrel file (only what it exports is public API)
  src/
    camera_connection.dart     — CameraConnection (identifies/authenticates one camera)
    camera_result.dart         — CameraResult / CameraSuccess / CameraFailure / CameraTimeout
    mirror_flip_types.dart     — shared MirrorFlipMode enum (LAN + WAN pair)
    anti_flicker_types.dart    — shared AntiFlickerMode enum (LAN + WAN pair)
    night_vision_types.dart    — shared NightVisionType/NightVisionStatus/NightVisionSource
    privacy_mode_types.dart    — shared PrivacyMode enum (LAN + WAN pair)
    device_reset_types.dart    — shared FactoryResetMode enum (LAN + WAN pair)
    util/
      onvif_rect_coordinates.dart  — pixel <-> ONVIF-normalized-polygon math (masks/OSD)
    media/
      fmp4_muxer.dart              — RtspFmp4Muxer/VideoCodec: NALU + AAC access units -> fMP4
                                      boxes (init segment + per-sample fragments). Shared by LAN
                                      (`RtspLiveViewProxy`/`RtspRemuxProxy`, `mobile_app/lib`) and
                                      WAN (`KvsMediaLiveViewSession`, below) — moved here from the
                                      app layer 2026-09-18 specifically so the WAN path could reuse
                                      it instead of a second, independently-written muxer
                                      (`kvs_fmp4_muxer.dart`, deleted the same day — see
                                      `KvsMediaLiveViewSession`'s own doc below for why).
    lan/
      wsse_digest.dart              — shared WSSE-style SHA-1 digest auth
      insecure_camera_http_client.dart — HTTP client that trusts the camera's self-signed cert
      onvif/                        — pure ONVIF SOAP clients
        onvif_device_client.dart
        onvif_imaging_client.dart
        onvif_video_encoder_client.dart
        osd_client.dart
        mask_client.dart
        audio_capability_client.dart
        media2_capabilities_client.dart
        speaker_volume_client.dart
        onvif_recording_client.dart    — Profile G Recording Control (client-only, unused for now)
        onvif_search_client.dart       — Profile G Search (client-only, unused for now)
        onvif_replaycontrol_client.dart — Profile G Replay Control (client-only, unused for now)
        soap_fault.dart             — shared <Fault> detection, used by every client's _post()
      nuraeye/                      — the proprietary /nuraeye/* REST API
        nuraeye_client.dart         — core dispatcher (hand-written, everything else calls through it)
        audio_volume_client.dart
        bbox_overlay_client.dart
        event_preferences_client.dart
        event_response_actions_client.dart
        capabilities_client.dart
        deterrence_client.dart
        loitering_duration_client.dart
        cloud_streaming_client.dart
        mirror_flip_client.dart
        anti_flicker_client.dart
        network_info_client.dart
        night_vision_client.dart
        privacy_mode_client.dart
        local_storage_client.dart
        recording_mode_client.dart
        health_client.dart
        recordings_client.dart
        snapshot_client.dart
        live_stream_uri_client.dart
        talk_uri_client.dart
        nuraeye_rest_client.dart    — GENERATED (base REST transport)
        rest_*.dart                 — GENERATED (typed per-group REST clients)
        rest_result.dart            — GENERATED (RestResult/RestSuccess/RestFailure/RestTimeout)
      discovery/
        ws_discovery_client.dart    — WS-Discovery UDP client (find cameras on the LAN)
    wan/                           — AWS IoT MQTT command relay + KVS playback
      wan_auth.dart                — app-supplied auth/config hooks (set once at startup)
      iot_command_client.dart      — low-level command-relay transport
      kvs_media/
        kvs_media_viewer_credentials_client.dart — vends short-lived stream-scoped AWS creds
        mkv_demuxer.dart            — streaming EBML/MKV parser (KVS GetMedia wire format)
        kvs_get_media_client.dart   — signed POST /getMedia, returns the raw MKV byte stream
        kvs_media_live_view_session.dart — orchestrates the above + a local HTTP loopback server
      wan_live_view_client.dart    — WanLiveViewClient interface
      aws_wan_live_view_client.dart — concrete WanLiveViewClient implementation
      wan_audio_volume_client.dart
      wan_bbox_overlay_client.dart
      wan_deterrence_client.dart
      wan_loitering_duration_client.dart
      wan_device_identity_client.dart
      wan_image_quality_client.dart
      wan_imaging_client.dart
      wan_mask_client.dart
      wan_mirror_flip_client.dart
      wan_anti_flicker_client.dart
      wan_event_preferences_client.dart
      wan_event_response_actions_client.dart
      wan_night_vision_client.dart
      wan_osd_client.dart
      wan_preview_snapshot_client.dart
      wan_local_storage_client.dart
      wan_recording_mode_client.dart
      wan_health_client.dart
      wan_privacy_mode_client.dart
      wan_speaker_volume_client.dart
      wan_video_encoder_client.dart
```

`lan/onvif/` and `lan/nuraeye/` are kept as separate protocol families deliberately: the former
speaks ONVIF SOAP (WS-UsernameToken digest auth), the latter speaks the camera's proprietary
`/nuraeye/*` JSON REST API (bearer-session auth). `wan/` mirrors a subset of `lan/nuraeye/`'s
settings one-for-one, over AWS IoT MQTT via a Lambda relay, for when the phone isn't on the same
network as the camera.

## Table of contents

- [Result type](#result-type)
- [Connecting to a camera](#connecting-to-a-camera)
- [LAN — ONVIF](#lan--onvif)
  - [OnvifDeviceClient](#onvifdeviceclient)
  - [OnvifImagingClient](#onvifimagingclient)
  - [OnvifVideoEncoderClient](#onvifvideoencoderclient)
  - [OsdClient](#osdclient)
  - [MaskClient](#maskclient)
  - [AudioCapabilityClient](#audiocapabilityclient)
  - [Media2CapabilitiesClient](#media2capabilitiesclient)
  - [SpeakerVolumeClient](#speakervolumeclient)
  - [OnvifRecordingClient](#onvifrecordingclient)
  - [OnvifSearchClient](#onvifsearchclient)
  - [OnvifReplayControlClient](#onvifreplaycontrolclient)
- [LAN — NuraEye REST](#lan--nuraeye-rest)
  - [Hand-written clients](#hand-written-clients)
    - [NuraeyeClient](#nuraeyeclient)
    - [AudioVolumeClient](#audiovolumeclient)
    - [BboxOverlayClient](#bboxoverlayclient)
    - [EventPreferencesClient](#eventpreferencesclient)
    - [EventResponseActionsClient](#eventresponseactionsclient)
    - [DeterrenceClient](#deterrenceclient)
    - [LoiteringDurationClient](#loiteringdurationclient)
    - [CapabilitiesClient](#capabilitiesclient)
    - [CloudStreamingLanClient](#cloudstreaminglanclient)
    - [MirrorFlipClient](#mirrorflipclient)
    - [AntiFlickerClient](#antiflickerclient)
    - [NetworkInfoClient](#networkinfoclient)
    - [NightVisionClient](#nightvisionclient)
    - [PrivacyModeClient](#privacymodeclient)
    - [LocalStorageClient](#localstorageclient)
    - [RecordingModeClient](#recordingmodeclient)
    - [HealthClient](#healthclient)
    - [RecordingsClient](#recordingsclient)
    - [SnapshotClient](#snapshotclient)
    - [LiveStreamUriClient](#livestreamuriclient)
    - [TalkUriClient](#talkuriclient)
  - [Generated REST clients](#generated-rest-clients)
- [LAN — Discovery](#lan--discovery)
  - [WsDiscoveryClient](#wsdiscoveryclient)
- [WAN — AWS IoT / KVS](#wan--aws-iot--kvs)
  - [WanAuth](#wanauth)
  - [IotCommandClient](#iotcommandclient)
  - [KvsMediaViewerCredentialsClient](#kvsmediaviewercredentialsclient)
  - [KvsGetMediaClient](#kvsgetmediaclient)
  - [KvsMediaLiveViewSession](#kvsmedialiveviewsession)
  - [WanLiveViewClient / AwsWanLiveViewClient](#wanliveviewclient--awswanliveviewclient)
  - [WanAudioVolumeClient](#wanaudiovolumeclient)
  - [WanBboxOverlayClient](#wanbboxoverlayclient)
  - [WanSpeakerVolumeClient](#wanspeakervolumeclient)
  - [WanDeviceIdentityClient](#wandeviceidentityclient)
  - [WanImageQualityClient](#wanimagequalityclient)
  - [WanImagingClient](#wanimagingclient)
  - [WanMaskClient](#wanmaskclient)
  - [WanMirrorFlipClient](#wanmirrorflipclient)
  - [WanAntiFlickerClient](#wanantiflickerclient)
  - [WanEventPreferencesClient](#waneventpreferencesclient)
  - [WanEventResponseActionsClient](#waneventresponseactionsclient)
  - [WanDeterrenceClient](#wandeterrenceclient)
  - [WanLoiteringDurationClient](#wanloiteringdurationclient)
  - [WanNightVisionClient](#wannightvisionclient)
  - [WanOsdClient](#wanosdclient)
  - [WanLocalStorageClient](#wanlocalstorageclient)
  - [WanRecordingModeClient](#wanrecordingmodeclient)
  - [WanHealthClient](#wanhealthclient)
  - [WanRecordingsClient](#wanrecordingsclient)
  - [WanClipPlaybackClient](#wanclipplaybackclient)
  - [WanPrivacyModeClient](#wanprivacymodeclient)
  - [WanVideoEncoderClient](#wanvideoencoderclient)
  - [WanPreviewSnapshotClient](#wanpreviewsnapshotclient)
- [Shared types](#shared-types)
- [Getting started](#getting-started)

---

## Result type

Every network-calling method returns `Future<CameraResult<T>>`. `CameraResult<T>` is a sealed
class with three cases:

```dart
sealed class CameraResult<T> {}

class CameraSuccess<T> extends CameraResult<T> {
  final T value;
}

/// A request the camera actively rejected or failed to service (HTTP error, SOAP Fault, MQTT
/// error response). Distinct from CameraTimeout because a rejection is informative (e.g. wrong
/// password, unsupported feature), while a timeout only means "no answer".
class CameraFailure<T> extends CameraResult<T> {
  final String reason;
}

/// No response arrived within the call's bounded timeout.
class CameraTimeout<T> extends CameraResult<T> {}
```

Callers pattern-match with Dart's `switch` and object patterns:

```dart
switch (result) {
  case CameraSuccess(:final value):
    // use value
  case CameraFailure(:final reason):
    // show reason to the user / log it
  case CameraTimeout():
    // camera unreachable / no response in time
}
```

This is the API-stability contract of the package: no client ever returns a formatted string,
throws an app-level exception, or exposes a raw HTTP/SOAP/MQTT error — always one of these three
structured values, so both a human UI and a future automated caller can consume the exact same
return shape.

A parallel, internal-only `RestResult<T>` (`RestSuccess`/`RestFailure`/`RestTimeout`) exists in
`lan/nuraeye/rest_result.dart` for the generated REST-transport layer — it additionally carries
an HTTP status code on failure. App code should not normally need to touch it; `NuraeyeClient`
already translates it into `CameraResult` at its boundary.

---

## Connecting to a camera

`CameraConnection` is an immutable value identifying and authenticating against one camera.
Every client in this package takes a `CameraConnection` (or something built from one) in its
constructor.

```dart
const CameraConnection({
  required String host,        // LAN IP/hostname — NOT used for WAN, and not a stable identity
  required String username,
  required String password,
  int httpsPort = 443,
  int rtspPort = 554,
  String? thingName,           // AWS IoT thing name — required for any WAN call
  bool? wanLiveViewCapable,    // null = unknown (not yet queried), not "unsupported"
  bool? wanCommandCapable,     // null = unknown; AWS IoT/MQTT support (independent of KVS)
  String? macAddress,          // stable identity across DHCP lease changes
});
```

Key members:

| Member | Description |
|---|---|
| `identityKey` | `macAddress ?? host` — the key every local cache/store should use to recognize "which camera is this." **Never key a local store on `host` directly** — a DHCP renewal can change it for the same physical camera. |
| `onvifDeviceEndpoint` / `onvifImagingEndpoint` / `onvifMediaEndpoint` | Fixed ONVIF SOAP endpoint URIs derived from `host`/`httpsPort`. |
| `snapshotEndpoint({String profile = 'high'})` | `GET /snapshot` URI. `profile` is `"high"`, `"medium"`, or `"low"` — one of the camera's fixed ONVIF profile names. Use `"high"` for a user-facing capture, `"medium"` for a lightweight click-to-draw backdrop (mask/OSD editors). |
| `copyWithThingName(String)` | Returns a new connection with `thingName` set (once resolved via `OnvifDeviceClient.getSerialNumber()` at onboarding). |
| `copyWithWanCapabilities({required bool wanLiveViewCapable, required bool wanCommandCapable})` | Returns a new connection with both WAN-capability flags set — both come from the same `GetCapabilities` call, so they're set together (**renamed from `copyWithWanLiveViewCapable` 2026-08-14** when `wanCommandCapable` was added — it was being fetched at onboarding but silently discarded, so nothing could gate the Alerts screen on it even though alert delivery is exclusively WAN MQTT; see `CameraAlertsScreen`). |
| `copyWithMacAddress(String)` | Returns a new connection with `macAddress` set. |
| `copyWithPassword(String)` | Returns a new connection with `password` replaced — call after a successful password change; the old connection keeps using its old password otherwise. |
| `toJson()` / `CameraConnection.fromJson(Map)` | Plain-Dart JSON (de)serialization, for the app's own local persistence. |

`CameraConnection` is only ever mutated by constructing a new instance — every `copyWith*`
method returns a fresh object.

---

## LAN — ONVIF

Every client in this section speaks ONVIF SOAP over HTTPS, authenticated with a WS-UsernameToken
digest (`wsse_digest.dart`'s `WsseDigest`, shared with the NuraEye REST login and snapshot auth).
All requests go through `insecure_camera_http_client.dart`'s `createCameraHttpClient()`, which
trusts the camera's self-signed certificate and preserves outgoing HTTP header case (the
camera's embedded server matches header names case-sensitively).

**Every client's `_post()` checks the response body for a SOAP `<Fault>` element via
`soap_fault.dart`'s `soapFaultReason()`, *before* checking the HTTP status code, not after.**
This camera's firmware doesn't use one consistent HTTP status for a fault, in either direction —
Media2 validation errors (e.g. `SetOSD` rejecting an out-of-range color via `ter:InvalidArgVal`)
come back as `HTTP 200` with a `<s:Fault>` body, which an HTTP-status-only check would silently
treat as success; other faults (e.g. `GetReplayUri`'s `OperationProhibited`/409 rejection of a
second concurrent playback client) come back on a genuinely non-200 status *with* a real
`<Fault>` body. **Real bug, found and fixed 2026-09-24 across all 11 clients in this section**:
every one of them checked HTTP status first and returned the raw, unparsed SOAP XML as the error
string for the second case — surfacing as a raw SOAP response dumped straight into a screen's
error text instead of a real message. Any new ONVIF client added to this section must call
`soapFaultReason(response.body)` first, and only fall back to a raw `HTTP <code>: <body>` failure
message once that returns `null` (a genuinely non-SOAP failure, e.g. a proxy's own 502/503 HTML
page) — see `soap_fault.dart`'s own doc comment for the full reasoning.

### OnvifDeviceClient

`lan/onvif/onvif_device_client.dart` — `GetDeviceInformation`, `GetServices` (real ONVIF
service-discovery — other clients resolve their Media2 endpoint through this rather than a
hardcoded path), the device-identity trio (`GetScopes`/`SetScopes`, `GetSystemDateAndTime`/
`SetSystemDateAndTime`), account-password change, and reboot/factory-reset (`SystemReboot`/
`SetSystemFactoryDefault` — see `WanDeviceIdentityClient` for the WAN mirrors, since ONVIF SOAP
itself has no WAN transport).

```dart
OnvifDeviceClient(CameraConnection connection, {http.Client? httpClient})
```

| Method | Params | Returns | Description |
|---|---|---|---|
| `getSerialNumber` | `{Duration timeout}` | `CameraResult<String>` | The camera's serial number — also its AWS IoT thing name/KVS stream name. Used at onboarding to populate `CameraConnection.thingName`. |
| `getDeviceInformation` | `{Duration timeout}` | `CameraResult<DeviceInformation>` | Full `GetDeviceInformation` (manufacturer/model/firmware/serial/hardware ID). |
| `getNetworkInterfaceInfo` | `{Duration timeout}` | `CameraResult<NetworkInterfaceInfo>` | The camera's active network interface (name/MAC/IPv4). `NetworkInterfaceInfo.isWireless` distinguishes wired vs WiFi. |
| `getServices` | `{Duration timeout}` | `CameraResult<List<OnvifServiceEntry>>` | Real ONVIF service discovery (`IncludeCapability: false`) — a missing entry means this camera build genuinely doesn't offer that service. |
| `getDeviceIdentity` | `{Duration timeout}` | `CameraResult<DeviceIdentity>` | Current display name + location (`GetScopes`). Either can be empty. |
| `setDeviceName` | `String name, {Duration timeout}` | `CameraResult<void>` | Sets display name only — name and location are set independently. |
| `setDeviceLocation` | `String location, {Duration timeout}` | `CameraResult<void>` | Sets location label only. |
| `getSystemDateAndTime` | `{Duration timeout}` | `CameraResult<DeviceDateTime>` | Camera's UTC clock + POSIX-style time zone string. |
| `setTimeZone` | `String tz, {Duration timeout}` | `CameraResult<void>` | Changes only the time zone — internally re-reads the current clock first and echoes it back, since the firmware requires a full Manual date/time on every `SetSystemDateAndTime` call. |
| `setUserPassword` | `String username, String newPassword, {Duration timeout}` | `CameraResult<void>` | Changes the camera's single local device account password (shared by ONVIF + NuraEye). **Caller must update its own stored `CameraConnection.password` on success** — this client keeps using the password it was constructed with. |
| `reboot` | `{Duration timeout}` | `CameraResult<String>` | Reboots the camera (`SystemReboot`). Returns the camera's `tt:Message` (typically `"Rebooting in 5 seconds"`). Success does **not** mean the device is back yet — expect a real connectivity gap of several seconds. |
| `factoryReset` | `FactoryResetMode mode, {Duration timeout}` | `CameraResult<void>` | Resets to factory defaults (`SetSystemFactoryDefault`). See [`FactoryResetMode`](#shared-types) for the Soft/Hard distinction — `hard` wipes WiFi credentials, forcing re-onboarding. **The camera reboots automatically afterward** (`bsp_rebootAsync()`) — same connectivity-gap caveat as `reboot` above, success does not mean the device is back yet. |
| `close` | — | `void` | Closes the underlying HTTP client. |

Constants: `kMaxDeviceNameLength`/`kMaxDeviceLocationLength` = 32, `kMaxDevicePasswordLength` =
15 — client-side length limits matching firmware constraints.

### OnvifImagingClient

`lan/onvif/onvif_imaging_client.dart` — Day/Night, WDR, and ISP image-quality controls, all
riding ONVIF's `GetImagingSettings`/`SetImagingSettings`/`GetOptions`. No WAN counterpart exists
in this package for the *settings* client itself (see `WanImagingClient`/`WanImageQualityClient`
for the WAN mirrors of these same fields, added later).

```dart
OnvifImagingClient(CameraConnection connection, {http.Client? httpClient})
```

| Method | Params | Returns | Description |
|---|---|---|---|
| `getImagingSettings` | `{Duration timeout}` | `CameraResult<ImagingSettings>` | Current brightness/saturation/contrast/sharpness, Day/Night mode, WDR mode+level, exposure mode/time/gain, white-balance mode. |
| `getImagingOptions` | `{Duration timeout}` | `CameraResult<ImagingOptions>` | Bounds/choice lists for every field above. Always a live network call — this package carries no caching of its own (moved to the app layer 2026-08-28, see `mobile_app/lib/features/settings/camera_settings_cache.dart`'s `NetworkAnswerCache`). |
| `setImagingSettings` | `ImagingSettings settings, {Duration timeout}` | `CameraResult<void>` | Applies only the non-null fields of `settings` (matches firmware's optional-field semantics). |
| `close` | — | `void` | Closes the underlying HTTP client. |

`ImagingOptions.wdrSupported == false` means the WDR options element was entirely absent
(non-HDR sensor) — the UI should hide WDR outright, not just disable it.

### OnvifVideoEncoderClient

`lan/onvif/onvif_video_encoder_client.dart` — video encoder settings for **any** of the camera's
streams via ONVIF **Media2** (`GetProfiles`/`GetVideoEncoderConfigurations`/
`SetVideoEncoderConfiguration`/`GetVideoEncoderConfigurationOptions`). Originally scoped to the
high-resolution profile only (Stream 0, `VideoEncoderCfg_1`); generalized 2026-09-10 to take a
`configToken` on every method (`kHighResVideoEncoderToken`/`kMediumResVideoEncoderToken`/
`kLowResVideoEncoderToken`, or any token [getProfiles] reports), defaulting to
`kHighResVideoEncoderToken` for source compatibility with call sites written before this client
addressed more than one stream. Distinct from the older, narrower WAN-only
`SetStreamQuality`/`GetStreamQuality`, which stay hardcoded to Stream 1's low-res mobile
substream and never accept a resolution.

```dart
OnvifVideoEncoderClient(CameraConnection connection, {http.Client? httpClient, Uri? endpoint})
```

`endpoint` seeds the resolved Media2 service endpoint (skips the `GetServices` round trip) — pass
a previously-resolved value (e.g. from `mobile_app`'s `NetworkAnswerCache`) if the caller has one.

| Method | Params | Returns | Description |
|---|---|---|---|
| `getProfiles` | `{Duration timeout}` | `CameraResult<List<MediaProfile>>` | Every ONVIF media profile the camera currently reports (`GetProfiles`, no token filter) — token, name, video-encoder-config token, and current resolution for each. Use this to discover how many streams exist; never hardcode a count or a `VideoEncoderCfg_N` list. |
| `getVideoEncoderSettings` | `{String configToken = kHighResVideoEncoderToken, Duration timeout}` | `CameraResult<VideoEncoderSettings>` | Current bitrate, frame rate, GOV length, quality, encoder profile, width/height, encoding (`"H264"`/`"H265"`), CBR/VBR flag, for the given stream's config. |
| `setVideoEncoderSettings` | `VideoEncoderSettings settings, {Duration timeout}` | `CameraResult<void>` | Always sends the full configuration — SOAP `SetVideoEncoderConfiguration` has no partial-update mode. Targets `settings.token`, so pass the same token `getVideoEncoderSettings` was called with. |
| `getVideoEncoderSettingsOptions` | `{String configToken = kHighResVideoEncoderToken, Duration timeout}` | `CameraResult<VideoEncoderSettingsOptions>` | Bounds/choices per encoding (H264 and H265 report different ranges/profiles/CBR support), for the given stream's config. Always a live network call — no caching in this package (moved to the app layer 2026-08-28). |
| `resolveMedia2Endpoint` | `{Duration timeout}` | `CameraResult<Uri>` | Resolves (and remembers for this instance's life) the Media2 endpoint via `GetServices`, unless `endpoint` was already seeded. |
| `resolvedEndpoint` (getter) | — | `Uri?` | The endpoint this instance has resolved so far, or `null`. Read this after a successful call to persist it in the app-level cache for next time. |
| `close` | — | `void` | Closes the HTTP client and internal `OnvifDeviceClient`. |

**Shared types**: `MediaProfile` (`{token, name, videoEncoderConfigToken, resolution}`) —
`getProfiles`'s result element. `kHighResVideoEncoderToken`/`kMediumResVideoEncoderToken`/
`kLowResVideoEncoderToken` (`"VideoEncoderCfg_1"`/`"_2"`/`"_3"`) — the well-known tokens for this
firmware's fixed 3-stream set (high/medium/low), for callers that don't need to call `getProfiles`
first.

Endpoint/Options caching is **instance-lifetime only** now, not process-lifetime — see
`.claude/rules/mobile-app-screen-conventions.md`'s "Caching capability/service-discovery
responses" section for where the process-lifetime cache moved to (`mobile_app`'s
`NetworkAnswerCache`).

`VideoEncoderSettingsOptions.forEncoding(String)` returns the `EncodingOptions` for a given
codec; `.availableEncodings` lists the codecs the camera reports.

### OsdClient

`lan/onvif/osd_client.dart` — On-Screen Display: timestamp overlay and free-text overlay, via
ONVIF **Media2** (`GetOSDs`/`CreateOSD`/`SetOSD`/`DeleteOSD`/`GetOSDOptions`). **Not yet
hardware-verified against a real camera** (no `testing_utilities/*.py` reference script exists
for OSD; wire format matched directly against firmware source).

```dart
OsdClient(CameraConnection connection, {http.Client? httpClient, Uri? endpoint})
```

`endpoint` seeds the resolved Media2 service endpoint — see `OnvifVideoEncoderClient`'s doc above
for the same convention.

| Method | Params | Returns | Description |
|---|---|---|---|
| `getOsds` | `{Duration timeout}` | `CameraResult<List<OsdEntry>>` | Currently-configured OSD entries (both slots ship enabled by default). |
| `createTimestampOsd` | `{String posType, double posX, double posY, String dateFormat, String timeFormat, OsdColor? fontColor, Duration timeout}` | `CameraResult<String>` | Creates the `DateAndTime` slot. Returns the new OSD token. |
| `createTextOsd` | `String text, {String posType, double posX, double posY, OsdColor? fontColor, Duration timeout}` | `CameraResult<String>` | Creates the `Plain` (free-text) slot. Returns the new OSD token. |
| `updateTextOsd` | `String token, String text, {String posType, double posX, double posY, OsdColor? fontColor, Duration timeout}` | `CameraResult<void>` | Updates the Plain OSD in place, keeping its token. |
| `updateTimestampPosition` | `String token, {String posType, required double posX, required double posY, String dateFormat, String timeFormat, OsdColor? fontColor, Duration timeout}` | `CameraResult<void>` | Updates the DateAndTime OSD in place, keeping its token. |
| `getOsdOptions` | `{Duration timeout}` | `CameraResult<OsdOptions>` | Font size range, color support, position/date/time-format choices. Always a live network call — no caching in this package (moved to the app layer 2026-08-28). |
| `deleteOsd` | `String token, {Duration timeout}` | `CameraResult<void>` | Removes an OSD entry ("off" is modeled as delete, not a hide flag). |
| `resolveMedia2Endpoint` | `{Duration timeout}` | `CameraResult<Uri>` | Resolves (and remembers for this instance's life) the Media2 endpoint via `GetServices`. |
| `resolvedEndpoint` (getter) | — | `Uri?` | The endpoint this instance has resolved so far, or `null`. |
| `close` | — | `void` | Closes the HTTP client and internal `OnvifDeviceClient`. |

Position-type constants: `kOsdPositionCustom`, `kOsdPositionUpperLeft`,
`kOsdPositionUpperRight`, `kOsdPositionLowerLeft`, `kOsdPositionLowerRight`. `posX`/`posY` (each
in `[-1, 1]`) are only meaningful/sent when `posType == kOsdPositionCustom`.

### MaskClient

`lan/onvif/mask_client.dart` — Privacy mask editor backend via ONVIF **Media2**
(`CreateMask`/`SetMask`/`DeleteMask`/`GetMasks`/`GetMaskOptions`). Always sends a 4-point
rectangle polygon. **Not yet hardware-verified** against a real camera.

```dart
MaskClient(CameraConnection connection, {http.Client? httpClient, Uri? endpoint})
```

`endpoint` seeds the resolved Media2 service endpoint — see `OnvifVideoEncoderClient`'s doc above
for the same convention. **Endpoint/Options caching moved to the app layer 2026-08-28** (this
class used to keep both as `static`, process-lifetime maps — see
`.claude/rules/mobile-app-screen-conventions.md`'s "Caching capability/service-discovery
responses" section).

| Method | Params | Returns | Description |
|---|---|---|---|
| `getMasks` | `{Duration timeout}` | `CameraResult<List<MaskEntry>>` | Currently-configured masks. |
| `getMaskOptions` | `{Duration timeout}` | `CameraResult<MaskOptions>` | `MaxMasks`/`MaxPoints`/supported types/colors. Always a live network call — no caching in this package. |
| `createMask` | `{required List<OnvifPoint> polygon, required bool enabled, required String type, MaskColor? color, Duration timeout}` | `CameraResult<String>` | Creates a new mask. Returns its token. |
| `setMask` | `{required String token, required List<OnvifPoint> polygon, required bool enabled, required String type, MaskColor? color, Duration timeout}` | `CameraResult<void>` | Updates an existing mask in place. |
| `deleteMask` | `String token, {Duration timeout}` | `CameraResult<void>` | Removes a mask. |
| `resolveMedia2Endpoint` | `{Duration timeout}` | `CameraResult<Uri>` | Resolves (and remembers for this instance's life) the Media2 endpoint via `GetServices`. |
| `resolvedEndpoint` (getter) | — | `Uri?` | The endpoint this instance has resolved so far, or `null`. |
| `close` | — | `void` | Closes the HTTP client and internal `OnvifDeviceClient`. |

`MaskEntry.type` is echoed by ONVIF but only `"Color"` (a fixed black rectangle) is actually
rendered by this firmware today — gate UI on `MaskOptions.types`/`colorList`, not on assuming
all three ONVIF mask types work.

### AudioCapabilityClient

`lan/onvif/audio_capability_client.dart` — audio hardware **presence** check (not
configuration), used to gate the two-way-talk control. **Media2** (`GetAudioSourceConfigurations`/
`GetAudioOutputConfigurations` with a fixed `ConfigurationToken`) — migrated off Media v1's
`GetAudioSources`/`GetAudioOutputs` 2026-08-12 for consistency with every other ONVIF client in
this package.

```dart
AudioCapabilityClient(CameraConnection connection, {http.Client? httpClient, Uri? endpoint})
```

`endpoint` seeds the resolved Media2 service endpoint — see `OnvifVideoEncoderClient`'s doc above
for the same convention.

| Method | Params | Returns | Description |
|---|---|---|---|
| `getAudioCapability` | `{Duration timeout}` | `CameraResult<AudioCapability>` | `hasSpeaker` (`GetAudioOutputConfigurations` non-empty) and `hasMicrophone` (`GetAudioSourceConfigurations` non-empty). |
| `resolveMedia2Endpoint` | `{Duration timeout}` | `CameraResult<Uri>` | Resolves (and remembers for this instance's life) the Media2 endpoint via `GetServices`. |
| `resolvedEndpoint` (getter) | — | `Uri?` | The endpoint this instance has resolved so far, or `null`. |
| `close` | — | `void` | Closes the HTTP client and internal `OnvifDeviceClient`. |

### Media2CapabilitiesClient

`lan/onvif/media2_capabilities_client.dart` — whether this camera advertises OSD/Mask support at
all, via Media2 `GetServiceCapabilities`. Resolves its endpoint through `OnvifDeviceClient
.getServices()` rather than a hardcoded path; a camera with no Media2 service at all returns a
normal "not supported" success result, not a failure.

```dart
Media2CapabilitiesClient(CameraConnection connection, {http.Client? httpClient})
```

| Method | Params | Returns | Description |
|---|---|---|---|
| `getServiceCapabilities` | `{Duration timeout}` | `CameraResult<Media2Capabilities>` | `osdSupported`/`maskSupported` booleans. |
| `close` | — | `void` | Closes the HTTP client and internal `OnvifDeviceClient`. |

### SpeakerVolumeClient

`lan/onvif/speaker_volume_client.dart` — camera-side speaker output volume via ONVIF Media2
(`GetAudioOutputConfigurations`/`SetAudioOutputConfiguration`). Distinct from the phone's own
local volume. Hardware-verified (against an earlier Media v1 build; not yet re-verified against
Media2 specifically).

```dart
SpeakerVolumeClient(CameraConnection connection, {http.Client? httpClient, Uri? endpoint})
```

`endpoint` seeds the resolved Media2 service endpoint — see `OnvifVideoEncoderClient`'s doc above
for the same convention.

| Method | Params | Returns | Description |
|---|---|---|---|
| `getSpeakerVolume` | `{Duration timeout}` | `CameraResult<SpeakerVolume>` | Current output level (0-100) plus the token/name/outputToken fields ONVIF requires echoing back on set. Returns `CameraFailure` if the camera reports no `AudioOutputConfiguration` at all (no speaker) — UI should have already gated on `AudioCapabilityClient.hasSpeaker` before calling. |
| `setSpeakerVolume` | `SpeakerVolume current, {Duration timeout}` | `CameraResult<void>` | Applies a new volume — pass a `SpeakerVolume` built via `.withLevel(newLevel)` on a previously-loaded value, since ONVIF requires the sibling fields resent. |
| `resolveMedia2Endpoint` | `{Duration timeout}` | `CameraResult<Uri>` | Resolves (and remembers for this instance's life) the Media2 endpoint via `GetServices`. |
| `resolvedEndpoint` (getter) | — | `Uri?` | The endpoint this instance has resolved so far, or `null`. |
| `close` | — | `void` | Closes the HTTP client and internal `OnvifDeviceClient`. |

### OnvifRecordingClient

`lan/onvif/onvif_recording_client.dart` — ONVIF Profile G Recording Control service
(`/onvif/recording`, `FR-OV-080`), read/discovery-only on this firmware (`CreateRecording`/
`SetRecordingConfiguration`/etc. all return `ActionNotSupported`, see `onvif_recording.c`).
**Client-only, not wired into any screen** — a new, parallel path alongside the existing
REST-based `RecordingsClient`, per direct user instruction to leave the REST client as-is until
Profile G "becomes strong." `RecordingInfo.recordingToken` is the same UTC epoch-start decimal
identity `RecordingsClient`'s `"id"` field already uses — the two are interchangeable strings
for the same physical clip.

```dart
OnvifRecordingClient(CameraConnection connection, {http.Client? httpClient})
```

| Method | Params | Returns | Description |
|---|---|---|---|
| `getRecordings` | `{Duration timeout}` | `CameraResult<List<RecordingInfo>>` | Every stored clip currently reported. Takes no request parameters — the real `GetRecordings` SOAP action doesn't accept a time filter (that's the Search service's job, see `OnvifSearchClient`). |
| `getRecordingOptions` | `{Duration timeout}` | `CameraResult<RecordingOptions>` | Spare job/track capacity — always `0` on this device (not ONVIF-writable). |
| `getServiceCapabilities` | `{Duration timeout}` | `CameraResult<RecordingServiceCapabilities>` | `DynamicRecordings`/`DynamicTracks`/`Options`/`MaxRecordings`/`MaxRecordingJobs`. |
| `close` | — | `void` | Closes the underlying HTTP client. |

### OnvifSearchClient

`lan/onvif/onvif_search_client.dart` — ONVIF Profile G Search service (`/onvif/search`,
`FR-OV-081`). **Client-only, not wired into any screen** — same scope note as
`OnvifRecordingClient`. Speaks the real two-call async-job protocol (`FindRecordings`/
`FindEvents` → `SearchToken`, then `GetRecordingSearchResults`/`GetEventSearchResults` pages
results out) even though the firmware's job always completes synchronously underneath —
`RecordingSearchResults.searchState`/`EventSearchResults.searchState` are always `"Completed"`
on this device.

```dart
OnvifSearchClient(CameraConnection connection, {http.Client? httpClient})
```

| Method | Params | Returns | Description |
|---|---|---|---|
| `getServiceCapabilities` | `{Duration timeout}` | `CameraResult<SearchServiceCapabilities>` | `MetadataSearch` (camera-state-derived) plus `GeneralStartEvents`/`NLSearch`/`ImageSearch` (always `false` firmware-side). |
| `findRecordings` | `{DateTime? startTime, DateTime? endTime, Duration timeout}` | `CameraResult<String>` | Starts a recording search over an optional time range. Returns the `SearchToken`. Does not send `Scope`/`MaxMatches`/`KeepAliveTime` — the firmware ignores all three. |
| `getRecordingSearchResults` | `String searchToken, {int maxResults = 32, Duration timeout}` | `CameraResult<RecordingSearchResults>` | Pages matched clips out by token. |
| `findEvents` | `{DateTime? startTime, DateTime? endTime, Duration timeout}` | `CameraResult<String>` | Starts an event search. Returns the `SearchToken`. Same omitted-params caveat as `findRecordings`. |
| `getEventSearchResults` | `String searchToken, {int maxResults = 32, Duration timeout}` | `CameraResult<EventSearchResults>` | Pages matched `EventMgr` events out by token. `EventSearchItem.recordingToken` is always empty (not correlated firmware-side) and `.source` is the raw numeric event ID as text, not a label. |
| `getRecordingSummary` | `{Duration timeout}` | `CameraResult<RecordingSummary>` | Earliest/latest recording time and total clip count, computed fresh from the same clip index `getRecordings` reads — no search token needed. |
| `getSearchState` | `String searchToken, {Duration timeout}` | `CameraResult<String>` | Always `"Completed"` on this device. |
| `endSearch` | `String searchToken, {Duration timeout}` | `CameraResult<DateTime>` | Frees the search job slot (fixed pool of 2 on this device — an un-ended job leaks a slot). Returns the firmware's own current time, not the search's actual end point. |
| `close` | — | `void` | Closes the underlying HTTP client. |

### OnvifReplayControlClient

`lan/onvif/onvif_replaycontrol_client.dart` — ONVIF Profile G Replay Control service
(`/onvif/replay`, `FR-OV-082`), URI resolution only. **Correction (2026-09-07): the line
previously here said "client-only, not wired into any screen" — that was wrong.**
`recording_timeline_screen.dart` calls `getReplayUri` directly (`_replayControl.getReplayUri
(clip.id.toString())`) to resolve a clip's RTSP(S) playback URI, then hands the parsed host/
port/path to `RtspRemuxProxy` (`mobile_app/lib/features/recordings/rtsp/rtsp_remux_proxy.dart`)
— a real RTSP/1.0 client + fMP4 remuxer + local HTTP loopback proxy, **not** part of this
package, built specifically because `video_player`/ExoPlayer/AVPlayer have no RTSP support at
all (see that file's own doc comment, and `rtsp_replay_client.dart`'s, for the full story
including why `media_kit`/libmpv was tried and abandoned — `BUG-021`). This client itself
(`getReplayUri`) only returns the URI as plain data — it doesn't open an RTSP connection or play
back video itself, that's `RtspRemuxProxy`'s job, deliberately kept out of this package per its
own "clean, network-client-only" design principle (playback/remux logic is presentation logic,
not a network client). No seek/time-offset parameter exists on this SOAP call itself — seeking
is a `Range: clock=<start>-<end>` header on the RTSP `PLAY` request against the returned URI,
handled entirely by `RtspRemuxProxy`/`rtsp_replay_client.dart`, not this client. See
`design/Camera-ONVIF-API.md` § 1.7/§ 4.1 for the full protocol reference (method-by-method
behavior, real use cases, and the confirmed absence of a `PAUSE` method) this was built against.

```dart
OnvifReplayControlClient(CameraConnection connection, {http.Client? httpClient})
```

| Method | Params | Returns | Description |
|---|---|---|---|
| `getServiceCapabilities` | `{Duration timeout}` | `CameraResult<ReplayServiceCapabilities>` | `ReversePlayback`/`RTP_RTSP_TCP` plus `sessionTimeoutSeconds` — reported as a single plain-integer-seconds value on this device, not the WSDL's `tt:FloatRange` min/max pair. |
| `getReplayUri` | `String recordingToken, {Duration timeout}` | `CameraResult<String>` | Resolves a `RecordingToken` (same identity as `OnvifRecordingClient`/`OnvifSearchClient`) to a playable `rtsp://`/`rtsps://` URI on the camera's dedicated playback port. `CameraFailure` (SOAP fault, not a generic error) when the token doesn't resolve to an existing clip, **or** when a playback session is already active — this device rejects a second concurrent playback client rather than evicting the first (HTTP 409, `ter:OperationProhibited`/`ter:PlaybackBusy`; `onvif_replaycontrol.c`'s `GetReplayUri` handler). The `CameraFailure.reason` text for the busy case is `"A recorded-clip playback session is already in progress on this device. Try again once it ends."` (`onvif_fault.c`'s `OnvifFaultSubCodeEx_PlaybackBusy`, added 2026-09-24) — safe to show directly to the user, no client-side translation needed. |
| `close` | — | `void` | Closes the underlying HTTP client. |

---

## LAN — NuraEye REST

Every client in this section ultimately calls through `NuraeyeClient`, which speaks the camera's
`/nuraeye/*` REST API (bearer-session auth, per `FR-NE-104`/`FR-NE-105`).

### Hand-written clients

These are the classes most app code actually touches — each wraps `NuraeyeClient.call()` with a
typed method per action.

#### NuraeyeClient

`lan/nuraeye/nuraeye_client.dart` — the core dispatcher every other NuraEye-protocol client in
this package calls through. Translates a legacy `action` string + params into the matching REST
resource call internally.

```dart
NuraeyeClient(CameraConnection connection, {http.Client? httpClient})
```

| Method | Params | Returns | Description |
|---|---|---|---|
| `call` | `String action, {Map<String, dynamic>? params, Duration timeout}` | `CameraResult<Map<String, dynamic>>` | Dispatches one legacy NuraEye action (e.g. `"GetWiFiInfo"`, `"SetNightVisionType"`) to its REST equivalent. Returns the parsed `output` map. |
| `areYouNuraeyeDevice` | `{Duration timeout}` | `CameraResult<bool>` | `POST /nuraeye/identity` challenge-response device-genuineness check, using a fixed challenge password (not the connection's real credentials) — locally recomputes and compares the expected reply digest. Unauthenticated; the cheapest round trip in this API. Single-shot — used as-is by `LiveStreamUriClient.checkReachable()`, which deliberately wants a fast, non-retrying probe. |
| `areYouNuraeyeDeviceWithRetry` | `{int attempts = 3, Duration attemptTimeout = 8s, Duration retryDelay = 1s}` | `CameraResult<bool>` | Retrying variant for first-contact discovery/onboarding only (`DiscoveryScreen`'s candidate filter, `AddCameraCredentialsScreen`'s manual-entry check) — added 2026-08-15 after a real-device report and a live Python check confirmed a genuine camera can lose to `areYouNuraeyeDevice`'s single 5s attempt on a phone's *first* HTTPS request over a given WiFi connection (cold TLS handshake/radio wake-up), despite answering in ~0.4s once the connection is warm. Stops retrying as soon as one attempt succeeds; returns the last result once every attempt is exhausted. |
| `close` | — | `void` | Closes the HTTP client. |
| `debugClearCaches` (static) | — | `void` | Test-only: clears session/in-flight-login caches (no longer clears a `GetCapabilities` cache — that cache moved out of this class 2026-08-28). |
| `clearSessionFor` (static) | `String host` | `void` | Drops the cached bearer session for `host` — call after a password change or when a camera is removed from the app, so a stale session can't mask a wrong re-entered password on a re-add. |

**Notable behavior:**
- **Bearer sessions are cached per camera host for the life of the app process** (not per
  `NuraeyeClient` instance — most call sites construct a short-lived instance per call).
  Proactively checked for expiry before use and refreshed on activity (mirrors the firmware's
  idle-based session timeout), with a one-time re-login retry on a `401` as a backstop.
- **Concurrent logins for the same host are serialized** — the firmware only holds 6 concurrent
  sessions total (LRU-evicted), so multiple simultaneous fresh `NuraeyeClient`s for one camera
  share a single in-flight login instead of each triggering their own.
- `GetCapabilities` itself is **not** cached in this class any more (moved to the app layer
  2026-08-28, see `CapabilitiesClient`'s doc below) — only the bearer session is.
- Failure strings are prefixed `HTTP <code>: <reason>` when a status code is known — some app
  code depends on finding the numeric code as text (e.g. detecting a `401` to show "incorrect
  password").

`call`'s recognized `action` strings (each maps to a REST resource internally): `GetWiFiInfo`,
`SetupWiFi`, `GetWiFiSignalStrength`, `GetSupportedTimezones`, `GetCloudStreamingStatus`,
`StopCloudStreaming`, `GetPrivacyMode`, `SetPrivacyMode`, `GetMicGain`, `SetMicGain`,
`GetAudioRecording`, `SetAudioRecording`, `PlayTestSound`, `StopTestSound`,
`GetTestSoundStatus`, `GetCapabilities`, `GetNightVisionType`, `SetNightVisionType`,
`GetMirrorFlip`, `SetMirrorFlip`, `GetLiveStreamUri`, `GetImageDefaults`, `GetVideoMode`,
`GetPreviewKey`, `GetLocalStorage`, `SetLocalStorage`, `GetDeviceHealth`. Prefer the typed wrapper clients below over calling `call()` directly where
one exists.

#### AudioVolumeClient

`lan/nuraeye/audio_volume_client.dart` — microphone input gain, microphone recording on/off, and
speaker test-tone playback.

```dart
AudioVolumeClient(CameraConnection connection, {http.Client? httpClient})
```

| Method | Params | Returns | Description |
|---|---|---|---|
| `getMicGain` | `{Duration timeout}` | `CameraResult<int>` | Current mic input gain. |
| `setMicGain` | `int gain, {Duration timeout}` | `CameraResult<void>` | Sets mic input gain. |
| `isAudioRecordingEnabled` | `{Duration timeout}` | `CameraResult<bool>` | Whether the mic is actively capturing at all (distinct from gain level). |
| `setAudioRecordingEnabled` | `bool enabled, {Duration timeout}` | `CameraResult<void>` | Toggles mic recording. |
| `playTestSound` | `{Duration timeout}` | `CameraResult<void>` | Plays a short prerecorded test tone through the speaker. |
| `stopTestSound` | `{Duration timeout}` | `CameraResult<void>` | Stops test-tone playback. |
| `isTestSoundPlaying` | `{Duration timeout}` | `CameraResult<bool>` | Whether the test tone is still playing. |
| `close` | — | `void` | Closes the internal `NuraeyeClient`. |

Speaker *output* volume is a separate ONVIF action — see `SpeakerVolumeClient` above.

#### CapabilitiesClient

`lan/nuraeye/capabilities_client.dart` — camera capability discovery, queried at onboarding and
cached by the app layer (`mobile_app/lib/features/settings/camera_settings_cache.dart`'s
`NetworkAnswerCache` — see `.claude/rules/mobile-app-screen-conventions.md`'s "Caching
capability/service-discovery responses" section; this class itself carries no caching of its
own).

```dart
CapabilitiesClient(NuraeyeClient nuraeye)
```

| Method | Params | Returns | Description |
|---|---|---|---|
| `getCapabilities` | `{Duration timeout}` | `CameraResult<CameraCapabilities>` | `wanCommandCapable` (AWS IoT/MQTT support), `wanLiveViewCapable` (additionally requires KVS build support — both also require this specific device to have real AWS credentials provisioned, not just build-time support), `supportedEventTypes` (`FR-CF-143`/`FR-NE-111` — the alert event strings this build actually generates; empty on firmware too old to report it), `supportedEventDeterrenceOptions` (`FR-CF-144`/`FR-NE-112` — per detection event type, which response actions are eligible for it; only detection-type events appear as keys, empty map on firmware too old to report it), and `sirenCapable`/`spotlightCapable`/`warningCapable` (`FEAT-236`, 2026-08-14 — same hardware-presence flags `GetDeterrenceCapabilities` reports on its own dedicated endpoint, mirrored here so `DeterrenceClient`-consuming UI can reuse this already-fetched response instead of a second round trip; `false` on firmware too old to report them), `localStorageCapable` (`FR-CF-044`, added
2026-08-21 — whether this SKU has an SD card slot at all; `false` on firmware too old to report
it), `recordingClipDurationMinSeconds`/`MaxSeconds` (`FR-NE-119`, added 2026-08-23 — the
valid range for `RecordingsClient.setClipDuration`; `0`/`0` on firmware too old to report them
or with no local-storage capability at all), `loiteringDurationMinSeconds`/`MaxSeconds`
(`FR-CF-150`, added 2026-08-26 — fixed compile-time bounds for
`LoiteringDurationClient.setLoiteringDuration`; `0`/`0` on firmware too old to report them), and
`bboxOverlayCapable` (`FR-CF-151`, added 2026-08-26 — whether this build supports the
bounding-box overlay toggle at all, `false` on a build without `AI_DETECTIONS`; gate
`BboxOverlayClient`-driven UI on this). **Always a live network call as of 2026-08-28** — no
`forceRefresh` param any more, since there's nothing left in this package to bypass; the app-level
`NetworkAnswerCache` is what a caller should check first for a normal load, and simply not check
(call this directly) for an explicit re-probe — see `storage_settings_screen.dart`'s
`_maybeReprobeLocalStorage` for the reference re-probe pattern. |

#### EventPreferencesClient

`lan/nuraeye/event_preferences_client.dart` — `GetEventPreferences`/`SetEventPreferences`
(`FR-CF-143`, `FR-NE-111`) — see `WanEventPreferencesClient` for the WAN mirror.

```dart
EventPreferencesClient(NuraeyeClient nuraeye)
```

| Method | Params | Returns | Description |
|---|---|---|---|
| `getEventPreferences` | `{Duration timeout}` | `CameraResult<Map<String, bool>>` | Current enabled/disabled state, keyed by the same strings `CapabilitiesClient`'s `supportedEventTypes` reports. |
| `setEventPreferences` | `Map<String, bool> changes, {Duration timeout}` | `CameraResult<void>` | Partial update — only the keys present in `changes` change; every other type's state is left untouched. An unrecognized key is a `CameraFailure` (camera returns `HTTP 400`, whole request rejected, no partial application). |

**Disabling a type is a real, device-side change** — the camera suppresses it at the source
(`EventMgr_Send()`), on every delivery path it has, including ONVIF PullPoint — not a
client-side filter, not scoped to this app's own feed.

#### EventResponseActionsClient

`lan/nuraeye/event_response_actions_client.dart` — `GetEventResponseActions`/
`SetEventResponseActions` (`FR-CF-144`, `FR-NE-112`) — see `WanEventResponseActionsClient` for
the WAN mirror.

```dart
EventResponseActionsClient(NuraeyeClient nuraeye)
```

| Method | Params | Returns | Description |
|---|---|---|---|
| `getEventResponseActions` | `{Duration timeout}` | `CameraResult<Map<String, List<String>>>` | Current selected response actions per detection event type, keyed by the same strings `CapabilitiesClient`'s `supportedEventDeterrenceOptions` reports. |
| `setEventResponseActions` | `Map<String, List<String>> changes, {Duration timeout}` | `CameraResult<void>` | Partial update — only the event types present in `changes` change; each key's array fully **replaces** that event type's selected action set (not additive). An unrecognized event type key, or an action not eligible for that type, is a `CameraFailure` (camera returns `HTTP 400`, whole request rejected, no partial application). |

**Not to be confused with `EventPreferencesClient`** — that controls whether an event type is
generated at all; this controls what happens *in addition* when an already-enabled detection
event fires. `siren`/`spotlight`/`warning` are real physical device actions the camera
auto-triggers; `mobile_alert` has no device-side effect at all — this app reads it locally to
decide whether to show a push notification, never as a device-side gate.

#### LoiteringDurationClient

`lan/nuraeye/loitering_duration_client.dart` — `GetLoiteringDuration`/`SetLoiteringDuration`
(`FR-CF-150`, `FR-NE-121`) — see `WanLoiteringDurationClient` for the WAN mirror.

```dart
LoiteringDurationClient(NuraeyeClient nuraeye)
```

| Method | Params | Returns | Description |
|---|---|---|---|
| `getLoiteringDuration` | `{Duration timeout}` | `CameraResult<int>` | Current configured dwell threshold, in whole seconds — how long a tracked object must stay present before the camera fires a `Loitering` event. |
| `setLoiteringDuration` | `int seconds, {Duration timeout}` | `CameraResult<void>` | A value outside `CapabilitiesClient`'s `loiteringDurationMinSeconds`/`MaxSeconds` is a `CameraFailure` (camera returns `HTTP 400`). |

**Independent of `EventPreferencesClient`'s `PersonDetected` toggle** — Loitering has its own
enable/disable entry in `supportedEventTypes`/`EventPreferencesClient` (wire name `"Loitering"`).
Firmware runs its NN pipeline whenever *either* `PersonDetected` or `Loitering` is enabled (fixed
2026-08-26 — previously `PersonDetected` alone gated the pipeline, so disabling it while leaving
`Loitering` on silently broke loitering detection too).

#### BboxOverlayClient

`lan/nuraeye/bbox_overlay_client.dart` — `GetBboxOverlayEnabled`/`SetBboxOverlayEnabled`
(`FR-CF-151`, `FR-NE-123`) — see `WanBboxOverlayClient` for the WAN mirror.

```dart
BboxOverlayClient(NuraeyeClient nuraeye)
```

| Method | Params | Returns | Description |
|---|---|---|---|
| `isBboxOverlayEnabled` | `{Duration timeout}` | `CameraResult<bool>` | Whether the camera draws the AI detection bounding-box overlay (OSD burn-in) on the video stream. |
| `setBboxOverlayEnabled` | `bool enabled, {Duration timeout}` | `CameraResult<void>` | Toggles the overlay. |

**Independent of detection/alerts themselves** — `PersonDetected`/`Loitering` keep firing and
carrying `bbox` in their event payload regardless of this toggle; it only controls whether a
box is visibly burned into the video everyone watches/records. Gate the toggle on
`CapabilitiesClient`'s `bboxOverlayCapable`, not a hardcoded assumption.

#### DeterrenceClient

`lan/nuraeye/deterrence_client.dart` — `ActivateDeterrence`/`DeactivateDeterrence`/
`GetDeterrenceStatus` (`FR-NE-082`/`083`) plus `GetDeterrenceDurations`/`SetDeterrenceDurations`
(`FR-NE-113`, `FEAT-236`) — see `WanDeterrenceClient` for the WAN mirror.

```dart
DeterrenceClient(NuraeyeClient nuraeye)
```

| Method | Params | Returns | Description |
|---|---|---|---|
| `getDeterrenceStatus` | `{Duration timeout}` | `CameraResult<DeterrenceStatus>` | Each deterrence action's own independent active/inactive state (`siren`/`spotlight`/`warning` fields, `activeActions` getter, `isActive(action)` helper) — siren/spotlight/warning are independent hardware outputs and can be active simultaneously (`FEAT-236`, 2026-08-14 fix; previously a single `{active, action}` pair could only ever report one action as "the" active one). |
| `activateDeterrence` | `String action, {Duration timeout}` | `CameraResult<void>` | `action` ∈ `siren`/`spotlight`/`warning`, gated on `CapabilitiesClient`'s `sirenCapable`/`spotlightCapable`/`warningCapable`. **No duration parameter** (removed `FEAT-236`, 2026-08-14) — the camera applies its own persisted duration from `getDeterrenceDurations`/`setDeterrenceDurations` instead, shared with the camera's own automatic detection-triggered response (`EventResponseActionsClient`). |
| `deactivateDeterrence` | `String action, {Duration timeout}` | `CameraResult<void>` | Stops immediately, regardless of how much of the configured duration remains. |
| `getDeterrenceDurations` | `{Duration timeout}` | `CameraResult<Map<String, int>>` | Current configured auto-stop value per action, keyed `siren_seconds`/`spotlight_seconds` (whole seconds) and `warning_repeat_count` (a repeat count, not seconds — see below). Only the keys `CapabilitiesClient` reports as capable are meaningful. |
| `setDeterrenceDurations` | `Map<String, int> changes, {Duration timeout}` | `CameraResult<void>` | Partial update — only the keys present in `changes` change. An unrecognized key, a value outside `getDeterrenceDurationOptions`' reported range for it, or an action this build isn't capable of is a `CameraFailure` (camera returns `HTTP 400`, whole request rejected). |
| `getDeterrenceDurationOptions` | `{Duration timeout}` | `CameraResult<DeterrenceDurationOptions>` | Camera-reported valid `min`/`max` per key — **build UI bounds from this, never hardcode a range** (real-hardware finding, 2026-08-15: an earlier version hardcoded 0-60s and let the UI set a degenerate `0`). |

**`warning`'s value is a repeat count, not seconds** (revised `FEAT-236`, 2026-08-15, after
real-hardware testing) — it repeats its prerecorded clip `warning_repeat_count` times before
stopping (or until an explicit `deactivateDeterrence`), rather than running for a duration. A
duration-based loop was tried first and found unreliable on real hardware (a fixed-period guess
timer cut the clip off partway through and restarted it) — the current implementation is
completion-driven internally (`bsp_camera_ameba.c`'s `prvWarningPollTimerCallback()`), so the
app only needs to know "how many times," not "how long."

#### CloudStreamingLanClient

`lan/nuraeye/cloud_streaming_client.dart` — LAN counterparts to two of `WanLiveViewClient`'s
three commands. No LAN `startCloudStreaming` — starting cloud streaming only makes sense for a
WAN-bound client.

```dart
CloudStreamingLanClient(NuraeyeClient nuraeye)
```

| Method | Params | Returns | Description |
|---|---|---|---|
| `getCloudStreamingStatus` | `{Duration timeout}` | `CameraResult<StreamStatus>` | `active`/`idle`/`degraded`/`notCompiled`. A failed/timed-out LAN call here means "not reachable on this network," not "camera offline." |
| `stopCloudStreaming` | `{Duration timeout}` | `CameraResult<void>` | Stops the KVS push — used opportunistically once LAN reachability is confirmed, to avoid an unnecessary AWS/Lambda round trip. |

#### MirrorFlipClient

`lan/nuraeye/mirror_flip_client.dart` — LAN transport for mirror/flip mode.

```dart
MirrorFlipClient(NuraeyeClient nuraeye)
```

| Method | Params | Returns | Description |
|---|---|---|---|
| `getMirrorFlip` | `{Duration timeout}` | `CameraResult<MirrorFlipMode>` | Current mode. |
| `setMirrorFlip` | `MirrorFlipMode mode, {Duration timeout}` | `CameraResult<void>` | Sets mode. |

See `wan/wan_mirror_flip_client.dart`'s `WanMirrorFlipClient` for the WAN counterpart (same
`MirrorFlipMode` enum).

#### AntiFlickerClient

`lan/nuraeye/anti_flicker_client.dart` — LAN transport for power-line frequency / anti-flicker
mode. No ONVIF-standard element exists for this setting (checked against the live
`ImagingSettings20` schema — see `kb/raw/2026-08-12-feature-antiflicker-mode.md`), same
situation as `MirrorFlipClient` above.

```dart
AntiFlickerClient(NuraeyeClient nuraeye)
```

| Method | Params | Returns | Description |
|---|---|---|---|
| `getAntiFlickerMode` | `{Duration timeout}` | `CameraResult<AntiFlickerMode>` | Current mode (`hz50`/`hz60`/`auto`). |
| `setAntiFlickerMode` | `AntiFlickerMode mode, {Duration timeout}` | `CameraResult<void>` | Sets mode. |

See `wan/wan_anti_flicker_client.dart`'s `WanAntiFlickerClient` for the WAN counterpart (same
`AntiFlickerMode` enum).

#### NetworkInfoClient

`lan/nuraeye/network_info_client.dart` — WiFi info/setup/signal and the curated time-zone
catalog; no ONVIF equivalent.

```dart
NetworkInfoClient(CameraConnection connection, {http.Client? httpClient})
```

| Method | Params | Returns | Description |
|---|---|---|---|
| `getWifiSsid` | `{Duration timeout}` | `CameraResult<String>` | Configured WiFi SSID (the WiFi password is deliberately discarded, never surfaced). Only meaningful when the active interface is wireless. |
| `setupWifi` | `{required String ssid, required String psk, bool verify = true, Duration timeout}` | `CameraResult<void>` | Sends new WiFi credentials. `verify: true` (default) saves and attempts a connection; the firmware always forces save-only when currently reached over Ethernet, regardless of this flag. |
| `getWifiSignalStrength` | `{Duration timeout}` | `CameraResult<({int rssi, int snr})>` | Current WiFi signal strength. Only meaningful when wireless. |
| `getSupportedTimezones` | `{Duration timeout}` | `CameraResult<List<TimezoneOption>>` | Camera-served curated time-zone list. Always a live network call — no caching in this package (moved to the app layer 2026-08-28, see `mobile_app/lib/features/settings/camera_settings_cache.dart`'s `NetworkAnswerCache`). Older firmware without this action returns `CameraFailure` — fall back to a hardcoded list rather than an empty picker. |
| `close` | — | `void` | Closes the internal `NuraeyeClient`. |

`TimezoneOption.code` is the POSIX-style string to pass to `OnvifDeviceClient.setTimeZone` — the
*setting* of time zone stays an ONVIF action; only the catalog to pick from is NuraEye.

#### NightVisionClient

`lan/nuraeye/night_vision_client.dart` — LAN transport for night-vision type, implementing the
shared `NightVisionSource` interface.

```dart
class NightVisionClient implements NightVisionSource {
  NightVisionClient(NuraeyeClient nuraeye)
}
```

| Method | Params | Returns | Description |
|---|---|---|---|
| `getNightVisionType` | `{Duration timeout}` | `CameraResult<NightVisionStatus>` | Current type (`grey`/`color`/`smart`), capability flags, and (for `smart`) live sub-state. |
| `setNightVisionType` | `NightVisionType type, {Duration timeout}` | `CameraResult<void>` | Sets night-vision type. |

See `wan/wan_night_vision_client.dart`'s `WanNightVisionClient` for the WAN counterpart —
identical interface, so UI code can hold either behind a single `NightVisionSource` reference.

#### PrivacyModeClient

`lan/nuraeye/privacy_mode_client.dart` — LAN transport for privacy mode.

```dart
PrivacyModeClient(NuraeyeClient nuraeye)
```

| Method | Params | Returns | Description |
|---|---|---|---|
| `getPrivacyMode` | `{Duration timeout}` | `CameraResult<PrivacyMode>` | Current mode (`none`/`zone`/`full`). |
| `setPrivacyMode` | `PrivacyMode mode, {Duration timeout}` | `CameraResult<void>` | Sets mode. `full` stops all capture; `zone` uses whatever mask zones are already configured. |

See `wan/wan_privacy_mode_client.dart`'s `WanPrivacyModeClient` for the WAN counterpart.

#### LocalStorageClient

`lan/nuraeye/local_storage_client.dart` — LAN transport for local (SD card) storage
(`FR-CF-044`/`FR-NE-087`/`FR-MOB-083`).

```dart
LocalStorageClient(NuraeyeClient nuraeye)
```

| Method | Params | Returns | Description |
|---|---|---|---|
| `getStatus` | `{Duration timeout}` | `CameraResult<LocalStorageStatus>` | Live status: `enabled`, `cardPresent`, `capacityBytes`, `freeBytes`. Always live — never cached. |
| `setEnabled` | `bool enabled, {Duration timeout}` | `CameraResult<void>` | Turns recording on/off. **The camera rejects `enabled: true` with no SD card present** (`500`) — check `LocalStorageStatus.cardPresent` before calling with `true` rather than relying on the rejection alone. |

See `wan/wan_local_storage_client.dart`'s `WanLocalStorageClient` for the WAN counterpart.

#### RecordingModeClient

`lan/nuraeye/recording_mode_client.dart` — LAN transport for local recording mode selection
(`FR-CF-046`/`FR-NE-088`/`FR-MOB-084`-`088`): Continuous / Scheduled / Event-Triggered.

```dart
RecordingModeClient(NuraeyeClient nuraeye)
```

| Method | Params | Returns | Description |
|---|---|---|---|
| `getMode` | `{Duration timeout}` | `CameraResult<RecordingModeStatus>` | Current mode, its schedule (empty unless `mode` is `scheduled`), and `eventTriggerSourceConfigured` (`FR-CF-047` — only meaningful for `eventTriggered`). |
| `setMode` | `RecordingMode mode, {List<RecordingScheduleWindow> schedule, Duration timeout}` | `CameraResult<void>` | `schedule` is sent only when `mode` is `scheduled`. **The camera rejects a `mode` not in this SKU's `supportedRecordingModes`, or an invalid schedule** (`500`) — check `CameraCapabilities.supportedRecordingModes` before calling rather than relying on the rejection alone. |

See `wan/wan_recording_mode_client.dart`'s `WanRecordingModeClient` for the WAN counterpart.

#### HealthClient

`lan/nuraeye/health_client.dart` — LAN transport for camera health/vitals (`FR-HLT-009`, Stage 3
first slice — `design/stages/03-camera-health-diagnostics/DESIGN.md`). Read-only, no matching Set
— both fields are camera-derived, not user-configurable.

```dart
HealthClient(NuraeyeClient nuraeye)
```

| Method | Params | Returns | Description |
|---|---|---|---|
| `getHealth` | `{Duration timeout}` | `CameraResult<HealthStatus>` | `rebootCount`, `lastRebootUtc` (UTC epoch seconds; `0` = not yet corrected this boot), `rebootReason` (why the current boot happened, e.g. `"Firmware Upgrade"`/`"Factory Reset"`/`"HTTP Server Failure"`/`"Unknown / Crash"` — `BUG-048`, free text not a closed enum, empty on older firmware), `uptimeSeconds`, `clockSyncState` (`ClockSyncState.synced`/`.uncertain`), `uncertainSince` (UTC epoch seconds; `0` if synced), `firmwareVersion` (duplicates `OnvifDeviceClient.getDeviceInformation()`'s value). A reboot-loop flag and AI-model version are `FR-HLT-009`'s remaining, unimplemented scope; last-recording-segment timestamp isn't implemented either. |

See `wan/wan_health_client.dart`'s `WanHealthClient` for the WAN counterpart.

#### RecordingsClient

`lan/nuraeye/recordings_client.dart` — recorded clip list + playback/download + delete
(`FR-NE-117`/`FR-NE-118`/`FR-NE-120`, `FR-MOB-107`/`108`/`109`/`110`, `FEAT-039`). LAN only — no WAN counterpart
exists yet. Reworked from an originally ONVIF Recording Service/Profile G-based design (see
`design/stages/04-recording-playback/DESIGN.md` NF2) after finding ONVIF Search's async
job-polling browse model a poor fit for a phone client.

```dart
RecordingsClient(NuraeyeClient nuraeye)
```

| Method | Params | Returns | Description |
|---|---|---|---|
| `getRecordings` | `{int? start, int? end, Duration timeout}` | `CameraResult<RecordingsList>` | Lists clips, optionally scoped to a UTC-epoch-seconds time range. `RecordingsList.storageAvailable`/`cardPresent` distinguish capability/presence from a genuinely empty range — mirrors `LocalStorageStatus`'s own split. **Single page only** — see `RecordingsList.truncated`'s doc; prefer `getAllRecordings` unless you specifically want just the oldest-first first page. |
| `getAllRecordings` | `{int? start, int? end, int maxPages = 20, Duration timeout}` | `CameraResult<RecordingsList>` | Pages through `getRecordings` automatically (`start = <last clip's start> + 1` each time `truncated` comes back `true`) until a page is clean or `maxPages` is hit. Added 2026-09-24 after a real bug: `RecordingsScreen`/`RecordingTimelineScreen` both called the single-page `getRecordings` directly and never checked `truncated`, so a camera with enough history silently hid every newer clip (including fresh scheduled-mode recordings) behind however many old ones filled the first response's JSON buffer (~70-80 in practice). Use this for any screen that needs a *complete* list; `getRecordings` remains correct for a narrow probe (e.g. "does anything exist in this exact range") or for finding the *oldest* clip specifically (`RecordingModeSettingsScreen`'s backlog estimate — truncation only ever cuts the newer tail, since the camera returns oldest-first). |
| `getClipDuration` | `{Duration timeout}` | `CameraResult<int>` | Currently-configured recorded-clip duration, in seconds (`FR-NE-119`). |
| `setClipDuration` | `int seconds, {Duration timeout}` | `CameraResult<void>` | Applies for the *next* clip rotation only — the segment currently being written keeps its original length. Rejected (`400`) outside `CameraCapabilities.recordingClipDurationMinSeconds`/`MaxSeconds` — check those bounds before calling. |
| `clipUri` | `int clipId` | `Uri` | The `GET /nuraeye/recordings/{id}/clip` URI for a clip (its `RecordingClip.id`). Supports HTTP `Range` requests for seeking — pass straight to `VideoPlayerController.networkUrl`. |
| `clipHeaders` | `{Duration timeout}` | `CameraResult<Map<String, String>>` | The `Authorization` header to attach to a raw request against `clipUri` — same bearer-session token every other call uses (`NuraeyeClient.authHeadersFor`), obtained without a separate login round trip. Needed because [clipUri]'s response is binary, not something `NuraeyeClient.call`'s JSON path can serve. |
| `deleteRecordings` | `{List<int>? ids, bool deleteAll = false, Duration timeout}` | `CameraResult<int>` | Deletes the given `ids`, or every clip if `deleteAll: true` (pass exactly one of the two) — one bulk primitive for both a multi-select delete and a "delete all" action (`FR-NE-120`). Never deletes the currently-recording segment, even if its id is included or `deleteAll` is set — the camera silently skips it. Returns the number of clips actually deleted. |
| `downloadClip` | `int clipId, {Duration timeout}` | `CameraResult<Uint8List>` | Downloads the full clip into memory via `createCameraHttpClient()`'s cert-trust bypass — needed because `video_player`'s native platform player has no way to trust this camera's self-signed HTTPS cert for `VideoPlayerController.networkUrl` (`BUG-004`). Caller (`ClipPlaybackScreen`) writes the bytes to a temp file and plays via `VideoPlayerController.file` instead; this method has no file/caching concept of its own (pure-Dart, no `path_provider`). Reuses one `http.Client` across calls on the same instance, not a fresh one per call — avoids repeatedly re-paying this camera's self-signed-cert TLS handshake when browsing between clips. |
| `closeDownloadClient` | — | `void` | Closes the `http.Client` `downloadClip` reuses, if one was ever created. Call from the owning screen's `dispose()` (`ClipPlaybackScreen` does). Safe to call even if `downloadClip` was never called. |

`RecordingClip` (`id`, `start`, `end`, `sizeBytes`, `active`, `trigger`) and `RecordingsList`
(`storageAvailable`, `cardPresent`, `truncated`, `clips`) are defined in `src/recordings_types.dart`
— see "Shared types" below.

#### SnapshotClient

`lan/nuraeye/snapshot_client.dart` — `GET /snapshot` still-image capture. Notably built directly
on `dart:io`'s `HttpClient` rather than `package:http` (needed to preserve HTTP header case for
its `Authorization` header, since this is the one endpoint in the package that carries auth in a
header rather than a request body).

```dart
SnapshotClient(CameraConnection connection)
```

| Method | Params | Returns | Description |
|---|---|---|---|
| `getSnapshot` | `{Duration timeout, String profile = 'high'}` | `CameraResult<Uint8List>` | Captures a still JPEG. `profile` — see `CameraConnection.snapshotEndpoint`'s doc for the `"high"`/`"medium"`/`"low"` choice. |
| `close` | — | `void` | Closes the underlying `HttpClient`. |

#### LiveStreamUriClient

`lan/nuraeye/live_stream_uri_client.dart` — the mobile app's only LAN live-view discovery
mechanism. **2026-09-07: replaces `WebRtcUriClient`/`getWebRtcUri`**, merging what were two
separate camera endpoints (`POST /nuraeye/webrtc-uri`, `GET /nuraeye/rtsp-uri`) into one
`POST /nuraeye/live-stream-uri` — the camera picks the transport server-side (WebRTC when
`WEBRTC_STREAMING` is built in, RTSP(S) otherwise) and reports which one via
`LiveStreamTarget.transport`, so this client (and its caller, `LiveViewController`) no longer
need to know in advance which of two endpoints would work. **RTSP is no longer VMS/NVR-only
reserved territory** — supersedes the earlier "RTSP is reserved for VMS/NVR, not exposed by this
package" conclusion (`kb/raw/2026-07-29-design-mobile-app-lan-webrtc-not-rtsp-correction.md`),
itself superseded once the camera's `WEBRTC_STREAMING` was disabled camera-side. No WAN
counterpart exists for either transport — both are LAN-only by design. **2026-09-11**: the
old-firmware compatibility fallback this client briefly kept (retrying via the pre-merge
`GetWebRtcUri`/`POST /nuraeye/webrtc-uri` on a 404) was removed — all cameras are being upgraded
to firmware that serves this endpoint directly.

```dart
LiveStreamUriClient(NuraeyeClient nuraeye)
```

**Profile-token constants** (same file) — pass one of these to `getLiveStreamUri`, never a bare
string literal: `kMainStreamProfileToken` (`'Profile_1'`, the main/"high" ONVIF-facing stream),
`kSubStreamProfileToken` (`'Profile_2'`, the sub/"medium" ONVIF-facing stream),
`kMobileOnlyStreamProfileToken` (`'Profile_3'`, the dedicated mobile-only stream, `FR-CF-153`, no
ONVIF profile behind it). Added 2026-09-08 after a real bug: `LiveViewScreen`'s live-view default
was a bare `'Profile_1'` literal, so the mobile app's own live view was requesting the NVR/VMS
main stream instead of the stream built for it — a named constant makes the choice visible at
every call site instead of relying on remembering which literal string means what. **This app's
live view always passes `kMobileOnlyStreamProfileToken` and must never pass either of the other
two** — see `STREAMING_GUIDE.md` §2.1 for the full rationale and history.

| Method | Params | Returns | Description |
|---|---|---|---|
| `getLiveStreamUri` | `String profileToken, {Duration timeout}` | `CameraResult<LiveStreamTarget>` | Resolves the live-view connection target for one video profile (`Profile_1`/`Profile_2`/`Profile_3` — `Profile_3` is a NuraEye-only token, `FR-CF-153`'s mobile-only stream, not an ONVIF profile). `LiveStreamTarget.transport` (`LiveStreamTransport.webrtc`/`.rtsp`) tells the caller which player to drive — `.mediaUri` is a WebRTC signaling `POST` target (`http://`, unauthenticated/unencrypted by firmware design) for the former, an RTSP(S) stream URL (`rtsps://`, RTSP-level Digest auth applies) for the latter. |
| `checkReachable` | `{Duration timeout = 3s}` | `Future<bool>` (not `CameraResult`) | Independent LAN reachability probe via `areYouNuraeyeDevice` — used to distinguish "camera not on this network" from "camera on this network but `getLiveStreamUri` itself is failing." |
| `close` | — | `void` | Closes the internal `NuraeyeClient`. |

**Mobile-app-side consumers** (`mobile_app/lib/features/live_view/`, not part of this package —
see that folder's own doc comments for the full picture):
- `LiveViewController` (`live_view_controller.dart`) resolves the target via this client and
  emits `LiveViewActive(transport: Transport.lan, mediaUri:, lanMediaKind:)` — it does not itself
  open a connection.
- `LiveViewScreen` drives the actual session based on `lanMediaKind`: `WebRtcLiveViewSession`
  (`flutter_webrtc`) for `.webrtc`, or `rtsp/rtsp_live_view_proxy.dart`'s `RtspLiveViewProxy` for
  `.rtsp` — the latter remuxes the camera's RTSPS stream into fMP4 over a local HTTP loopback
  (adapted from the pre-existing recorded-clip playback machinery,
  `../recordings/rtsp/rtsp_replay_client.dart`/`rtsp_remux_proxy.dart` +
  `camera_api`'s own `media/fmp4_muxer.dart` — same protocol engine, live view instead of clip
  playback: no seek, no known duration), then reuses
  the exact same `VideoPlayerController`-based rendering/mute/snapshot-capture code the WAN (KVS
  HLS) path already had — both are, past that point, just "a `video_player` session fed by a
  local/remote URI."
- Two-way talk is **not** one of these consumers — it is a separate connection with its own
  discovery client (`TalkUriClient`, below), not a mode of the live-view stream.

#### TalkUriClient

`lan/nuraeye/talk_uri_client.dart` — the mobile app's only two-way-talk discovery mechanism
(added 2026-09-11, replacing the WebRTC `{"talk": true}` signaling flag and a never-completed
live-view-layered RTSP talk track — both removed). Two-way talk runs over the camera's dedicated
audio-only RTSPS talk module (`module_rtsps_talk.c`, port 560), a connection completely
independent of live view. LAN-only — no WAN counterpart (`FR-NE-081` is `Planned`).

```dart
TalkUriClient(NuraeyeClient nuraeye)
```

| Method | Params | Returns | Description |
|---|---|---|---|
| `getTalkUri` | `{Duration timeout}` | `CameraResult<TalkTarget>` | `POST /nuraeye/talk-uri` (body ignored). `TalkTarget { int port, Uri mediaUri }` — `mediaUri` is always `rtsps://<ip>:560/talk` (the module is TLS-only; the client validates `transport == "rtsps"`). A `400` ("Two-way talk unavailable on this build" — no `AUDIO_ENABLED`) or a bad transport surfaces as `CameraFailure`. |
| `close` | — | `void` | Closes the internal `NuraeyeClient`. |

**Shared type:** `TalkTarget` (`talk_uri_client.dart`) — `{ int port, Uri mediaUri }`.

**Mobile-app-side consumers** (`mobile_app/lib/features/live_view/`, not part of this package):
`RtspTalkSession` (`rtsp/rtsp_talk_session.dart`) opens the port-560 RTSPS `RECORD` session and
streams the phone mic (`package:record`, AAC-LC 8000 Hz) to it; `TalkDownlinkPlayer`
(`rtsp/talk_downlink_player.dart`) plays the camera's return audio; the talk control lives on
`LiveWatchScreen`. Wire protocol: [TWO_WAY_TALK_GUIDE.md](TWO_WAY_TALK_GUIDE.md).

### Generated REST clients

The `rest_*.dart` files (plus `nuraeye_rest_client.dart` and `rest_result.dart`) are
**machine-generated** by `tools/generate_dart_rest_client.py` from
`design/Camera-REST-API.openapi.yaml`, regenerated via the `/generate_dart_client` command —
**never hand-edit these files.** They mirror the OpenAPI spec's `/nuraeye/*` paths 1:1, one
group-client class per OpenAPI tag, each method returning `Future<RestResult<T>>` (the
REST-specific result type, distinct from `CameraResult`).

`NuraeyeRestClient` (`nuraeye_rest_client.dart`) is the shared low-level transport every
generated client (and `NuraeyeClient` itself) calls through — it owns the camera's host/port/
scheme/bearer-token and unwraps the `{error_code, error_msg, output}` response envelope into a
`RestResult<Map<String, dynamic>>`.

**These generated per-group clients are currently unused by `NuraeyeClient`** (which builds
directly on `NuraeyeRestClient` instead) — they exist as a ready-made typed surface for future
use or for a consumer that wants the REST API's native shape rather than the legacy
action/params shape `NuraeyeClient.call()` presents.

| Class | Covers |
|---|---|
| `RestIdentityDiscoveryClient` | `identityChallenge`, `sessionLogin`, `sessionLogout` — device identity and bearer-session lifecycle. |
| `RestCapabilitiesClient` | `getCapabilities` — every build/unit capability flag in one response. |
| `RestNetworkConnectivityClient` | WiFi get/set, WiFi signal, time zones, cloud parameters. |
| `RestAudioClient` | Audio recording, audio settings (mic gain + speaker volume), test-sound status. |
| `RestVideoImageClient` | Image defaults, mirror/flip, night-vision type, video mode. |
| `RestStreamingClient` | Cloud streaming status/stop, WebRTC URI resolution, shared preview-key fetch. |
| `RestPrivacyClient` | Privacy mode get/set. |
| `RestDeterrenceAlarmsClient` | Buzzer and deterrence-action status/control. |
| `RestStorageClient` | Local storage (SD card) status/enable. |
| `RestAlertsClient` | Per-rule alert configuration (mobile notifications, buzzer activation). |

Each generated file also defines its own plain-data response classes (e.g.
`GetCapabilitiesResponse`, `GetPrivacyModeResponse`) with a `fromJson` factory — these are
distinct types from the hand-written clients' own domain types (`CameraCapabilities`,
`PrivacyMode`, etc.) even where they cover the same data.

---

## LAN — Discovery

### WsDiscoveryClient

`lan/discovery/ws_discovery_client.dart` — pure-Dart WS-Discovery UDP client (multicast primary
+ unicast subnet-sweep fallback) for finding ONVIF/NuraEye devices on the LAN.

```dart
WsDiscoveryClient()
```

| Method | Params | Returns | Description |
|---|---|---|---|
| `scanMulticast` | `{Duration timeout = 5s}` | `Future<List<WsDiscoveryCandidate>>` | Sends a multicast Probe to `239.255.255.250:3702` and collects `ProbeMatch` replies for `timeout`. The primary discovery tier. |
| `scanUnicast` | `{Duration overallCap = 15s, Duration stragglerWait = 5s}` | `Future<List<WsDiscoveryCandidate>>` | Fallback: sweeps every host on each local IPv4 interface's assumed `/24` subnet with a unicast Probe. Only run when `scanMulticast` finds nothing. |

Each `WsDiscoveryCandidate` is a raw probe match — **not yet verified as a genuine NuraEye
device**; call `NuraeyeClient.areYouNuraeyeDevice()` separately per candidate to confirm.
`WsDiscoveryCandidate.deviceServiceUri` gives the ONVIF device-service URL to probe.

Documented limitation: the unicast sweep assumes a `/24` subnet per interface rather than
deriving the real prefix length (`dart:io` has no portable API for that) — correct for the
overwhelming majority of home/community LANs, this app's target deployment.

---

## WAN — AWS IoT / KVS

Every client in this section talks to the camera over AWS IoT Core. **Since 2026-08-18**,
`IotCommandClient` (commands: settings, deterrence, device identity, etc.) connects **directly**
to AWS IoT Core over MQTT-over-WSS — no Lambda relay involved. Video playback
(`KvsMediaViewerCredentialsClient` + `KvsMediaLiveViewSession`) still goes through the Lambda
relay (`cloud_backend/kvs_playback_lambda`) for its one credential-vending call — a separate,
**confirmed-real** Cognito-federation restriction on the KVS control-plane APIs specifically (see
`kb/wiki/kvs-viewer-read-permissions-cognito-role.md`), not the same restriction the command relay
was removed for. None of these clients import anything app-specific — they source their AWS
credentials/config through `WanAuth`'s static hooks instead.

### WanAuth

`wan/wan_auth.dart` — app-wide static hooks every WAN client falls back to when not given a
per-call override. **Set these exactly once, at app startup, before the first WAN call** (e.g.
in `main.dart`).

| Hook | Type | Purpose |
|---|---|---|
| `idTokenProvider` | `String? Function()?` | Returns the signed-in session's current Cognito ID token, or `null` if not signed in. Backs `KvsMediaViewerCredentialsClient`'s Lambda-relayed credential vending. |
| `kvsPlaybackLambdaUrl` | `String?` | The deployed `cloud_backend/kvs_playback_lambda` Function URL. Backs only `KvsMediaViewerCredentialsClient` now — `IotCommandClient` no longer uses it. |
| `awsCredentialsProvider` | `Future<WanAwsCredentials?> Function()?` | Returns real, temporary AWS credentials for the signed-in user's federated Identity Pool role, or `null` if not signed in. Expected to internally cache/refresh. Backs `IotCommandClient`'s direct MQTT-over-WSS connection. |
| `awsIotEndpoint` | `String?` | AWS IoT Core data-plane endpoint (no scheme, e.g. `xxxxx-ats.iot.ap-south-1.amazonaws.com`) — fleet-wide, same value the camera firmware connects to. Backs `IotCommandClient`. |
| `awsRegion` | `String?` | AWS region the Identity Pool / IoT endpoint live in (e.g. `ap-south-1`) — needed for SigV4 signing. Backs `IotCommandClient`. |
| `previewSharedKeyProvider` | `Future<Uint8List?> Function(String thingName)?` | Returns this device's cached copy of `thingName`'s camera-generated shared AES-256 preview key, or `null` if never fetched. Backs `WanPreviewSnapshotClient`. Redesigned 2026-08-21 from a single device-wide RSA private key to a per-camera shared symmetric key — see `PreviewKeyStore`'s doc. |
| `onPreviewKeyNeedsRegistration` | `void Function(String thingName)?` | Called when the camera reports its previously-generated preview key is gone (e.g. after a factory reset) — the app should flag that camera for automatic re-fetch next time it's reachable on LAN. |

`WanAwsCredentials` (`wan/wan_auth.dart`) is a minimal `{accessKeyId, secretKey, sessionToken}`
value type — a `camera_api`-local copy of `auth_api`'s `AwsCredentials` shape (this package can't
depend on `auth_api`), just the fields a single MQTT connect needs.

### IotCommandClient

`wan/iot_command_client.dart` — the low-level AWS IoT command transport every other WAN client in
this package sits on top of. **Talks directly to AWS IoT Core** over a single, persistent,
self-healing MQTT-over-WSS connection (`IotMqttTransport`, `wan/iot_mqtt_transport.dart`) — SigV4
WebSocket presigning with the app's own federated Cognito credentials, reused across every command
and every `IotCommandClient` instance/thingName in the process, not reconnected per call.

**History**: this used to be direct MQTT, then a Lambda-relayed HTTPS call (2026-07-31 —
2026-08-18, after AWS was found to reject Cognito-federated credentials for this call pattern),
then reverted back to direct MQTT (2026-08-18) once that restriction was re-tested live and found
no longer reproducing (`kb/raw/2026-08-18-fix-direct-iot-mqtt-restored.md`) — the relay's
fresh-connection-per-call pattern was costing up to ~12s per command by itself. If AWS ever
re-rejects direct Cognito-federated MQTT, that history is the reference for restoring a relay.

```dart
IotCommandClient(String thingName, {IotTransport? transport})
```

`transport` is the test seam (`IotTransport` interface, `wan/iot_mqtt_transport.dart`) — defaults
to `IotMqttTransport.instance`, the one shared connection.

| Method | Params | Returns | Description |
|---|---|---|---|
| `sendStartCloudStreaming` | `String quality` | `Future<Map<String, dynamic>?>` | **`FR-CF-154` (2026-09-14): request/response, not fire-and-forget** — `params.quality` (`"high"`/`"medium"`/`"low"`), replies with `{token, quality}` on success. Goes through `sendCommandWithResponse`, so it throws on a genuine camera-side rejection (e.g. missing/invalid quality) the same way every other request/response command does. |
| `sendStopCloudStreaming` | `{int? token}` | `Future<void>` | Fire-and-forget `StopCloudStreaming`. `token` (the lease from `sendStartCloudStreaming`) is sent as `params.token` when given; omitting it falls back to the camera's legacy "stop every quality" behavior. |
| `sendCommandWithResponse` | `int command, {Map<String, dynamic>? params, double? timeoutSeconds, bool retryOnTimeout}` | `Future<Map<String, dynamic>?>` | Generic request/response path for any command that replies on the camera's response topic (`vizenlink/response/<thingName>`), reassembling a chunked reply (`FR-NE-108`) if one arrives. Returns `null` **only** when no reply arrives within the window at all (default 12s, overridable via `timeoutSeconds`) — a successful reply with no `output` field (every `Set*`/`Delete*` command's normal shape, see `.claude/rules/cloud-components.md` § "Get/Set response asymmetry") returns an empty map, `{}`, never `null` (`BUG-020`, fixed 2026-08-18 — this class of bug was first found and fixed once already for the old Lambda relay, `BUG-006`; removing the relay dropped that same normalization until this fix restored it client-side). Has a one-shot automatic retry when no reply arrives at all (transient session jitter, not a stuck camera) — **added 2026-09-15**: pass `retryOnTimeout: false` to skip it (only from a caller that already polls on its own schedule, e.g. a reachability ping, where the retry just doubles worst-case latency). Throws on a genuine camera-side failure (`status != "ok"`). |

Every WAN setting client below is a thin typed wrapper around `sendCommandWithResponse` with a
specific integer command constant (defined as `static const` fields on this class, e.g.
`IotCommandClient.getMirrorFlip`) and a params/response shape. App code does not normally need to
call `IotCommandClient` directly except through those wrappers.

### KvsMediaViewerCredentialsClient

`wan/kvs_media/kvs_media_viewer_credentials_client.dart` — vends short-lived (900s),
stream-scoped AWS credentials for calling `kinesisvideo:GetMedia` directly, via the Lambda relay's
`mode=media` action. **Replaces `KvsPlaybackClient` entirely, 2026-09-17** — see
[KvsMediaLiveViewSession](#kvsmedialiveviewsession) below for why (AWS rejects Cognito-federated
credentials for `GetDataEndpoint`/`GetMedia` regardless of IAM policy, independently re-confirmed
live before this was built; the Lambda mints these via `sts:AssumeRole` under its own plain
execution role instead — no media bytes ever flow through the Lambda itself).

```dart
KvsMediaViewerCredentialsClient({http.Client? client, String? Function()? idTokenProvider})
```

| Method | Params | Returns | Description |
|---|---|---|---|
| `getCredentials` | `String streamName` | `Future<KvsMediaViewerCredentials>` | Returns `{accessKeyId, secretAccessKey, sessionToken, expiration, region, dataEndpoint}` — the Lambda resolves the `GetMedia` data-plane endpoint itself using the minted credentials, so the caller never needs a separate `GetDataEndpoint` round trip. Throws on failure. `streamName` is `<thing_name>-<quality>` (`high`/`medium`/`low`, all three suffixed — same `FR-CF-154` convention as before), normally built for you via `WanLiveViewClient.startMediaSession(quality)`. `KvsMediaViewerCredentials.isExpiringSoon({margin})` tells a caller to refresh before an actual `AccessDenied`. **Cloud/hardware-verified end-to-end** for both H.264 and H.265 (`testing_utilities/kvs_media_viewer_credentials_test.py`, 4/4 PASS each) — see `kb/raw/2026-09-17-code-kvs-media-viewer-credential-vending.md`. |

### KvsGetMediaClient

`wan/kvs_media/kvs_get_media_client.dart` — calls AWS KVS's `GetMedia` directly (`POST
/getMedia` on the per-stream data endpoint from
[KvsMediaViewerCredentialsClient](#kvsmediaviewercredentialsclient), SigV4-signed via
`AwsSigV4.signJsonPost`) and returns the raw response as an unbounded byte stream. **Internal
implementation detail, not called directly by any screen** —
[KvsMediaLiveViewSession](#kvsmedialiveviewsession) below is
the real consumer (fetches credentials, opens this connection, demuxes/remuxes the result); this
entry exists so the class itself has a documented contract, matching every other client in this
package, even though app code never constructs it directly. Wire format verified directly
against real `boto3`/`botocore` traffic (a captured real `GetMedia` request/response against a
fake endpoint) rather than assumed from documentation alone.

```dart
KvsGetMediaClient({http.Client? client})
```

| Method | Params | Returns | Description |
|---|---|---|---|
| `getMedia` | `{required KvsMediaViewerCredentials credentials, required String streamName}` | `Future<Stream<List<int>>>` | Opens a `GetMedia` connection starting from the live edge (`StartSelectorType: "NOW"` — the only selector this class supports; KVS's other selectors, for archived-fragment playback, aren't used here). Throws on a non-200 response. The returned stream stays open and keeps delivering bytes for as long as the camera keeps streaming — there is no natural end-of-stream for a live session; the caller must cancel its subscription (or call `close()`) to end the connection. |
| `close` | — | `void` | Closes the underlying HTTP client. |

### KvsMediaLiveViewSession

`wan/kvs_media/kvs_media_live_view_session.dart` — one WAN playback session: fetches
`KvsMediaViewerCredentials`, opens a direct signed `POST /getMedia` connection to AWS KVS via
[KvsGetMediaClient](#kvsgetmediaclient), demuxes the raw MKV stream (`mkv_demuxer.dart`'s `MkvDemuxer`),
remuxes it into fMP4, and serves that over a local HTTP loopback server — the WAN counterpart of
`mobile_app`'s LAN `RtspRemuxProxy`/`RtspLiveViewProxy`, same overall shape (`video_player`/
ExoPlayer plays the local loopback URL as an ordinary progressive/live fMP4 source).

**Reuses `media/fmp4_muxer.dart`'s `RtspFmp4Muxer` directly, not a separate muxer** (`kvs_fmp4_muxer.dart`'s
`KvsFmp4Muxer`, **deleted 2026-09-18**). Direct user hardware report: WAN playback decoded the
first video frame then permanently froze (audio kept advancing normally) — narrowed down over
several real-hardware test cycles to something in `KvsFmp4Muxer`'s own box construction, never
conclusively pinned to one specific field despite independently verifying (direct comparison
against a live RTSP capture of the same stream, plus manual SPS bit-level decoding) that both the
SPS bytes and every sample's AVCC framing were byte-correct. Rather than keep guessing at
individual box fields, `KvsMediaLiveViewSession._onSample` now **splits each (possibly
multi-NALU) `MkvSample` into its individual NALUs**, filters out parameter-set NALUs (SPS/PPS/
VPS/AUD/SEI — already baked into the init segment's `avcC`/`hvcC`, never resent as an ongoing
sample; same filter `RtspLiveViewSession._emitH264AccessUnit`/`_emitOrCaptureH265Nalu` already use
for the LAN path) and **converts millisecond timestamps to `RtspFmp4Muxer`'s own 90kHz-tick/
per-track-sample-rate conventions**, then feeds real slice NALUs through `RtspFmp4Muxer.fragment`/
`.audioFragment` — the exact code path LAN live view and LAN recorded-clip playback both already
use, hardware-proven. `KvsMediaViewerCredentials`/`GetMedia`/`MkvDemuxer` are completely
unaffected by this — only the final "already-demuxed samples -> fMP4 boxes" step changed. See
`media/fmp4_muxer.dart`'s own doc for the box-level details.

Along the way, also fixed: (1) a `video_player`/ExoPlayer live-position quirk (see
`RtspFmp4Muxer`'s `totalDurationSeconds` doc, `BUG-029`) — confirmed this session that leaving
duration `0`/unbounded is correct for a genuinely live WAN stream (matches `RtspLiveViewProxy`'s
own working convention); a large placeholder duration was tried and reverted after real-hardware
testing showed it made ExoPlayer switch into VOD-style buffering instead (position advanced, but
at ~1/8th real-time speed — worse, not fixed); (2) a latent audio-timestamp scaling bug —
`audioFragment`'s tick params must be in the audio track's own sample-rate timescale (RTSP's RTP
audio clock already ticks natively at the sample rate; KVS's millisecond Cluster timestamps did
not, and were never being converted before this fix); (3) `mkv_demuxer.dart`'s multi-fragment
timestamp continuity (`_fragmentTimeOffsetMs`) — defensive only, since this camera's KVS producer
turned out to already emit real absolute Unix epoch milliseconds as its Cluster timecodes
(confirmed against real captured bytes), so real fragment boundaries are naturally continuous on
their own; the correction now only applies if an actual regression is detected, never
unconditionally (an earlier version applied it on every real fragment boundary too, which — since
real timestamps didn't need correcting — nudged them by a small, usually-wrong amount each time).
**Hardware-verified 2026-09-18**: real WAN medium-quality playback confirmed smooth by the user
after all three fixes, with WAN-vs-LAN latency now ~3s (down from the broken version's much
larger, drifting gap) — see `kb/raw/` for the full investigation if one exists, or this package's
git history around 2026-09-18 for the session that found and fixed this.

There is no dedicated unit test for `RtspFmp4Muxer`'s box output itself (verified via real-device
hardware testing only, both here and for its original LAN use) — `mkv_demuxer_test.dart` covers
the demuxer side (parsing real captured `GetMedia` fixture bytes, including the multi-fragment
case) but nothing here exercises `KvsMediaLiveViewSession`'s own NALU-splitting/timestamp-
conversion logic in isolation. Worth adding if this path regresses again.

**Replaces `GetHLSStreamingSessionURL`-based WAN playback entirely, 2026-09-17** — not just for
H.265 (which AWS rejects outright: `UnsupportedStreamMediaTypeException`;
`GetDASHStreamingSessionURL` has the identical restriction despite more permissive-sounding prose,
both confirmed against the real AWS API) but for H.264 too, so the app has exactly one WAN
playback code path regardless of codec.

```dart
class KvsMediaLiveViewSession {
  KvsMediaLiveViewSession({
    required String streamName,
    KvsMediaViewerCredentialsClient? credentialsClient,
    KvsGetMediaClient? getMediaClient,
  })

  Uri? url;                    // the local loopback URL, set once start() completes
  Future<void> start();        // throws if credential vending or the initial GetMedia request fails
  Future<void> stop();         // tears down GetMedia + the local HTTP server; safe to call more than once
  bool get isSessionEnded;     // true once the GetMedia stream itself errored or ended
  void Function(String message)? onLog;
}
```

**One session instance per playback attempt — deliberately not reusable across reconnects**, same
convention as `RtspRemuxProxy`. The local server refuses new HTTP connections once
`isSessionEnded` is `true` (the underlying `GetMedia` connection died) — on any disconnect/error,
construct a **fresh** `KvsMediaLiveViewSession`, never retry against the same `url`.
`LiveViewController.reconnectWan()` is the app-level entry point for this (see
`live_view_controller.dart`'s doc). Demuxer correctness verified against real captured AWS KVS
fixture bytes for both codecs (`camera_api/test/mkv_demuxer_test.dart`, including the
multi-fragment `GetMedia` case) — `CodecPrivate` for a video track is already a byte-for-byte
valid `avcC`/`hvcC` payload and `SimpleBlock` frame data is already 4-byte-length-prefixed AVCC/
HVCC NALUs on this wire (the firmware's own KVS producer builds it that way), so
`KvsMediaLiveViewSession` never reconstructs either from raw SPS/PPS/VPS — it extracts the
individual parameter-set NALUs back out of the already-built `avcC`/`hvcC` blob instead (see
`_extractParamSets` in the source), since that's what `RtspFmp4Muxer`'s constructor needs.

### WanLiveViewClient / AwsWanLiveViewClient

`wan/wan_live_view_client.dart` defines the interface; `wan/aws_wan_live_view_client.dart`
provides the concrete implementation over `IotCommandClient` + `KvsMediaLiveViewSession`.

**`FR-CF-154` (2026-09-14): quality-selective, reference-counted, per-viewer lease tokens.**
Every KVS stream (`StreamQuality.high`/`.medium`/`.low`, one per LAN RTSPS quality tier) is a
real, independently-billed AWS resource, so the app must start only the one the user picked, and
share it with other concurrent viewers of the same tier via a camera-side reference count.
`startCloudStreaming` now takes the requested tier and returns a per-viewer lease token instead
of `void`; `stopCloudStreaming`/`getCloudStreamingStatus` take that token back —
`getCloudStreamingStatus` doubles as the lease heartbeat (see the method table below).

```dart
abstract interface class WanLiveViewClient {
  Future<CameraResult<int>> startCloudStreaming(StreamQuality quality);
  Future<CameraResult<void>> stopCloudStreaming(int token);
  Future<CameraResult<StreamStatus>> getCloudStreamingStatus(int token);
  Future<CameraResult<KvsMediaLiveViewSession>> startMediaSession(StreamQuality quality);
}

class AwsWanLiveViewClient implements WanLiveViewClient {
  AwsWanLiveViewClient(
    String thingName, {
    IotCommandClient? iotCommandClient,
  })
}
```

| Method | Description |
|---|---|
| `startCloudStreaming(quality)` | Starts (or, if another viewer already has this tier running, just joins) the KVS push for the requested `StreamQuality`. Returns the viewer's lease `int` token on success. |
| `stopCloudStreaming(token)` | Releases this viewer's lease; the camera tears the stream down once the last viewer's lease is released. |
| `getCloudStreamingStatus(token)` | Returns `active`/`idle`/`degraded`/`notCompiled` (`StreamStatus` enum) for this viewer's tier. Retries a couple of times on a transient `idle` result right after starting, since the substream can legitimately still be spinning up. **Also refreshes the camera-side lease for `token`** — call at least every 30s or the camera drops it (`bsp_camera_pollKvsViewerLeases()`, firmware-side). |
| `startMediaSession(quality)` | Starts and returns a fresh, already-connected `KvsMediaLiveViewSession` for `quality`'s stream once streaming is confirmed active. **Replaces `resolvePlaybackUri` (2026-09-17)** — callers must `stop()` the returned session when WAN playback ends for any reason, not just discard it (a live resource, unlike the old HLS URL). |

**Usage note, direct user hardware report 2026-09-18**: never call `startCloudStreaming`/
`startMediaSession` from a screen's own "just resolve reachability/enable the settings icon"
path — each KVS stream is a real, individually-billed AWS resource (see the `FR-CF-154` note
above), and calling this just from opening a live-view screen (before the user has asked to
actually watch anything) starts billing immediately, every time. `mobile_app`'s own
`LiveViewController` had exactly this bug: `start()` was called unconditionally from several
"just ping the camera" sites (screen `initState`, network reconnect, app resume, returning from
a settings screen), and its default behavior fell through to `startCloudStreaming` the moment LAN
was unreachable. Fixed via `LiveViewController.start({bool allowWan = true})` — every eager/
silent call site now passes `allowWan: false` (still does a cheap LAN-only reachability check,
but stops short of ever calling into WAN); only an explicit user action (tapping play, or a
manual retry) uses the default `allowWan: true`. Any future WAN caller should follow the same
shape: separate "is the camera reachable at all" from "the user wants to watch," and only ever
call `startCloudStreaming` for the latter.

**Hardware/cloud-verified for the pre-`FR-CF-154` shape** (corrected 2026-08-13 — was stale);
**the `FR-CF-154` quality/token rework itself is build-verified only, not yet hardware-verified**
as of 2026-09-14; **the `startMediaSession`/`GetMedia` replacement is cloud/hardware-verified for
credential vending + raw `GetMedia` fetch (both codecs), and — corrected 2026-09-18, was stale —
the full `LiveViewController` wiring is now genuinely hardware-verified too**: real WAN medium-
quality live playback (H.264) confirmed smooth end-to-end on a real device after the
`KvsMediaLiveViewSession`/`RtspFmp4Muxer` fix above (see that section for the full incident).
High-quality WAN playback is a **separate, still-open issue** — a persistent KVS `PutMedia`
`FRAMES_MISSING_FOR_TRACK` (`errorId=4011`) failure loop was found on the camera/KVS-producer
side specifically for the high-quality stream, unrelated to this fix; not yet root-caused. See
[STREAMING_GUIDE.md](STREAMING_GUIDE.md) for the full WAN sequence this class implements, and its
"Reconnect and failure semantics" section for a known, unresolved gap in how the app recovers from
a camera-initiated stop mid-session.

**Fixed 2026-08-14**: `getCloudStreamingStatus()` was the one method on this class missing the
`try`/`catch` its three siblings all had — `IotCommandClient.sendCommandWithResponse()` throws
on a genuine relay/network failure, and with nothing to catch it here that exception propagated
straight out past every caller's `CameraResult` switch, crashing on a plain transient network
failure (found by the mobile app team on a real device as an uncaught `SocketException`). Fixed,
and the constructor now accepts `iotCommandClient`/`kvsPlaybackClient` overrides (matching every
other `Wan*Client` in this package) — it previously had no way to inject a fake client at all,
which is why no test had ever exercised this class's real logic directly (every existing test
went through a hand-written fake of the `WanLiveViewClient` *interface* instead). See
`test/aws_wan_live_view_client_test.dart` for the new coverage.

### WanAudioVolumeClient

`wan/wan_audio_volume_client.dart` — WAN counterpart to `AudioVolumeClient`'s mic-gain,
recording-toggle, and test-sound half. **Recording on/off (`isAudioRecordingEnabled`/
`setAudioRecordingEnabled`) was previously undocumented as WAN-capable and unwired in the app
— the firmware command (`FR-NE-078`) had been `Implemented` and hardware-verified since
2026-07-28; wired into this client and `LiveViewScreen` 2026-08-11.**

```dart
WanAudioVolumeClient(String thingName, {IotCommandClient? iotCommandClient})
```

| Method | Params | Returns | Description |
|---|---|---|---|
| `getMicGain` | `{Duration timeout}` | `CameraResult<int>` | Current mic gain. |
| `setMicGain` | `int gain, {Duration timeout}` | `CameraResult<void>` | Sets mic gain. |
| `isAudioRecordingEnabled` | `{Duration timeout}` | `CameraResult<bool>` | Whether the mic is actively capturing at all. |
| `setAudioRecordingEnabled` | `bool enabled, {Duration timeout}` | `CameraResult<void>` | Toggles mic recording. |
| `playTestSound` | `{Duration timeout}` | `CameraResult<void>` | Plays the speaker test tone. |
| `stopTestSound` | `{Duration timeout}` | `CameraResult<void>` | Stops it. |
| `isTestSoundPlaying` | `{Duration timeout}` | `CameraResult<bool>` | Whether the test tone is still playing. |

### WanSpeakerVolumeClient

`wan/wan_speaker_volume_client.dart` — WAN counterpart to `SpeakerVolumeClient`. Returns a bare
`int` (not the ONVIF-shaped `SpeakerVolume` struct, since the WAN command has no
token/name/outputToken sibling fields to echo).

```dart
WanSpeakerVolumeClient(String thingName, {IotCommandClient? iotCommandClient})
```

| Method | Params | Returns | Description |
|---|---|---|---|
| `getSpeakerVolume` | `{Duration timeout}` | `CameraResult<int>` | Current output volume (0-100). |
| `setSpeakerVolume` | `int volume, {Duration timeout}` | `CameraResult<void>` | Sets output volume. |

### WanDeviceIdentityClient

`wan/wan_device_identity_client.dart` — WAN counterpart to `OnvifDeviceClient`'s name/location/
time-zone/password setters, plus reboot/factory-reset. Not a formal shared interface with
`OnvifDeviceClient`, but structurally matching signatures so a call site can pick either.

```dart
WanDeviceIdentityClient(String thingName, {IotCommandClient? iotCommandClient})
```

| Method | Params | Returns | Description |
|---|---|---|---|
| `getDeviceIdentity` | `{Duration timeout, bool retryOnTimeout}` | `CameraResult<({String name, String location, String timezone})>` | All three fields in one combined WAN read. **Fixed 2026-09-15**: `timeout` used to be declared but never forwarded to `sendCommandWithResponse`, silently falling back to its 12s default (plus the one-shot retry, ~24s worst case) regardless of what was asked for — now honored. `retryOnTimeout` (default `true`) passes through to `sendCommandWithResponse`; set `false` for a caller that polls on its own schedule (e.g. a reachability ping), where the retry only doubles worst-case latency for no benefit. |
| `getDeviceInfo` | `{Duration timeout}` | `CameraResult<DeviceInformation>` | `FR-NE-115`, added 2026-08-21 — WAN mirror of `OnvifDeviceClient.getDeviceInformation()` (manufacturer/model/firmware/serial/hardware ID). Returns the same `DeviceInformation` type as the LAN client, since the field set is identical either way. Distinct from `getDeviceIdentity` above (user-configurable name/location/timezone, not this fixed build/hardware identity). |
| `setDeviceName` | `String name, {Duration timeout}` | `CameraResult<void>` | Sets display name. |
| `setDeviceLocation` | `String location, {Duration timeout}` | `CameraResult<void>` | Sets location. |
| `setTimeZone` | `String tz, {Duration timeout}` | `CameraResult<void>` | Sets time zone. |
| `setUserPassword` | `String username, String newPassword, {Duration timeout}` | `CameraResult<void>` | Same single-account-slot semantics as the LAN client — **caller must update `CameraConnection.password` on success.** |
| `reboot` | `{Duration timeout}` | `CameraResult<void>` | WAN mirror of `OnvifDeviceClient.reboot` — no WAN transport exists for ONVIF SOAP, so this is the only way a WAN-only client can reboot the camera. |
| `factoryReset` | `FactoryResetMode mode, {Duration timeout}` | `CameraResult<void>` | WAN mirror of `OnvifDeviceClient.factoryReset` — **the camera reboots automatically afterward**, same as the LAN client. **A Hard reset issued over WAN wipes the WiFi credentials that WAN connectivity itself depends on** — the one path that reliably severs the app's own ability to reach this camera again until it's re-onboarded on LAN; warn the user accordingly. |

### WanImageQualityClient

`wan/wan_image_quality_client.dart` — WAN counterpart to `OnvifImagingClient`'s ISP image-quality
fields (brightness/contrast/saturation/sharpness/white-balance/exposure).

```dart
WanImageQualityClient(String thingName, {IotCommandClient? iotCommandClient})
```

| Method | Params | Returns | Description |
|---|---|---|---|
| `getImageSettings` | `{Duration timeout}` | `CameraResult<Map<String, dynamic>>` | Current image-quality field values, as a raw JSON map. |
| `setImageSettings` | `Map<String, dynamic> params, {Duration timeout}` | `CameraResult<Map<String, dynamic>>` | Applies given fields. |
| `getImageSettingsOptions` | `{Duration timeout}` | `CameraResult<Map<String, dynamic>>` | Bounds for the fields above. |
| `getImageDefaults` | `{Duration timeout}` | `CameraResult<Map<String, dynamic>>` | Factory-default values — the "Reset to Default" source. |

### WanImagingClient

`wan/wan_imaging_client.dart` — WAN counterpart to `OnvifImagingClient`'s Day/Night and WDR
fields. Mirror/Flip and ISP image quality are out of scope here (see `WanMirrorFlipClient`/
`WanImageQualityClient`).

```dart
WanImagingClient(String thingName, {IotCommandClient? iotCommandClient})
```

| Method | Params | Returns | Description |
|---|---|---|---|
| `getDayNightMode` | `{Duration timeout}` | `CameraResult<String>` | Configured mode, translated to the `ON`/`OFF`/`AUTO` vocabulary the LAN/ONVIF side uses (the wire protocol itself uses lowercase `day`/`night`/`auto`). |
| `getEffectiveDayMode` | `{Duration timeout}` | `CameraResult<bool>` | Live effective state (`true` = day) — initial value only; live updates come via a separate alert-hub mechanism the app layer owns. |
| `getVideoModeStatus` | `{Duration timeout}` | `CameraResult<({String configuredMode, bool isDayMode})>` | Combined configured+effective read in one round trip. `configuredMode` is untranslated (raw `day`/`night`/`auto`). |
| `setDayNightMode` | `String onvifMode, {Duration timeout}` | `CameraResult<void>` | Accepts `ON`/`OFF`/`AUTO`, translates internally. |
| `getWdr` | `{Duration timeout}` | `CameraResult<({bool enabled, double level})>` | Current WDR state. |
| `setWdr` | `bool enabled, double level, {Duration timeout}` | `CameraResult<void>` | Sets WDR state. |
| `getImagingOptions` | `{Duration timeout}` | `CameraResult<({List<String> dayNightModes, bool wdrSupported})>` | Day/Night choice list (`ON`/`OFF`/`AUTO` vocabulary) and WDR support flag. |

`thingName` is exposed as a public field so callers can filter a shared WAN alert stream down to
this specific camera.

### WanMaskClient

`wan/wan_mask_client.dart` — WAN counterpart to `MaskClient`. Reuses `MaskEntry`/`MaskColor`/
`MaskOptions`/`OnvifPoint` from the LAN side so callers work with identical types regardless of
transport.

```dart
WanMaskClient(String thingName, {IotCommandClient? iotCommandClient})
```

| Method | Params | Returns | Description |
|---|---|---|---|
| `getMasks` | `{Duration timeout}` | `CameraResult<List<MaskEntry>>` | Currently-configured masks. |
| `getMaskOptions` | `{Duration timeout}` | `CameraResult<MaskOptions>` | Mask capability envelope. |
| `setMask` | `{String token = '', required List<OnvifPoint> polygon, required bool enabled, required String type, MaskColor? color, Duration timeout}` | `CameraResult<String>` | Empty/omitted `token` creates a new mask; non-empty updates an existing one. Returns the applied token. |
| `deleteMask` | `String token, {Duration timeout}` | `CameraResult<void>` | Removes a mask. |

### WanMirrorFlipClient

`wan/wan_mirror_flip_client.dart` — WAN counterpart to `MirrorFlipClient`. Same `MirrorFlipMode`
enum as LAN.

```dart
WanMirrorFlipClient(String thingName, {IotCommandClient? iotCommandClient})
```

| Method | Params | Returns | Description |
|---|---|---|---|
| `getMirrorFlip` | `{Duration timeout}` | `CameraResult<MirrorFlipMode>` | Current mode. |
| `setMirrorFlip` | `MirrorFlipMode mode, {Duration timeout}` | `CameraResult<void>` | Sets mode. |

### WanAntiFlickerClient

`wan/wan_anti_flicker_client.dart` — WAN counterpart to `AntiFlickerClient`. Same
`AntiFlickerMode` enum as LAN.

```dart
WanAntiFlickerClient(String thingName, {IotCommandClient? iotCommandClient})
```

| Method | Params | Returns | Description |
|---|---|---|---|
| `getAntiFlickerMode` | `{Duration timeout}` | `CameraResult<AntiFlickerMode>` | Current mode. |
| `setAntiFlickerMode` | `AntiFlickerMode mode, {Duration timeout}` | `CameraResult<void>` | Sets mode. |

### WanEventPreferencesClient

`wan/wan_event_preferences_client.dart` — WAN counterpart to `EventPreferencesClient`. Same
wire vocabulary and partial-update semantics as LAN. No WAN "supported types" command — see
`CapabilitiesClient.supportedEventTypes`, LAN-only.

```dart
WanEventPreferencesClient(String thingName, {IotCommandClient? iotCommandClient})
```

| Method | Params | Returns | Description |
|---|---|---|---|
| `getEventPreferences` | `{Duration timeout}` | `CameraResult<Map<String, bool>>` | Current enabled/disabled state. |
| `setEventPreferences` | `Map<String, bool> changes, {Duration timeout}` | `CameraResult<void>` | Partial update — same semantics as the LAN client. |

### WanEventResponseActionsClient

`wan/wan_event_response_actions_client.dart` — WAN counterpart to `EventResponseActionsClient`.
Same wire vocabulary and partial-update semantics as LAN. No WAN "supported deterrence options"
command — see `CapabilitiesClient.supportedEventDeterrenceOptions`, LAN-only.

```dart
WanEventResponseActionsClient(String thingName, {IotCommandClient? iotCommandClient})
```

| Method | Params | Returns | Description |
|---|---|---|---|
| `getEventResponseActions` | `{Duration timeout}` | `CameraResult<Map<String, List<String>>>` | Current selected response actions per detection event type. |
| `setEventResponseActions` | `Map<String, List<String>> changes, {Duration timeout}` | `CameraResult<void>` | Partial update — same semantics as the LAN client. |

### WanDeterrenceClient

`wan/wan_deterrence_client.dart` — WAN counterpart to `DeterrenceClient`. Same wire vocabulary
and "no duration parameter on activate" behavior as LAN (`FEAT-236`). No WAN "capabilities"
command — see `CapabilitiesClient.sirenCapable`/`spotlightCapable`/`warningCapable`, LAN-only.

```dart
WanDeterrenceClient(String thingName, {IotCommandClient? iotCommandClient})
```

| Method | Params | Returns | Description |
|---|---|---|---|
| `getDeterrenceStatus` | `{Duration timeout}` | `CameraResult<DeterrenceStatus>` | Each deterrence action's own independent active/inactive state — same shape as `DeterrenceClient.getDeterrenceStatus`, see there. |
| `activateDeterrence` | `String action, {Duration timeout}` | `CameraResult<void>` | No duration parameter — the camera applies its own persisted duration. |
| `deactivateDeterrence` | `String action, {Duration timeout}` | `CameraResult<void>` | Stops immediately. |
| `getDeterrenceDurations` | `{Duration timeout}` | `CameraResult<Map<String, int>>` | Current configured auto-stop value per action. |
| `setDeterrenceDurations` | `Map<String, int> changes, {Duration timeout}` | `CameraResult<void>` | Partial update — same semantics as the LAN client. |
| `getDeterrenceDurationOptions` | `{Duration timeout}` | `CameraResult<DeterrenceDurationOptions>` | Camera-reported valid range per key — same semantics as the LAN client. |

### WanBboxOverlayClient

`wan/wan_bbox_overlay_client.dart` — WAN counterpart to `BboxOverlayClient`. Same wire
vocabulary as LAN. No WAN "capability" command — see `CapabilitiesClient.bboxOverlayCapable`,
LAN-only.

```dart
WanBboxOverlayClient(String thingName, {IotCommandClient? iotCommandClient})
```

| Method | Params | Returns | Description |
|---|---|---|---|
| `isBboxOverlayEnabled` | `{Duration timeout}` | `CameraResult<bool>` | Whether the overlay is currently drawn. |
| `setBboxOverlayEnabled` | `bool enabled, {Duration timeout}` | `CameraResult<void>` | Toggles the overlay. |

### WanLoiteringDurationClient

`wan/wan_loitering_duration_client.dart` — WAN counterpart to `LoiteringDurationClient`. Same
wire vocabulary and bounds as LAN. No WAN "bounds" command — see
`CapabilitiesClient.loiteringDurationMinSeconds`/`MaxSeconds`, LAN-only.

```dart
WanLoiteringDurationClient(String thingName, {IotCommandClient? iotCommandClient})
```

| Method | Params | Returns | Description |
|---|---|---|---|
| `getLoiteringDuration` | `{Duration timeout}` | `CameraResult<int>` | Current configured dwell threshold, in seconds. |
| `setLoiteringDuration` | `int seconds, {Duration timeout}` | `CameraResult<void>` | Same bounds/rejection semantics as the LAN client. |

### WanNightVisionClient

`wan/wan_night_vision_client.dart` — WAN counterpart to `NightVisionClient`, also implementing
`NightVisionSource`.

```dart
class WanNightVisionClient implements NightVisionSource {
  WanNightVisionClient(String thingName, {IotCommandClient? iotCommandClient})
}
```

| Method | Params | Returns | Description |
|---|---|---|---|
| `getNightVisionType` | `{Duration timeout}` | `CameraResult<NightVisionStatus>` | Same response shape as the LAN client. |
| `setNightVisionType` | `NightVisionType type, {Duration timeout}` | `CameraResult<void>` | Sets night-vision type. |

### WanOsdClient

`wan/wan_osd_client.dart` — WAN counterpart to `OsdClient`. Reuses `OsdEntry`/`OsdColor`/
`OsdOptions` from the LAN side. Scoped to the same two OSD text-string types `OsdClient` models
(`Plain`, `DateAndTime`).

```dart
WanOsdClient(String thingName, {IotCommandClient? iotCommandClient})
```

| Method | Params | Returns | Description |
|---|---|---|---|
| `getOsds` | `{Duration timeout}` | `CameraResult<List<OsdEntry>>` | Currently-configured OSD entries. |
| `getOsdOptions` | `{Duration timeout}` | `CameraResult<OsdOptions>` | OSD capability envelope. |
| `setOsd` | `{String token = '', required String textType, String? text, String posType = 'Custom', double? posX, double? posY, String? dateFormat, String? timeFormat, OsdColor? fontColor, Duration timeout}` | `CameraResult<String>` | Empty/omitted `token` creates a new OSD of `textType`; non-empty updates an existing one. Returns the applied token. |
| `deleteOsd` | `String token, {Duration timeout}` | `CameraResult<void>` | Removes an OSD entry. |

### WanLocalStorageClient

`wan/wan_local_storage_client.dart` — WAN counterpart to `LocalStorageClient`. Same
`LocalStorageStatus` type as LAN.

```dart
WanLocalStorageClient(String thingName, {IotCommandClient? iotCommandClient})
```

| Method | Params | Returns | Description |
|---|---|---|---|
| `getStatus` | `{Duration timeout}` | `CameraResult<LocalStorageStatus>` | Live status. |
| `setEnabled` | `bool enabled, {Duration timeout}` | `CameraResult<void>` | Same card-present rejection behavior as the LAN client. |

### WanRecordingModeClient

`wan/wan_recording_mode_client.dart` — WAN counterpart to `RecordingModeClient`. Same
`RecordingModeStatus` type as LAN.

```dart
WanRecordingModeClient(String thingName, {IotCommandClient? iotCommandClient})
```

| Method | Params | Returns | Description |
|---|---|---|---|
| `getMode` | `{Duration timeout}` | `CameraResult<RecordingModeStatus>` | Same fields as the LAN client. |
| `setMode` | `RecordingMode mode, {List<RecordingScheduleWindow> schedule, Duration timeout}` | `CameraResult<void>` | Same schedule/rejection behavior as the LAN client. |
| `getSupportedModes` | `{Duration timeout}` | `CameraResult<List<RecordingMode>>` | `FR-NE-089`/`FR-MOB-088` capability set. Per this app's "Options are LAN-only, with one exception" convention, callers should reach for this only as WAN Set-failure recovery, not a normal load path. |

### WanRecordingsClient

WAN counterpart of `RecordingsClient` (`FR-CF-152`, commands 80/81) — what the recording
timeline needs to list clips before WAN playback can start one.

```dart
WanRecordingsClient(String thingName, {IotCommandClient? iotCommandClient})
```

| Method | Returns | Notes |
|---|---|---|
| `getRecordingDates({start, end, tzOffsetMinutes})` | `CameraResult<List<DateTime>>` | Local-midnight dates with ≥1 clip (newest ≤50 kept by the camera). |
| `getRecordings({start, end})` | `CameraResult<List<RecordingClip>>` | Follows the camera's 20-clip pages internally. `sizeBytes`/`active` are not sent over WAN (0/false). |

### WanClipPlaybackClient

WAN recorded-clip playback control (`FR-CF-152`, commands 75–79). The camera streams the clip into
the KVS stream `wanClipPlaybackStreamName(thingName)` (`<thing>-playback`); play it with
`KvsMediaLiveViewSession(streamName: client.streamName)`. One playback session camera-wide.

```dart
WanClipPlaybackClient(String thingName, {IotCommandClient? iotCommandClient})
```

| Method | Notes |
|---|---|
| `startClip(clipId, {startMs})` | `clipId` is `RecordingClip.id`. 30 s timeout, never auto-retried. |
| `seekClip(clipId, startMs)` / `pause()` / `resume({startMs})` | The recording timeline screen only uses start+stop (teardown/restart) for seek and pause. |
| `stop()` | Safe when idle; releases the camera's playback slot. |

### WanHealthClient

`wan/wan_health_client.dart` — WAN counterpart to `HealthClient`, command `70`. Same
`HealthStatus` type as LAN. Read-only, no matching Set command.

```dart
WanHealthClient(String thingName, {IotCommandClient? iotCommandClient})
```

| Method | Params | Returns | Description |
|---|---|---|---|
| `getHealth` | `{Duration timeout}` | `CameraResult<HealthStatus>` | Same fields as the LAN client. |

### WanPrivacyModeClient

`wan/wan_privacy_mode_client.dart` — WAN counterpart to `PrivacyModeClient`. Same `PrivacyMode`
enum as LAN.

```dart
WanPrivacyModeClient(String thingName, {IotCommandClient? iotCommandClient})
```

| Method | Params | Returns | Description |
|---|---|---|---|
| `getPrivacyMode` | `{Duration timeout}` | `CameraResult<PrivacyMode>` | Current mode. |
| `setPrivacyMode` | `PrivacyMode mode, {Duration timeout}` | `CameraResult<void>` | Sets mode. |

### WanVideoEncoderClient

`wan/wan_video_encoder_client.dart` — WAN counterpart to `OnvifVideoEncoderClient`. Structurally
matching methods, not a formal shared interface. **Generalized 2026-09-10, direct user request**
("add WAN support for all streams, use existing API only with extra input arg to identify the
stream similar to ONVIF pattern") — every method takes a `configToken`, sent as the WAN command's
`config_token` param (mirrored firmware-side, `nuraeye.c`'s `GetVideoEncoderSettings`/
`SetVideoEncoderSettings`/`GetVideoEncoderSettingsOptions` handlers), rather than adding new
commands per stream. Defaults to `kHighResVideoEncoderToken`.

```dart
WanVideoEncoderClient(String thingName, {IotCommandClient? iotCommandClient})
```

| Method | Params | Returns | Description |
|---|---|---|---|
| `getVideoEncoderSettings` | `{String configToken = kHighResVideoEncoderToken, Duration timeout}` | `CameraResult<VideoEncoderSettings>` | Current encoder settings for the given stream. |
| `setVideoEncoderSettings` | `VideoEncoderSettings settings, {String? configToken, Duration timeout}` | `CameraResult<VideoEncoderSettings>` | Applies every field in `settings` (no partial-update reason to diff, since callers always hold the full loaded+edited struct). `configToken` defaults to `settings.token` when omitted. Returns the actual applied (post-clamp) values. |
| `getVideoEncoderSettingsOptions` | `{String configToken = kHighResVideoEncoderToken, Duration timeout}` | `CameraResult<VideoEncoderSettingsOptions>` | Per-encoding bounds/choices for the given stream. **Per this project's UX convention, WAN Options should only ever be fetched as a recovery step immediately after a WAN Set failure** — normal loads use LAN Options only; this client itself does not enforce that, the call site must. |

### WanPreviewSnapshotClient

`wan/wan_preview_snapshot_client.dart` — end-to-end-encrypted WAN reference-snapshot preview,
distinct from the persisted WAN snapshot mechanism. The camera encrypts the frame before it
leaves the device (AES-256-GCM under a shared key); this client is the only place that ever
holds the plaintext again, after decrypting locally with the device's cached shared key
(`WanAuth.previewSharedKeyProvider`).

**Redesigned 2026-08-21**: previously each device generated its own RSA-2048 keypair and the
camera RSA-OAEP-wrapped a fresh per-request AES key to it — a second app registering its own key
silently locked the first app out (only the most-recently-registered key could ever decrypt).
The camera now generates and owns one shared AES-256 key (`RestStreamingClient.getPreviewKey()`,
LAN, `GET /nuraeye/preview-key`) that any authorized app can fetch — no more per-device
asymmetric key, no more `wrapped_key` field in the response envelope.

```dart
WanPreviewSnapshotClient(String thingName, {IotCommandClient? iotCommandClient})
```

| Method | Params | Returns | Description |
|---|---|---|---|
| `getPreviewSnapshot` | `{Duration timeout = 25s}` | `CameraResult<Uint8List>` | Fetches, decrypts, and returns one preview frame. Returns `CameraFailure` if no shared key is cached yet (open a settings screen on LAN once first) — and, if the camera itself reports its key is gone (e.g. after a factory reset), calls `WanAuth.onPreviewKeyNeedsRegistration` as a side effect. |

**Callers must not persist the returned bytes** (no gallery save, no cache file) — this is a
transient configuration-screen backdrop, not a kept/shared snapshot.

---

## Shared types

These live at the package root (`src/`) rather than under `lan/` or `wan/`, because both a LAN
and a WAN client pair share them:

- **`mirror_flip_types.dart`** — `enum MirrorFlipMode { off, mirror, flip, both }` plus
  `MirrorFlipModeWire` extension (`.wireValue` getter, `.fromWire(String)` static parser). Shared
  by `MirrorFlipClient`/`WanMirrorFlipClient`.
- **`anti_flicker_types.dart`** — `enum AntiFlickerMode { hz50, hz60, auto }` plus
  `AntiFlickerModeWire` extension (`.wireValue` getter, `.fromWire(String)` static parser).
  Shared by `AntiFlickerClient`/`WanAntiFlickerClient`.
- **`night_vision_types.dart`** — `enum NightVisionType { grey, color, smart }`,
  `NightVisionTypeWire` extension, `NightVisionStatus` (value-equality class: `type`,
  `colorCapable`, `smartCapable`, `subState`), and the `NightVisionSource` abstract interface
  (`getNightVisionType`/`setNightVisionType`) both `NightVisionClient` and `WanNightVisionClient`
  implement — lets UI code hold either behind one reference type.
- **`privacy_mode_types.dart`** — `enum PrivacyMode { none, zone, full }` plus `PrivacyModeWire`
  extension. Shared by `PrivacyModeClient`/`WanPrivacyModeClient`.
- **`local_storage_types.dart`** — `LocalStorageStatus` (`enabled`, `cardPresent`,
  `capacityBytes`, `freeBytes`). Shared by `LocalStorageClient`/`WanLocalStorageClient`.
- **`recording_mode_types.dart`** — `enum RecordingMode { continuous, scheduled,
  eventTriggered }` (`.wireValue` getter, `.fromWireValue(String?)` static parser),
  `RecordingScheduleWindow` (value-equality: `dayOfWeek` `0`-`6`=Sun-Sat, `startMinute`/
  `endMinute` minutes since local midnight, no overnight wrap), and `RecordingModeStatus`
  (value-equality: `mode`, `schedule`, `eventTriggerSourceConfigured`). Shared by
  `RecordingModeClient`/`WanRecordingModeClient`.
- **`health_types.dart`** — `HealthStatus` (`rebootCount`, `lastRebootUtc`, `rebootReason`,
  `uptimeSeconds`, `clockSyncState`, `uncertainSince`, `firmwareVersion`) and
  `enum ClockSyncState { synced, uncertain }`. Shared by `HealthClient`/`WanHealthClient`.
- **`recordings_types.dart`** — `RecordingClip` (`id`, `start`, `end`, `sizeBytes`, `active`,
  `trigger`) and `RecordingsList` (`storageAvailable`, `cardPresent`, `truncated`, `clips`). LAN
  only for now — `RecordingsClient` is the sole client using these, no WAN counterpart exists
  yet, so this isn't shared across a LAN/WAN pair the way the other types above are; it lives at
  the package root anyway, matching this file's existing convention for wire-vocabulary types.
- **`device_reset_types.dart`** — `enum FactoryResetMode { soft, hard }` plus
  `FactoryResetModeWire` extension (`.wireValue` getter — `"Soft"`/`"Hard"`, the literal ONVIF
  `FactoryDefault` type values). **Soft** erases camera settings only, network config preserved
  (device stays reachable); **Hard** also erases network config, forcing the device back into AP
  provisioning mode. Shared by `OnvifDeviceClient.factoryReset`/
  `WanDeviceIdentityClient.factoryReset`. Unlike the other shared types above, this is a real
  ONVIF-standard type, not a NuraEye-only one — it lives here only because both a LAN and WAN
  client need it.
- **`util/onvif_rect_coordinates.dart`** — pixel-space ↔ ONVIF-normalized-coordinate conversion,
  used by the mask editor and OSD position drag:
  - `OnvifPoint(x, y)` — a single ONVIF point, each axis in `[-1, 1]`, Y increasing upward.
  - `PixelRect`/`PixelSize`/`PixelPoint` — pixel-space stand-ins for `dart:ui`'s `Rect`/`Size`/
    `Offset` (unavailable in this Flutter-free package).
  - `pixelRectToOnvifPolygon(PixelRect, PixelSize)` → `List<OnvifPoint>` — converts a pixel
    rectangle (top-left origin) into a clamped 4-point ONVIF polygon (top-left, top-right,
    bottom-right, bottom-left order).
  - `onvifPolygonToPixelRect(List<OnvifPoint>, PixelSize)` → `PixelRect` — the inverse, via
    bounding box (this firmware's masks are hardware rectangles regardless of point count).
  - `pixelPointToOnvifPos(PixelPoint, PixelSize)` → `OnvifPoint` / `onvifPosToPixelPoint(...)` →
    `PixelPoint` — single-point conversions for OSD placement.

Two other small shared pieces worth knowing about even though they aren't "types" in the same
sense:

- **`lan/wsse_digest.dart`**'s `WsseDigest` — the shared WSSE-style SHA-1 digest construction
  used identically by `NuraeyeClient`'s REST login, every ONVIF SOAP client's
  `WS-UsernameToken` header, and `SnapshotClient`'s `Authorization` header. `WsseDigest.generate
  (password)` produces a fresh nonce/timestamp/digest triple; `WsseDigest.computeDigest(...)` lets
  a caller (e.g. `areYouNuraeyeDevice`) recompute a digest for a known nonce/timestamp to verify
  a server-supplied reply.
- **`lan/insecure_camera_http_client.dart`**'s `createCameraHttpClient()` — the shared
  `package:http`-compatible client factory every LAN ONVIF/NuraEye client (except
  `SnapshotClient`, which uses `dart:io` directly for the same header-case reason) uses under the
  hood. Trusts the camera's self-signed TLS certificate (deliberately narrow: only for camera LAN
  connections) and preserves outgoing HTTP header name case, which the camera's embedded server
  requires.

---

## Getting started

A minimal example: connect to a camera on the LAN, read its display name via ONVIF, and handle
the result.

```dart
import 'package:camera_api/camera_api.dart';

Future<void> main() async {
  final connection = CameraConnection(
    host: '192.168.1.50',
    username: 'admin',
    password: 'changeme',
  );

  final device = OnvifDeviceClient(connection);
  try {
    final result = await device.getDeviceIdentity();
    switch (result) {
      case CameraSuccess(:final value):
        print('Camera name: ${value.name}, location: ${value.location}');
      case CameraFailure(:final reason):
        print('Camera rejected the request: $reason');
      case CameraTimeout():
        print('Camera did not respond in time — check network/credentials.');
    }
  } finally {
    device.close();
  }
}
```

A WAN example additionally requires setting `WanAuth`'s hooks once at app startup, before any
WAN client is used:

```dart
void configureWan() {
  WanAuth.idTokenProvider = () => currentCognitoIdToken; // your own auth state — see auth_api
  // Still used, but only by KvsPlaybackClient (KVS/HLS playback) now — this project's real,
  // live deployed relay (VizenLinkKvsPlaybackProxy, confirmed live 2026-08-12). Overridable via
  // --dart-define=KVS_PLAYBACK_LAMBDA_URL=... if this Lambda is ever redeployed at a new
  // Function URL.
  WanAuth.kvsPlaybackLambdaUrl = 'https://jxce73jfkwoouhcmxvhsoysxxq0gavso.lambda-url.ap-south-1.on.aws/';
  // IotCommandClient talks directly to AWS IoT — needs real, temporary AWS credentials (not just
  // the ID token above) plus the IoT endpoint/region. See auth_api's AuthController.awsCredentials().
  WanAuth.awsCredentialsProvider = () async {
    final creds = await currentAwsCredentials(); // your own auth state — see auth_api
    return WanAwsCredentials(
      accessKeyId: creds.accessKeyId,
      secretKey: creds.secretKey,
      sessionToken: creds.sessionToken,
    );
  };
  WanAuth.awsIotEndpoint = 'a1zfm34z2p80an-ats.iot.ap-south-1.amazonaws.com'; // this project's real endpoint
  WanAuth.awsRegion = 'ap-south-1';
}

Future<void> readMirrorFlipOverWan(String thingName) async {
  final wan = WanMirrorFlipClient(thingName);
  final result = await wan.getMirrorFlip();
  switch (result) {
    case CameraSuccess(:final value):
      print('Mirror/flip mode: $value');
    case CameraFailure(:final reason):
      print('Rejected: $reason');
    case CameraTimeout():
      print('No response from camera over WAN.');
  }
}
```

Every client exposes a `close()` method (where it owns network resources) — call it when done
with a short-lived client instance, though most app code constructs clients per-call and lets
them be garbage-collected, since the expensive state (bearer sessions, resolved endpoints,
Options caches) is cached at the `static`/process level, not on the instance itself.
