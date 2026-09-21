# camera_api — Settings API Guide

`API_REFERENCE.md` is organized by **client class** — one section per Dart class, with its
methods, params, and return types. It has no concept of "camera setting" as a unit; a single
setting can be read/written through more than one client (LAN vs WAN, or occasionally more than
one LAN action), and `API_REFERENCE.md` won't tell you that up front.

This file is organized the other way: by **camera setting**. For each one it names the correct
LAN and WAN client/method pair, and — this is the part `API_REFERENCE.md` structurally can't
give you — explicitly separates it from other settings that sound alike or that expose a
similar-looking value. Use this file first when you know *which setting* you're implementing but
not yet *which client*; use `API_REFERENCE.md` once you know the client and need its exact
signature.

**Why this file exists:** Day/Night mode and Night Vision Type were confused with each other
during development — both are "night-related camera settings," both have a `grey`/`color`-ish
or `on`/`off`/`auto`-ish flavor to their values, and Day/Night mode alone is reachable through
two differently-named wire actions (ONVIF `IrCutFilter` and NuraEye `GetVideoMode`) that are
*not* obvious from either name alone as being the same underlying camera value. See that section
below for the actual resolution.

This is a **living reference** — add a section here whenever a new setting is wired up, not just
when a mix-up happens.

## How to read each entry

- **Concept** — what the setting actually controls on the camera, in plain language.
- **Not to be confused with** — other settings in this package whose name, values, or screen
  proximity make them easy to reach for by mistake.
- **LAN** — the client + method to call when connected on the same network as the camera.
- **WAN** — the client + method for the AWS IoT relay path, or "none" if no WAN path exists.
- **Notes** — caching behavior, wire-format quirks, or anything that would surprise you mid-way
  through wiring the call up.

For the general LAN-vs-WAN transport-selection algorithm (try LAN, fall back to WAN, when to
re-fetch Options) and the Options-caching convention, see
[.claude/rules/mobile-app-screen-conventions.md](../../../.claude/rules/mobile-app-screen-conventions.md) — this file cross-references
those rules per setting rather than repeating them.

---

## Day/Night Mode (IR Cut Filter)

**Concept:** whether the camera's IR-cut filter is forced on (day/color mode), forced off
(night/IR mode), or automatically switched based on ambient light (`AUTO`/`ON`/`OFF`). This is
the setting ONVIF calls `IrCutFilter`.

**Not to be confused with:** [Night Vision Type](#night-vision-type) — a completely separate
setting (grey/color/smart night-time rendering) that does not derive from or drive this one; see
that section for the full distinction. Also not to be confused with the *live effective* state
(is it day or night *right now*) versus the *configured* mode (`AUTO`/`ON`/`OFF`) — both are
read together but are different fields (see Notes).

**LAN:**
- Configured mode: `OnvifImagingClient.getImagingSettings()` → `ImagingSettings.irCutFilterMode`
  (`AUTO`/`ON`/`OFF`); set via `setImagingSettings(...)`.
- Live effective state (is it day or night right now): `NuraeyeClient.call('GetVideoMode')` →
  `effective_state` (bool, `true` = day).
- Options/choice list: `OnvifImagingClient.getImagingOptions()` →
  `ImagingOptions.irCutFilterModes`.

**WAN:** `WanImagingClient` — `getDayNightMode()` (configured mode, translated to the ONVIF
`ON`/`OFF`/`AUTO` vocabulary), `getEffectiveDayMode()` (live state), `getVideoModeStatus()`
(both in one round trip), `setDayNightMode(onvifMode)`. `getImagingOptions()` for the choice
list + WDR support flag.

**Notes:**
- ONVIF's `IrCutFilter` field and NuraEye's `GetVideoMode`/`SetVideoMode` action are **the same
  underlying camera concept exposed via two wire vocabularies** — NuraEye's wire values are
  lowercase `day`/`night`/`auto`; ONVIF's are `ON`/`OFF`/`AUTO`. `WanImagingClient` translates
  between them at its own boundary so app code only ever sees the ONVIF vocabulary regardless of
  transport. There is no case where you need both `OnvifImagingClient` and a raw `GetVideoMode`
  call for the *configured* mode — `GetVideoMode` is used on LAN specifically because it's the
  only place the *live effective* `day`/`night` state (not just the configured mode) is exposed;
  `OnvifImagingClient` has no effective-state field.
- `OnvifImagingClient.getImagingOptions()` is a stateless, always-live call as of 2026-08-28 — it
  no longer caches anything itself. The app layer caches it (`mobile_app/lib/features/settings/
  camera_settings_cache.dart`'s `NetworkAnswerCache`) — see the caching convention in
  `.claude/rules/mobile-app-screen-conventions.md`. `WanImagingClient.getImagingOptions()` is a
  separate class and keeps its own behavior (unaffected by this change).
- `ImagingOptions.irCutFilterModes` is the actual choice list for this mode — if it's empty,
  there's nothing valid to offer (see the
  [capability-flags table](#per-setting-options-response-capability-flags--not-the-same-idea-as-the-two-above)).

## Night Vision Type

**Concept:** how the camera renders video once it's in night mode — plain grey/IR (`grey`),
forced color at night (`color`), or an automatic choice between the two based on scene
conditions (`smart`).

**Not to be confused with:** [Day/Night Mode](#daynight-mode-ir-cut-filter) above. These are
independently configurable — a camera can be in `AUTO` day/night mode while its night-vision
rendering is set to `smart`, or `ON` (forced night) with `grey` rendering, in any combination.
Day/Night mode decides *whether* the IR-cut filter is engaged; Night Vision Type decides *how
the image looks* once it is. Nothing in either wire protocol links the two values together.

**LAN:** `NightVisionClient.getNightVisionType()` / `.setNightVisionType(type)` — implements the
shared `NightVisionSource` interface.

**WAN:** `WanNightVisionClient` — same method names, same `NightVisionSource` interface, so UI
code can hold either behind one reference type without branching on transport.

**Notes:** `NightVisionStatus` carries `colorCapable`/`smartCapable` hardware/firmware support
flags, returned embedded in the status response itself (no separate Options call needed) — gate
the UI's available choices on those, not on assuming all three types are always selectable. The
REST-generated surface (`GetCapabilitiesResponse.nightVisionColorCapable`/
`.nightVisionSmartCapable`, unused today) duplicates the same two flags — prefer
`NightVisionStatus`'s copy, it's the one actually wired into the app.

## WDR (Wide Dynamic Range)

**Concept:** whether the sensor's wide-dynamic-range compensation is enabled, and its strength
level — helps with strong backlight/high-contrast scenes. Bundled into the same ONVIF
`GetImagingSettings`/`GetImagingOptions` call as Day/Night mode, but is a separate field.

**Not to be confused with:** general [Image Quality](#image-quality) (brightness/contrast/
saturation/sharpness) — WDR is a distinct sensor-level compensation mode, not one of the
standard ISP quality sliders, even though both live under "Imaging."

**LAN:** `OnvifImagingClient.getImagingSettings()`/`setImagingSettings()` (WDR fields), options
via `getImagingOptions()` → `ImagingOptions.wdrSupported`.

**WAN:** `WanImagingClient.getWdr()`/`setWdr(enabled, level)`.

**Notes:** `ImagingOptions.wdrSupported == false` means the WDR element was entirely absent from
the response (non-HDR sensor) — hide the control outright, don't just disable it. WDR support
must be read from `getImagingOptions()`'s own `wdrSupported` flag, never inferred from whether
`GetImagingSettings` happens to include the field. See
[Per-setting Options-response capability flags](#per-setting-options-response-capability-flags--not-the-same-idea-as-the-two-above)
for the WAN mirror of this same flag.

**Also the HDR/Linear sensor capture-mode switch (`FR-CF-147`).** On the two HDR-capable
sensors (IMX662, GC4663), the WDR On/Off field this section already covers **is** the sensor
capture-mode switch — not a separate control. The sensor's own dual-exposure readout
(`init_hdr_mode`) is boot-time-only with no live re-init path, so an actual WDR On<->Off
transition reboots the camera to take effect; the health-monitor task detects the
booted-vs-persisted mismatch and triggers the reboot (not the request path itself). WDR
*Level* is unaffected by this — it's still a pure runtime blend-strength control within
whichever mode is active. **UI must confirm before toggling WDR on a camera where
`wdrSupported` is true** — it may trigger a reboot, briefly interrupting live view/recording.
Mirrors the deterrence confirmation-gate pattern (`FR-MOB-105`). See
`imaging_settings_screen.dart`'s `_WdrCard` for the reference implementation.

## Image Quality

**Concept:** the standard ISP sliders — brightness, saturation, contrast, sharpness, exposure
mode/time/gain, white-balance mode.

**Not to be confused with:** [Image Defaults](#image-defaults-factory-reset-values) — the
factory-default *values* for these same fields, a read-only reference used for a "Reset to
Default" action, not the current live settings.

**LAN:** `OnvifImagingClient.getImagingSettings()`/`setImagingSettings()` (the non-Day/Night,
non-WDR fields), options via `getImagingOptions()`.

**WAN:** `WanImageQualityClient` — `getImageSettings()`/`setImageSettings(params)` (raw JSON
maps, not a typed struct), `getImageSettingsOptions()`.

## Image Defaults (factory-reset values)

**Concept:** the camera's factory-default values for the Image Quality fields above — read-only,
used to populate a "Reset to Default" action. Not itself a setting you can change.

**Not to be confused with:** [Image Quality](#image-quality) — the current, mutable values.

**LAN:** `NuraeyeClient.call('GetImageDefaults')`, or the generated `RestVideoImageClient` if
using the OpenAPI-generated surface directly.

**WAN:** `WanImageQualityClient.getImageDefaults()`.

## Mirror/Flip

**Concept:** horizontal mirror / vertical flip of the video output — `off`/`mirror`/`flip`/
`both`. This is a NuraEye-only setting; there is no ONVIF `MirrorFlipMode` concept on this
firmware (removed 2026-07-27, `FR-CF-129`/`FR-NE-039`) — don't look for or add an ONVIF Options
call for it, there is no camera-reported choice list to derive it from.

**LAN:** `MirrorFlipClient.getMirrorFlip()`/`.setMirrorFlip(mode)` (hand-written — prefer this
over the generated `RestVideoImageClient`, which hits the identical `/nuraeye/video/mirror-flip`
endpoint but exists only as unused reserve API surface, see
[Hand-written vs. generated REST clients](#hand-written-vs-generated-rest-clients) below).

**WAN:** `WanMirrorFlipClient` — same `MirrorFlipMode` enum, same method names.

## Anti-Flicker / Power-Line Frequency

**Concept:** eliminates video banding/flicker caused by artificial (mains-powered) lighting —
`50Hz`/`60Hz`/`Auto`. This is a NuraEye-only setting; there is no ONVIF-standard element for it
on any camera, not just this firmware — checked against the live `ImagingSettings20` schema and
confirmed no such field exists anywhere in it, including its Extension chain (see
`kb/raw/2026-08-12-feature-antiflicker-mode.md`). Same situation as [Mirror/Flip](#mirrorflip)
above — don't look for or add an ONVIF Options call for it.

**LAN:** `AntiFlickerClient.getAntiFlickerMode()`/`.setAntiFlickerMode(mode)` — REST-only, no
legacy `/nuraeye` JSON-RPC action exists for this setting (built REST-only from day one).

**WAN:** `WanAntiFlickerClient` — same `AntiFlickerMode` enum, same method names.

## Privacy Mode

**Concept:** a device-wide capture state — `none` (normal), `zone` (blank out configured mask
zones), `full` (stop all capture).

**Not to be confused with:** [Privacy Masks](#privacy-masks) — the actual rectangle zones that
`zone` mode blanks out. Privacy Mode is the on/off/which-scope switch; Privacy Masks is the
geometry it operates on. Setting Privacy Mode to `zone` with no masks configured is a valid but
probably-unintended no-op.

**LAN:** `PrivacyModeClient.getPrivacyMode()`/`.setPrivacyMode(mode)` (hand-written — prefer over
the generated `RestPrivacyClient`, same endpoint, see
[Hand-written vs. generated REST clients](#hand-written-vs-generated-rest-clients)).

**WAN:** `WanPrivacyModeClient` — same `PrivacyMode` enum.

## Privacy Masks

**Concept:** the actual rectangular zones (position, enabled flag, type, color) that Privacy
Mode's `zone` setting blanks out. Managed via ONVIF Media2 mask primitives
(`CreateMask`/`SetMask`/`DeleteMask`/`GetMasks`).

**Not to be confused with:** [Privacy Mode](#privacy-mode) above — the switch, not the geometry.
Also not to be confused with [OSD](#osd-on-screen-display) — both are Media2 "draw something on
the video" primitives with a similar create/set/delete/options shape, but OSD draws
timestamp/text overlays, masks draw opaque privacy rectangles; they are unrelated ONVIF
resources with separate token spaces.

**LAN:** `MaskClient` — `getMasks()`, `createMask(...)`/`setMask(...)`/`deleteMask(token)`,
`getMaskOptions()`.

**WAN:** `WanMaskClient` — same `MaskEntry`/`MaskColor`/`MaskOptions`/`OnvifPoint` types as LAN,
so app code doesn't need transport-specific geometry conversion.

**Notes:** `MaskClient.getMaskOptions()` is a stateless, always-live call as of 2026-08-28 — it no
longer caches anything itself (`WanMaskClient.getMaskOptions()` is a separate class, unaffected).
The app layer caches it instead (`NetworkAnswerCache`) — see
`.claude/rules/mobile-app-screen-conventions.md`'s caching convention; this is the setting that
originally motivated that rule (redundant re-fetches were starving the camera's RTSP pipeline).
`MaskEntry.type` only `"Color"` actually renders on this firmware — gate UI on
`MaskOptions.types`, don't assume all ONVIF-advertised types work. Two more gates apply before
even reaching `MaskOptions`: `Media2CapabilitiesClient.getServiceCapabilities().maskSupported`
(does this camera build advertise masks at all) and, within `MaskOptions` itself,
`rectangleOnly`/`singleColorOnly` (shape/color-picker freedom) plus `maxMasks == 0` as the
fallback-value signal for "not supported" — see the
[capability-flags table](#per-setting-options-response-capability-flags--not-the-same-idea-as-the-two-above).

## OSD (On-Screen Display)

**Concept:** timestamp overlay and free-text overlay burned into the video. ONVIF Media2
(`GetOSDs`/`CreateOSD`/`SetOSD`/`DeleteOSD`/`GetOSDOptions`), two fixed slots (`DateAndTime`,
`Plain`).

**Not to be confused with:** [Privacy Masks](#privacy-masks) — see that section's note; same
ONVIF Media2 shape, unrelated resource.

**LAN:** `OsdClient` — `getOsds()`, `createTimestampOsd(...)`/`createTextOsd(...)`/
`updateTextOsd(...)`/`updateTimestampPosition(...)`/`deleteOsd(token)`, `getOsdOptions()`.

**WAN:** `WanOsdClient` — `setOsd(...)` unifies create/update behind one method (empty/omitted
`token` creates, non-empty updates), otherwise mirrors the LAN shape.

**Notes:** neither transport is hardware-verified against a real camera as of this writing — no
`testing_utilities/*.py` reference script exists for OSD; wire format was matched directly
against firmware source. Treat with extra suspicion if a bug report touches OSD. Two capability
gates apply: `Media2CapabilitiesClient.getServiceCapabilities().osdSupported` (device-wide), and
within `OsdOptions`, `fontColorRangeAvailable` — whether the camera reports a continuous RGB
range (slider UI) vs. only a discrete `fontColors` list; checking `fontColors.isNotEmpty` alone
previously left the color picker never rendering on builds that only advertise the range. See
the [capability-flags table](#per-setting-options-response-capability-flags--not-the-same-idea-as-the-two-above).

## Video Encoder Settings (any stream — High/Medium/Low)

**Concept:** bitrate, frame rate, GOV length, quality, encoder profile, resolution, codec
(H264/H265), CBR/VBR — for **any** of the camera's streams (today: High/`Profile_1`/
`VideoEncoderCfg_1`, Medium/`Profile_2`/`VideoEncoderCfg_2`, Low/`Profile_3`/`VideoEncoderCfg_3`).
ONVIF Media2 (`GetProfiles`/`GetVideoEncoderConfigurations`/`SetVideoEncoderConfiguration`/
`GetVideoEncoderConfigurationOptions`). **Originally scoped to the high-resolution stream only**;
generalized 2026-09-10, direct user request, to a `configToken` parameter on every method — call
`OnvifVideoEncoderClient.getProfiles()` first to discover the real stream list/tokens rather than
hardcoding a count, then pass each profile's `videoEncoderConfigToken` through.

**Not to be confused with:** the older, narrower WAN-only `SetStreamQuality`/`GetStreamQuality`/
`GetOptions` firmware command set (`FR-NE-069`), which stays hardcoded to `VideoEncoderCfg_2` and
never accepts a resolution — no mobile-app screen uses it; don't wire a "video quality" control to
it when `WanVideoEncoderClient` (now covering every stream) is what's actually meant.

**LAN:** `OnvifVideoEncoderClient` — `getProfiles()` (stream discovery), `getVideoEncoderSettings
(configToken: ...)`, `setVideoEncoderSettings(...)` (always sends the full config, no
partial-update mode; targets `settings.token`), `getVideoEncoderSettingsOptions(configToken: ...)`.

**WAN:** `WanVideoEncoderClient` — same method names, same `configToken` parameter (sent as the
WAN command's `config_token` field, mirrored firmware-side); `getVideoEncoderSettingsOptions()`
should only ever be called as WAN-Set-failure recovery, never on a normal load — see
[.claude/rules/mobile-app-screen-conventions.md](../../../.claude/rules/mobile-app-screen-conventions.md) § "LAN/WAN transport
selection."

**Notes:** `VideoEncoderSettingsOptions.resolutions` must be read from the live Options response
(`resolutions.length <= 1` decides label-vs-dropdown at render time) — never hardcode a fixed
resolution count per stream. Today the High stream can report **two** resolutions on
`SENSOR_CFG_GC4653`/`SENSOR_CFG_GC4663` builds (native ~4MP 2560×1440 plus a ~2MP 1920×1080
option, `onvif_user_config.c`'s `HIGH_RESOLUTION_STREAM_OPTION_COUNT`); Medium and Low each report
exactly one — the `resolutions.length <= 1` dropdown-vs-label logic handles both cases with no
app-side code change, since it was always written generically rather than assuming one. `mobile_app`'s
`VideoEncoderSettingsScreen` is the reference implementation for a multi-stream tabbed UI built on
this client — one tab per `getProfiles()` result, each an independent `SettingCard` instance
addressing its own `configToken`. Separately, each `EncodingOptions.supportsCbr` is a
**per-encoding** flag (H264 and H265 can report differently) — the CBR/VBR toggle is only editable
when the *currently selected* encoding's own flag is `true`, not a single device-wide bool; see the
[capability-flags table](#per-setting-options-response-capability-flags--not-the-same-idea-as-the-two-above).

## Device Identity (Name / Location / Time Zone / Password)

**Concept:** the camera's display name and location labels (ONVIF `Scopes`), its time zone, and
its single local device account password (shared by ONVIF + NuraEye login).

**LAN:** `OnvifDeviceClient` — `getDeviceIdentity()`, `setDeviceName(name)`/
`setDeviceLocation(location)` (independent calls — name and location are set separately),
`getSystemDateAndTime()`/`setTimeZone(tz)`, `setUserPassword(username, newPassword)`.

**WAN:** `WanDeviceIdentityClient` — `getDeviceIdentity()` (all three fields combined in one
read), `setDeviceName`/`setDeviceLocation`/`setTimeZone`/`setUserPassword`, structurally matching
signatures (not a formal shared interface).

**Notes:** the time-zone *catalog* to pick from (`TimezoneOption` list) is a **separate,
NuraEye-only** call — `NetworkInfoClient.getSupportedTimezones()` — even though the *setting* of
time zone itself is an ONVIF action (`OnvifDeviceClient.setTimeZone`/
`WanDeviceIdentityClient.setTimeZone`). `TimezoneOption.code` is the string to pass to the
ONVIF/WAN setter. On either transport, **the caller must update its own stored
`CameraConnection.password` after a successful `setUserPassword`** — the client that made the
call keeps using the old password it was constructed with.

## Device Information (read-only)

**Concept:** the camera's fixed build/hardware identity — manufacturer, model, firmware
version, serial number, hardware ID (ONVIF `GetDeviceInformation`). Read-only, no setter.

**Not to be confused with:** [Device Identity](#device-identity-name--location--time-zone--password)'s
name/location/time zone — those are user-configurable; this is fixed per-unit/build data.

**LAN:** `OnvifDeviceClient.getDeviceInformation()`.

**WAN:** `WanDeviceIdentityClient.getDeviceInfo()` (`FR-NE-115`, added 2026-08-21) — returns the
same `DeviceInformation` type as the LAN client.

**Notes:** `CameraInfoScreen`'s "Device Information" card shows the cached value instantly
(`CachedCameraSettings`, warmed at onboarding) and only makes a live call on a cache miss —
same convention as every other read-only card in this guide.

## Device Reboot / Factory Reset

**Concept:** rebooting the camera on demand (ONVIF `SystemReboot`), and resetting it to factory
defaults at one of two levels (ONVIF `SetSystemFactoryDefault`):
- **Soft** — erases camera settings (ONVIF user config: imaging, masks, OSD, camera name/
  location, etc.) only. Network config (WiFi credentials, DHCP preferred IP) is preserved, so
  the device stays reachable at its existing address after it reboots.
- **Hard** — erases camera settings **and** network config. The device re-enters AP
  provisioning mode on reboot and must be fully re-onboarded (WiFi credentials re-entered,
  discovery/manual add repeated) before it's reachable again.

Unlike most entries in this guide, both actions are **real, standard ONVIF Device service
actions** with a full LAN path — this isn't a NuraEye-only setting. The WAN command set exists
purely because ONVIF SOAP has no WAN transport in this stack at all (same reasoning as
[Device Identity](#device-identity-name--location--time-zone--password)'s WAN mirror), not
because the setting itself needed inventing.

**Not to be confused with:** [Image Defaults](#image-defaults-factory-reset-values) — that's a
read-only *ISP value* lookup for one "Reset to Default" slider control, not a device-wide reset.

**LAN:** `OnvifDeviceClient` — `reboot()` (returns the camera's `tt:Message`, typically
`"Rebooting in 5 seconds"`), `factoryReset(FactoryResetMode mode)`.

**WAN:** `WanDeviceIdentityClient` — `reboot()`, `factoryReset(FactoryResetMode mode)`, same
signatures as the LAN client.

**Notes:** a success response from either method does **not** mean the device is back yet — both
actions trigger `bsp_rebootAsync()` (~5s async delay before the actual reset), so callers must
expect a real connectivity gap afterward, not just an instant confirm. Neither method has an
Options/capability query — there's nothing to bound, both take a fixed enum or no params at all.
**UI: `_DeviceManagementCard` in `camera_info_screen.dart`** (`FR-MOB-103`) — a "Device
Management" card with two rows, each behind its own confirmation flow: Reboot shows one
plain-language confirmation dialog; Factory Reset first asks the user to pick Soft or Hard (a
`SimpleDialog` with per-mode explanatory subtitles), then shows a second, destructive-styled
confirmation whose wording matches whichever mode was picked. On a successful Hard reset the
screen pops itself — the network config the app just used to reach the camera no longer exists,
so nothing else on the screen can succeed until it's re-onboarded; Soft reset and Reboot instead
show a result dialog and leave the user on the screen, since the camera stays reachable at the
same address. A Hard reset issued over WAN is also the one path that severs the app's own
ability to reach the camera again over WAN, since it wipes the WiFi credentials that WAN
connectivity itself was reached through — recovery requires re-onboarding on LAN.

## Event Preferences

**Concept:** whether the camera generates a given event *type* at all, device-wide
(`FR-CF-143`, `FR-NE-111`) — a per-camera on/off switch per event type
(`"VideoModeChanged"`/`"PrivacyModeChanged"`/`"PersonDetected"` today), not a per-detection-rule
setting.

**Not to be confused with:** the per-analytics-rule `mobile_notifications`/`buzzer_activation`
flags reachable via `NuraeyeClient.call('...alert-rules...')` (no dedicated `camera_api` client
exists for those yet) — that's a different, pre-existing concept: what *action* a specific
detection *rule* triggers when it fires, not whether an event *type* is generated at all. A
"mute" request from a user is almost always this section, not that one. (Both are slated to be
superseded by `FR-CF-144`/`FR-NE-112`'s generalized per-event response-action set once built —
not yet implemented, see that FR's `Planned` status.)

**A real, device-side suppression, not a client-side mute.** Disabling a type here stops the
camera from generating it at the source (`EventMgr_Send()`), on **every** delivery path it has
— this app's own MQTT feed, and ONVIF PullPoint (third-party NVR/VMS clients too), per direct
user decision. There is deliberately no separate "client-side mute" concept layered on top of
this: an earlier draft of this feature considered one (log the event, but suppress only this
app's own push notification), but that was dropped as redundant once `FR-CF-144`'s `mobile_alert`
response action was scoped — an event with `mobile_alert` unselected already means "log it,
don't push a notification for it," with no additional toggle needed.

**LAN:** `EventPreferencesClient` — `getEventPreferences()`, `setEventPreferences(Map<String,
bool> changes)` (partial update — only the keys present in `changes` change).

**WAN:** `WanEventPreferencesClient` — same method names and partial-update semantics.

**Notes:** the list of event types to show toggles for comes from
`CapabilitiesClient.getCapabilities().supportedEventTypes`
([Capabilities](#capabilities-discovery-not-a-setting)), never a hardcoded list — a future
firmware build that adds a real producer for e.g. tamper detection needs zero `camera_api`
changes, the new type just appears in that array. An unrecognized key in `setEventPreferences`
is a `CameraFailure` (the camera rejects the whole request with `HTTP 400` rather than applying
a partial subset) — don't send a key that isn't currently in `supportedEventTypes`.

## Response Actions (Deterrence-on-Event)

**Concept:** for **detection-type events only** (`"PersonDetected"` today — never state-change
events like `"VideoModeChanged"`/`"PrivacyModeChanged"`), which automatic response actions
(`siren`, `spotlight`, `warning`, `mobile_alert`) fire when that event triggers
(`FR-CF-144`, `FR-NE-112`). A per-event-type multi-select, not a single choice — an event can
have zero, one, or several response actions selected at once.

**Not to be confused with:**
- `EventPreferencesClient` (above) — that controls whether the event is generated **at all**;
  this controls what happens *in addition* once an already-enabled detection event fires. An
  event with every response action unselected still generates normally (still logged, still
  delivered to alert history) — it just doesn't trigger anything extra.
- The per-detection-rule `mobile_notifications`/`buzzer_activation` toggles
  (`NuraeyeClient.call('...alert-rules...')`) — a narrower, pre-existing concept this
  generalizes for the event types it covers.
- The manual, on-demand `ActivateDeterrence`/`DeactivateDeterrence`/`GetDeterrenceStatus`
  actions (`DeterrenceClient`, see [Deterrence — Manual Trigger & Auto-Stop
  Duration](#deterrence--manual-trigger--auto-stop-duration) below) — those are a human pressing
  a button in Live View to fire an action right now; this is the camera auto-firing an action
  because a detection event just happened. **Both share the exact same configured auto-stop
  duration** (`FR-NE-113`, `FEAT-236`) — there is no separate "automatic" vs. "manual" duration
  value anymore.

**`mobile_alert` has no device-side effect at all.** Selecting/unselecting it never changes
whether the camera delivers the event — that's `EventPreferencesClient`'s job alone, and stays
true regardless of this setting. It exists purely so the app can read, locally, whether an
incoming alert for a given event type should also surface a system push notification. If a
future need arises for "log this event, but never push a notification for it," this is already
that mechanism — there's no separate client-side mute concept layered on top of it.

**LAN:** `EventResponseActionsClient` — `getEventResponseActions()`,
`setEventResponseActions(Map<String, List<String>> changes)` (partial update — only the event
types present in `changes` change; each key's array fully **replaces** that event type's action
set, not additive).

**WAN:** `WanEventResponseActionsClient` — same method names and partial-update semantics.

**Notes:** the map of event types to response-action choices comes from
`CapabilitiesClient.getCapabilities().supportedEventDeterrenceOptions`
([Capabilities](#capabilities-discovery-not-a-setting)), never a hardcoded list — and it's
already the intersection of this SKU's hardware capability (no `siren` option offered on a
build without a buzzer) with which event types are even eligible for a response action at all
(state-change events are simply absent as keys, not present with an empty array). Sending an
action not present in that event type's eligible list is a `CameraFailure` (`HTTP 400`, whole
request rejected).

## Loitering Detection & Duration

**Concept:** `"Loitering"` is its own event type (`FR-CF-150`, wire name `"Loitering"`), enabled/
disabled via [Event Preferences](#event-preferences) the same as `"PersonDetected"`. On top of
that, `LoiteringDurationClient` configures the dwell threshold, in whole seconds, a tracked
object must stay present before the camera fires that event.

**Not to be confused with:** the deterrence auto-stop duration
([Deterrence — Manual Trigger & Auto-Stop Duration](#deterrence--manual-trigger--auto-stop-duration))
— that's how long a physical siren/spotlight/warning runs once triggered; this is how long an
object must be *present in frame* before loitering is even detected. Two different durations,
two different clients.

**Runs off the same NN pipeline as `"PersonDetected"` — not an independent detector.** Firmware
keeps the NN pipeline live whenever *either* `"PersonDetected"` or `"Loitering"` is enabled
(fixed 2026-08-26 — previously only `"PersonDetected"`'s toggle gated the pipeline, so disabling
it while leaving `"Loitering"` enabled silently broke loitering detection too, since it has no
independent producer). The app doesn't need to do anything special about this — just don't
assume Loitering keeps working while showing `"PersonDetected"` as off; both toggles genuinely
matter to the user in that combination.

**LAN:** `LoiteringDurationClient` — `getLoiteringDuration()`, `setLoiteringDuration(int
seconds)`.

**WAN:** `WanLoiteringDurationClient` — same method names.

**Notes:** bounds come from `CameraCapabilities.loiteringDurationMinSeconds`/`MaxSeconds`
([Capabilities](#capabilities-discovery-not-a-setting)) — fixed compile-time bounds, not
per-value camera-reported, so there's no separate Options command (same shape as [Recordings](#recordings-browse--playback-not-a-settings-toggle)'
clip-duration setting). A value outside that range is a `CameraFailure` (`HTTP 400`). Wired into
`EventSettingsScreen`'s `"Loitering"` card as an inline mm/ss label + `-`/`+` stepper-flanked
slider (`_LoiteringDurationField`, restyled 2026-08-26 to match `recordings_screen.dart`'s
`_ClipDurationDialog` per direct user request), following this screen's usual
pending/applied/Apply pattern — not a separate screen.

## Detection Bounding-Box Overlay

**Concept:** whether the camera draws the AI object-detection bounding box (OSD burn-in) on the
video stream (`FR-CF-151`). A pure display setting — independent of whether detection/alerts
are running at all.

**Not to be confused with:** [Event Preferences](#event-preferences)/`"PersonDetected"` — that
controls whether detection runs and events fire; this only controls whether a box is visibly
drawn on the video everyone watches/records. `PersonDetected`/`Loitering` events keep firing and
carrying `bbox` (a fraction of the sensor frame) in their payload regardless of this toggle — a
mobile-app client wanting to draw its own box in its own UI reads that payload field directly,
it does not depend on this camera-side overlay setting at all.

**LAN:** `BboxOverlayClient` — `isBboxOverlayEnabled()`, `setBboxOverlayEnabled(bool enabled)`.

**WAN:** `WanBboxOverlayClient` — same method names.

**Notes:** gated on `CameraCapabilities.bboxOverlayCapable`
([Capabilities](#capabilities-discovery-not-a-setting)) — `false` on a build without
`AI_DETECTIONS` compiled in, where there's no detection pipeline to draw an overlay for. Wired
into `EventSettingsScreen`'s `"PersonDetected"` card as an inline switch (revealed when that
card's own toggle is on), following this screen's usual pending/applied/Apply pattern — not a
separate screen.

## Audio — Mic Gain / Recording Toggle / Test Tone

**Concept:** microphone input gain level, whether the mic is actively capturing at all (distinct
from gain), and speaker test-tone playback control.

**Not to be confused with:** [Speaker Volume](#speaker-volume-output) — the camera's *output*
level, a separate ONVIF-only setting with no relation to mic gain beyond both involving audio
hardware.

**LAN:** `AudioVolumeClient` — `getMicGain()`/`setMicGain(gain)`,
`isAudioRecordingEnabled()`/`setAudioRecordingEnabled(enabled)`,
`playTestSound()`/`stopTestSound()`/`isTestSoundPlaying()`.

**WAN:** `WanAudioVolumeClient` — same method set. `isAudioRecordingEnabled`/
`setAudioRecordingEnabled` were undocumented-as-WAN-capable and unwired in the app until
2026-08-11 even though the firmware command (`FR-NE-078`) had been hardware-verified since
2026-07-28 — a reminder to check the firmware FR's `Status` before assuming a WAN gap is real.

**Notes:** gate every method in this section on `AudioCapabilityClient.getAudioCapability()
.hasMicrophone` — a camera build with no microphone hardware has nothing meaningful to return
here.

## Speaker Volume (output)

**Concept:** the camera's speaker output level (0-100) — ONVIF Media2
(`GetAudioOutputConfigurations`/`SetAudioOutputConfiguration`), distinct from the phone's own
local volume and from [mic gain](#audio--mic-gain--recording-toggle--test-tone).

**LAN:** `SpeakerVolumeClient.getSpeakerVolume()`/`.setSpeakerVolume(current)` — pass a
`SpeakerVolume` built via `.withLevel(newLevel)` on a previously-loaded value; ONVIF requires the
sibling token/name/outputToken fields resent on every set.

**WAN:** `WanSpeakerVolumeClient` — returns/accepts a bare `int`, not the ONVIF-shaped
`SpeakerVolume` struct (no sibling fields to echo over the WAN command).

**Notes:** `getSpeakerVolume` returns `CameraFailure` if the camera has no
`AudioOutputConfiguration` at all — UI should gate on `AudioCapabilityClient.hasSpeaker` before
calling either transport's getter.

## Two-Way Talk

**Concept:** full-duplex voice between phone and camera — phone mic → camera speaker and camera
mic → phone, AAC-LC 8000 Hz both ways. Not a setting toggle; a live call-style session. Runs over
a **dedicated audio-only RTSPS module** on the camera (`module_rtsps_talk.c`, port 560), a
connection completely separate from live view.

**Not to be confused with:** [mic gain](#audio--mic-gain--recording-toggle--test-tone) /
[speaker volume](#speaker-volume-output) (those adjust levels for a talk call and are surfaced
on the in-call panel); the [audio-recording toggle](#audio--mic-gain--recording-toggle--test-tone)
(`FR-CF-024` — the camera force-activates its mic for the talk return leg regardless, and
converges back to the toggle's value on teardown).

**LAN:** `TalkUriClient.getTalkUri()` → `POST /nuraeye/talk-uri` resolves
`TalkTarget { port, mediaUri }` (`mediaUri` always `rtsps://<ip>:560/talk`). The app then opens
that RTSPS session itself (`RtspTalkSession`, in `mobile_app/lib/features/live_view/rtsp/`) —
`OPTIONS`/`DESCRIBE`/`SETUP×2`/`RECORD`, `$`-framed AAC RTP. See
[TWO_WAY_TALK_GUIDE.md](TWO_WAY_TALK_GUIDE.md).

**WAN:** none — `FR-NE-081` ("Two-Way Talk WAN Relay") is `Status: Planned`. Gate the talk
control on LAN connectivity.

**Notes:** offer the control only when `AudioCapabilityClient.getAudioCapability().hasSpeaker` is
true (`FR-MOB-082`, hide-don't-disable). Exclusivity (`FR-CF-131`): one talker per camera — a
second attempt is rejected at `RECORD` with a non-200 status, surfaced as "someone else is
currently talking" (no push for when the slot frees; retry-based). Replaced the former WebRTC
`{"talk": true}` signaling path (removed 2026-09-11).

## Snapshot / Preview Image

**Concept:** a still-image capture. There are **three different mechanisms** depending on
transport and purpose — pick by scenario, not by "which one did I use last time."

| Scenario | Client | Notes |
|---|---|---|
| LAN, user-facing capture or click-to-draw backdrop | `SnapshotClient.getSnapshot()` | `GET /snapshot`; `profile: 'high'` for a real capture, `'medium'` for a lightweight mask/OSD editor backdrop. |
| WAN, transient settings-screen backdrop | `WanPreviewSnapshotClient.getPreviewSnapshot()` | End-to-end encrypted (AES-256-GCM under a camera-generated shared key); **caller must not persist the returned bytes** — no gallery save, no cache file. Requires the shared key already fetched (open a settings screen on LAN once first — `RestStreamingClient.getPreviewKey()`, redesigned 2026-08-21 from a per-app pushed RSA key so re-adding this camera on a second device doesn't lock the first one out). |
| WAN, live video | `WanLiveViewClient.startMediaSession()` | Not a snapshot — starts a live `KvsMediaLiveViewSession` (direct `GetMedia`, local loopback URL) after `startCloudStreaming()` confirms active. See [Cloud Streaming](#cloud-streaming-wan-live-view) below. |

## Cloud Streaming (WAN live view)

**Concept:** starting/stopping the KVS push for WAN live view, and checking its status.

**Not to be confused with:** the [WAN Preview Snapshot](#snapshot--preview-image) mechanism — a
single encrypted still frame for a settings-screen backdrop, not video streaming.

**LAN:** `CloudStreamingLanClient` — `getCloudStreamingStatus()`, `stopCloudStreaming()` only
(no LAN `start` — starting cloud streaming only makes sense for a WAN-bound client). Used
opportunistically once LAN reachability is confirmed, to avoid an unnecessary AWS/Lambda round
trip when stopping.

**WAN:** `WanLiveViewClient`/`AwsWanLiveViewClient` — `startCloudStreaming(quality)`/
`stopCloudStreaming(token)`/`getCloudStreamingStatus(token)`/`startMediaSession(quality)`
(**replaces `resolvePlaybackUri`, 2026-09-17** — returns a live `KvsMediaLiveViewSession` the
caller must `stop()` when done, not a static URL).
**`FR-CF-154` (2026-09-14): quality-selective and reference-counted** — `quality` is a
`StreamQuality` (`high`/`medium`/`low`, one per real AWS KVS stream, each independently billed);
`startCloudStreaming` returns a per-viewer lease token, which `getCloudStreamingStatus` also
refreshes (the heartbeat — call it at least every 30s or the camera drops the lease). See
[STREAMING_GUIDE.md](STREAMING_GUIDE.md) §3 for the full sequence.

**Never call `startCloudStreaming`/`startMediaSession` just to check reachability or enable a UI
element** — direct user hardware report 2026-09-18: each KVS stream is a real, individually-
billed AWS resource, so calling this from a screen's silent "ping the camera" path (opened, app
resumed, network reconnected) bills real cloud usage the user never asked for. `mobile_app`'s own
`LiveViewController` had exactly this bug (fixed via `start({bool allowWan})`, gating every eager
call site to `allowWan: false` and reserving `allowWan: true` for an explicit user action) — see
`API_REFERENCE.md`'s `WanLiveViewClient` usage note for the full story. Any new WAN live-view
caller should follow the same split.

## WiFi

**Concept:** the configured WiFi SSID, live signal strength, and setting new credentials.
NuraEye-only, no ONVIF equivalent.

**LAN:** `NetworkInfoClient` — `getWifiSsid()`, `setupWifi(ssid, psk, {verify})`,
`getWifiSignalStrength()`.

**WAN:** none — WiFi is inherently a LAN-adjacent, physically-local operation.

**Notes:** `getWifiSsid()`/`getWifiSignalStrength()` are only meaningful when the camera's active
interface is actually wireless — check `OnvifDeviceClient.getNetworkInterfaceInfo().isWireless`
first; on a wired (Ethernet) camera these return stale/meaningless data rather than a clean
failure, since the underlying firmware config always holds a WiFi entry even when it isn't the
active interface. `setupWifi`'s `verify: true` (default) is itself overridden by firmware
behavior — it always forces save-only when currently reached over Ethernet, regardless of what
the app passes.

## Deterrence — Manual Trigger & Auto-Stop Duration

**Concept:** two related settings, per `FEAT-236` (2026-08-14, revised 2026-08-15 after
real-hardware testing — see the note at the bottom of this section):
- **Manual trigger** (`FR-NE-082`/`083`) — a human activating siren/spotlight/warning right now,
  from Live View, independent of any detection event.
- **Auto-stop configuration** (`FR-NE-113`) — how long/how many times each action
  (siren/spotlight/warning) runs before stopping on its own. **One configured value per action,
  shared by both this manual trigger and the automatic detection-triggered response** ([Response
  Actions](#response-actions-deterrence-on-event) above) — not a per-request or
  per-trigger-path setting. `ActivateDeterrence`'s request carries **no duration parameter at
  all** — the camera always applies its own persisted value.

**Mixed units — `warning` is a repeat count, not seconds.** `siren_seconds`/`spotlight_seconds`
are whole seconds; `warning_repeat_count` (renamed from `warning_seconds`, 2026-08-15) is how
many times the clip plays before stopping, not a duration. `warning` loops internally
(completion-driven — see the note below), rather than playing once and self-terminating on the
clip's own length (the pre-`FEAT-236` behavior, when `warning` had no auto-stop concept at all).

**Bounds come from the camera, never hardcode a range.** `getDeterrenceDurationOptions()` reports
the real `min`/`max` per key — build slider/stepper bounds from this response, same "every Set
has a matching Options, UI built from it" rule this repo already applies to every other setting.
An earlier version of this feature hardcoded a 0-60s UI range instead, found and corrected via
real-hardware testing (a value of `0` degenerates to "never really activates").

**Not to be confused with:** [Response Actions](#response-actions-deterrence-on-event) above —
that decides *which* actions auto-fire on a detection event; this decides *how long/how many
times* an action (fired either way) runs, and gives the user a way to fire one directly.

**LAN:** `DeterrenceClient` — `getDeterrenceStatus()`, `activateDeterrence(String action)`,
`deactivateDeterrence(String action)`, `getDeterrenceDurations()` →
`Map<String, int>` (`siren_seconds`/`spotlight_seconds`/`warning_repeat_count`),
`setDeterrenceDurations(Map<String, int> changes)` (partial update),
`getDeterrenceDurationOptions()` → `DeterrenceDurationOptions` (per-key `min`/`max`).

**WAN:** `WanDeterrenceClient` — same method names and semantics.

**Notes:** gate the manual-trigger controls and duration section on
`CapabilitiesClient.getCapabilities().sirenCapable`/`spotlightCapable`/`warningCapable`
([Capabilities](#capabilities-discovery-not-a-setting)) — never a hardcoded action list, and
**never gated on any event type's own enable/disable toggle**: manual triggering doesn't depend
on detection being enabled at all, unlike the per-event Response Actions cards. Reference
implementation: `mobile_app/lib/features/live_view/live_view_screen.dart` (`_ControlsBar`'s
deterrence row, manual trigger, plus a periodic `GetDeterrenceStatus` poll while an action is
active — added 2026-08-15, real-hardware finding: without it, the control kept showing "active"
forever after the camera's own auto-stop fired, since nothing re-checked status) and
`mobile_app/lib/features/alerts/event_settings_screen.dart` (the Deterrence section — a slider
per second-based action, a `+`/`-` stepper for `warning_repeat_count`).

**Real-hardware finding, 2026-08-15 — do not reintroduce a duration-based warning loop.** The
first version of `warning`'s auto-stop used a fixed-period timer to *guess* when the clip
finished and re-trigger it. Real-device testing found this cut the clip off partway through and
restarted it. The fix (firmware-side, `bsp_camera_ameba.c`'s `prvWarningPollTimerCallback()`)
polls the actual playback-finished signal and only re-triggers on a real completion, decremented
against a repeat count — this is why `warning`'s unit had to change from seconds to a count in
the first place, not just a naming preference.

**Superseded generated client note:** the generated `RestDeterrenceAlarmsClient` (`/nuraeye/
buzzer`, `/nuraeye/deterrence`, `/nuraeye/deterrence/durations`) exists but is **not** what
`DeterrenceClient`/`WanDeterrenceClient` call — like every other hand-written NuraEye client,
they go through `NuraeyeClient.call()`'s REST-backed action-name facade instead (see [Hand-written
vs. generated REST clients](#hand-written-vs-generated-rest-clients) below). `RestBuzzerClient`-
style direct usage is unused in the app.

## Local Storage

**Concept:** SD-card local recording enable/disable, plus live card-presence and capacity/free
space (`FR-CF-044`/`FR-NE-087`/`FR-MOB-083`). **Two independent facts, not one**: *capability*
(does this SKU have an SD slot at all — a fixed, build-time fact) and *card presence* (is a card
actually inserted right now — always live). A camera can be capability-supported with no card
present; the camera actively **rejects** turning recording on in that case (`500`) rather than
silently accepting it.

**Wired up 2026-08-21** — added the whole way through (client, capability field, UI card,
`StorageSettingsScreen`) in one pass; no earlier partial state to reconcile against.

**LAN:** `LocalStorageClient.getStatus()`/`setEnabled(bool)`. **WAN:**
`WanLocalStorageClient` — same methods, same `LocalStorageStatus` type.

**Capability:** `CameraCapabilities.localStorageCapable` (`CapabilitiesClient.getCapabilities()`)
— cached at onboarding as `CachedCameraSettings.localStorageSupported`, same convention as
`osdSupported`/`privacyModeSupported`. **Live card presence is never cached** — always a fresh
`getStatus()` call, since it can change the instant the SD slot is opened.

**UI convention — deliberately not FR-MOB-082's "hide the control" pattern**: the top-level
"Storage" entry on `CameraSettingsScreen` stays visible and disabled-with-message when
`localStorageSupported == false` (same `_GroupTile` pattern as OSD/Privacy Masks), never hidden
— direct user instruction. Within `StorageSettingsScreen` itself, the enable/disable toggle is
omitted (not just disabled) and replaced with a "No SD card present" warning whenever
`cardPresent == false`, since the camera would reject a Set attempt anyway. Turning the toggle
off requires an explicit confirmation dialog (stops future recording, does not erase existing
footage).

**Capability staleness fix, 2026-08-28** — real bug, direct user report: `localStorageSupported`
was only ever warmed once at onboarding and never re-checked, and `NuraeyeClient`'s underlying
`GetCapabilities` response was cached per camera host for the whole app process's lifetime with
no invalidation on remove/re-add. A camera reflashed with local storage newly compiled in (SKU
capability flipped `false`→`true`) stayed permanently stuck on "This camera doesn't support
this" — the `_GroupTile` disables `onTap` entirely once `false` is cached, so the user couldn't
even reach `StorageSettingsScreen` to retry, and removing/re-adding the camera in-app didn't
help since the stale cache lived at the process level, not the in-app camera list. Fixed the same
day with a single-attempt re-probe (`CameraSettingsScreen._maybeReprobeLocalStorage`, mirroring
the pre-existing `_maybeReprobeCloudSnapshots` fix for the same class of bug) that bypassed the
cache via a `forceRefresh` bool on `CapabilitiesClient.getCapabilities`, as long as support hadn't
already been confirmed `true`.

**This surfaced a deeper design problem the same day, fixed by a second pass**: caching
`GetCapabilities`/`GetOptions`/service-endpoint answers *inside* `camera_api` client classes (as
`static` host-keyed maps) put that caching somewhere with no reachable camera-removal hook at
all — the bug above wasn't really about a missing `forceRefresh` call, it was that the cache
lived in the wrong layer. Per direct user decision ("camera api should be clean... just network
client only"), every such cache was moved out of `camera_api` into the app layer
(`mobile_app/lib/features/settings/camera_settings_cache.dart`'s `NetworkAnswerCache`, keyed by
`CameraConnection.identityKey`) and wired to the app's real camera-removal path
(`home_screen.dart`'s `_removeCamera`) — see
`.claude/rules/mobile-app-screen-conventions.md`'s "Caching capability/service-discovery
responses" section for the current convention. `CapabilitiesClient.getCapabilities` (and every
other moved method) is now a plain, stateless, always-live call with no `forceRefresh` param —
a re-probe like `_maybeReprobeLocalStorage` now just calls it directly (bypassing the app-level
cache by construction, since it never reads from it) and writes the fresh answer back into
`NetworkAnswerCache` itself.

## Camera Health

**Concept:** Reboot count/time, uptime, clock-sync status, and firmware version (`FR-HLT-009`/
`FR-HLT-022`, Stage 3 — `design/stages/03-camera-health-diagnostics/DESIGN.md`). Read-only, not
a settings toggle — every field is camera-derived, no matching Set request exists. A reboot-loop
flag, AI-model version, and last-recording-segment timestamp are `FR-HLT-009`'s remaining,
unimplemented scope, and `Camera Health`'s card will grow to show them once the camera side
implements them — don't assume this screen is "done."

**Not to be confused with:** `Device Information` (firmware version/serial/hardware ID — static
identity, not a live health metric) or `Device Reboot` (the action of triggering a reboot — this
screen only *reports* reboot history, it doesn't trigger one).

**`last_reboot_utc` can read `0`** — this means "not yet corrected this boot," not "camera has
never booted." This platform has no battery-backed RTC (`FR-CF-114`), so every boot's clock
starts uncertain by definition; the camera writes a provisional `0` at boot and corrects it once
its first NTP sync of that boot lands (mirroring the same placeholder-then-correct pattern the
camera already uses for pre-sync recording filenames). If the app displays `0` shortly after a
reboot, that's expected — reload after a few seconds once the camera has had time to sync.

**`clock_sync_state` reuses `FR-CF-114`/Stage 3 `H0`'s already-implemented uncertain-clock flag**
(`bsp_getTimeUncertainState()`) — found via direct user request to check for already-implemented
firmware state not yet surfaced anywhere, previously unused by any API consumer. Only two states
exist (`synced`/`uncertain`) — not a third "free-running since boot" sub-state, since the BSP
layer doesn't distinguish that from a full sync. `uncertain_since` is `0` while synced.

**`firmware_version` duplicates `Device Information`'s value on purpose** — direct user request
to have one health call cover full vitals rather than needing a second round trip; it's the
identical value `GetDeviceInfo`/ONVIF `GetDeviceInformation` already report.

**Wired up 2026-08-25, extended 2026-08-26** (`uptime_seconds`/`clock_sync_state`/
`uncertain_since`/`firmware_version`) — camera-side persistence, LAN+WAN clients, and the
`Camera Health` card all added in one pass, direct user request to start this epic with a first
basic param, then extended after checking which other already-implemented firmware state wasn't
yet shipped anywhere.

**LAN:** `HealthClient.getHealth()`. **WAN:** `WanHealthClient.getHealth()` — same
`HealthStatus` type.

**No capability gate** — unlike Storage/Privacy Masks, `/nuraeye/health` is unconditional (not
behind a build flag), so `HealthSettingsScreen`'s `Camera Health` entry on
`CameraSettingsScreen` is always shown and always reachable, no `_GroupTile.supported` check.

## Recordings (browse + playback, not a settings toggle)

**Concept:** browsing and playing back clips already recorded to local SD storage
(`FR-NE-117`/`FR-NE-118`, `FR-MOB-107`/`108`/`109`, `FEAT-039`) — distinct from
[Local Storage](#local-storage) above, which only controls *whether* recording happens at all.
Recordings only make sense where Local Storage's own capability/card-presence checks pass — the
`RecordingsScreen` entry point reuses `localStorageSupported` for its own gate rather than
introducing a second capability flag for the same underlying fact.

**Not to be confused with ONVIF Recording Service/Profile G** — an earlier design for this same
Feature used `GetRecordings`/`GetRecordingInformation`/`GetReplayUri` (ONVIF Recording/Search/
Replay services, `FR-OV-080`/`081`/`082`). That approach is now `On Hold`, kept only for
`FEAT-211` (third-party NVR/VMS interop) — the mobile app was reworked onto the plain REST
mechanism documented here after finding ONVIF Search's async job-polling browse model a poor
fit for a phone client. See `design/stages/04-recording-playback/DESIGN.md` NF2 for the full
history.

**A client for that ONVIF path now exists again, but is not used by any screen.** Added
2026-08-28: `OnvifRecordingClient`/`OnvifSearchClient`/`OnvifReplayControlClient`
(`lan/onvif/onvif_recording_client.dart`, `_search_client.dart`, `_replaycontrol_client.dart`,
documented in [API_REFERENCE.md](API_REFERENCE.md#onvifrecordingclient)) speak the now-`Implemented`
firmware-side `FR-OV-080`/`081`/`082` services directly — per direct user instruction, this is a
deliberate parallel build-out, not a revival of the earlier rejected UI approach: `RecordingsClient`
and every screen above stay exactly as-is, and the ONVIF client is expected to eventually replace
them once Profile G "becomes strong." Don't wire it into `RecordingsScreen`/`ClipPlaybackScreen`
without a separate, explicit decision to do so.

**LAN only** — no WAN client exists yet. `RecordingsClient.getRecordings({start, end})` lists
clips. `RecordingsClient.clipUri(id)`/`clipHeaders()` still exist (Range-capable HTTP URL +
auth headers) but are **not** what playback actually uses — see the download-then-play note
below.

**Playback downloads the clip first, it does not stream directly from the camera** (`BUG-004`,
found 2026-08-24 — `video_player`'s native platform player, unlike every other client in this
package, has no way to trust this camera's self-signed HTTPS cert, so a direct
`VideoPlayerController.networkUrl` attempt fails its TLS handshake before any request is even
sent — this was the actual reason playback silently never worked). `ClipPlaybackScreen` instead
calls `RecordingsClient.downloadClip(id)` (goes through `createCameraHttpClient()`'s cert-trust
bypass, same as every other client here) and plays the result from a temp file
(`VideoPlayerController.file`, `path_provider`'s temp directory — never app documents/gallery,
deleted as soon as the next clip opens or the screen closes). This is a real trade-off, not a
transparent implementation detail: it loses true progressive streaming and native `Range`-based
seeking — the whole clip downloads before playback starts, acceptable for clip sizes seen so far
(5-16MB over LAN) but worth knowing before building further UI that assumes instant-start
streaming.

**Event correlation is real but bounded**: each clip's `trigger` field (when present) comes from
the camera's own alert-event history, which is a 100-entry RAM ring buffer — it does not survive
a reboot and only ever holds the *most recent* 100 events. An older clip showing no `trigger`
does not mean nothing happened during it, just that it's outside that window. Don't build UI
that treats a missing `trigger` as authoritative "nothing happened" — the app's own copy
("No events found for this clip" vs. a stronger claim) should reflect this.

**Clip duration is user-configurable** (`FR-CF-148`/`FR-NE-119`, added 2026-08-23 — direct user
request; previously a hardcoded 60s with no way to change it). `RecordingsClient.getClipDuration()`/
`setClipDuration(int)`, bounds from `CameraCapabilities.recordingClipDurationMinSeconds`/
`MaxSeconds` (never hardcoded — same "UI built from the Options/capability response" rule as
every other setting), reachable via `RecordingsScreen`'s clock-icon action. **Applies only to the
next segment rotation** — the segment currently being written keeps its original length, and
every clip's reported `end` time (`RecordingsClient.getRecordings()`) is computed from the
*currently* configured duration, not the duration actually in effect when that specific clip was
recorded (this codebase has no per-segment duration record) — a clip recorded under a previous
setting will report a slightly approximate `end`/event-correlation window after a change. Not a
silent bug; document this the same way if building further UI around it.

**Deleting clips is bulk, not per-clip** (`FR-NE-120`/`FR-MOB-110`, added 2026-08-24 — direct
user request: "delete all or like select multiple and delete also").
`RecordingsClient.deleteRecordings({ids, deleteAll})` is one call backing both a multi-select
delete and a "delete all" action — pass `ids` for specific clips or `deleteAll: true` for
everything, never both. The camera never deletes the clip currently being recorded, even if its
id is included or `deleteAll` is set — it's silently skipped, not an error, so the UI doesn't
need to special-case it. `RecordingsScreen` enters selection mode via long-press on a clip or the
overflow menu's "Select recordings" action; both destructive actions require a confirmation
dialog before the request is sent.

**Reachable on WAN too, but with no functionality** (added 2026-08-24, direct user instruction):
`RecordingsScreen`'s entry point in `CameraSettingsScreen` used to be hidden entirely on WAN
(matching the LAN-only scoping above); it's now always visible, but the screen itself shows
"Connect to LAN to see/control recordings" and skips every request (list load, clip-duration,
delete) when `isWan` is true — discoverable without being functional, rather than invisible.

**UI:** `RecordingsScreen` (clip list, `CameraSettingsScreen`'s "Recordings" tile) →
`ClipPlaybackScreen` (playback, direct time-jump via a date/time picker converted to an in-clip
seek or a clip switch, next/previous-event navigation among clips that have a `trigger`).

## Capabilities (discovery, not a setting)

**Concept:** what this specific camera build/unit supports — queried once at onboarding and
cached by the app, not read/written per-screen like the settings above. **This package has many
independent capability/support flags, not just one** — each gates a different setting or client,
and none of them are the same thing as that setting's current *value*. This section is the
complete inventory; the per-setting sections above each note their own gate inline, but check
here if you're not sure whether a flag you're about to ignore is load-bearing.

**LAN:**
- `CapabilitiesClient.getCapabilities()` → `wanCommandCapable`/`wanLiveViewCapable`/
  `supportedEventTypes`/`supportedEventDeterrenceOptions`/`sirenCapable`/`spotlightCapable`/
  `warningCapable` (the hand-written client, seven fields — see the WAN paragraph below for the
  first two, [Event Preferences](#event-preferences) for the third, [Response
  Actions](#response-actions-deterrence-on-event) for the fourth, and [Deterrence — Manual
  Trigger & Auto-Stop Duration](#deterrence--manual-trigger--auto-stop-duration) for the last
  three — added `FEAT-236`, 2026-08-14, mirroring fields the generated client below already had).
- The generated `RestCapabilitiesClient.getCapabilities()` (`/nuraeye/capabilities`) returns a
  **broader** response, `GetCapabilitiesResponse`, with the same fields plus
  `sirenCapable`/`spotlightCapable`/`warningCapable` (now also on the hand-written client above)
  and `localStorageCapable` (SD card), plus REST-surface duplicates of night-vision
  capability (`nightVisionColorCapable`/`nightVisionSmartCapable`, see below). **Nothing in the
  app currently calls this client** — if you're wiring up local-storage controls, this is the
  flag you need and it isn't being checked anywhere yet; don't assume an equivalent check
  already exists elsewhere (the deterrence flags this comment used to point at are now also
  covered by the hand-written client's `supportedEventDeterrenceOptions`, already wired into
  `EventSettingsScreen`). **Not yet regenerated for `supported_event_types`/
  `supported_event_deterrence_options`** (added to the OpenAPI spec 2026-08-13) — `tools/
  generate_dart_rest_client.py` needs a re-run before this generated model picks them up; the
  hand-written `CapabilitiesClient` above is unaffected and already has both.
- `Media2CapabilitiesClient.getServiceCapabilities()` → `osdSupported` (gates
  [OSD](#osd-on-screen-display)) / `maskSupported` (gates
  [Privacy Masks](#privacy-masks)) — whether the Media2 service advertises each feature at all,
  independent of anything `OsdOptions`/`MaskOptions` themselves report.
- `AudioCapabilityClient.getAudioCapability()` → `hasSpeaker` (gates
  [Speaker Volume](#speaker-volume-output)) / `hasMicrophone` (gates
  [mic gain](#audio--mic-gain--recording-toggle--test-tone) and two-way talk's return-audio leg).
- `OnvifDeviceClient.getNetworkInterfaceInfo()` → `.isWireless` — gates
  `NetworkInfoClient.getWifiSsid()`/`getWifiSignalStrength()`: both return meaningless/stale data
  (not a clean failure) if called while the active interface is wired Ethernet. Check
  `isWireless` first.

**WAN:** none of these have a WAN path — capability discovery is inherently a LAN-first,
onboarding-time operation (see `prefetchAndCache` in
[.claude/rules/mobile-app-screen-conventions.md](../../../.claude/rules/mobile-app-screen-conventions.md)).

### Being signed in — the prerequisite above every other WAN gate

**Every `Wan*Client` call requires the user to be authenticated, full stop — this is checked
before `wanCommandCapable`, before any Options flag, before anything else in this guide.** It's
easy to miss because it isn't a capability flag you read from a response; it's a precondition
enforced inside `IotCommandClient` itself: if `WanAuth.idTokenProvider()` (wired to
`auth_api`'s `AuthController` — see that package's `API_REFERENCE.md`) returns `null`, every
`Wan*Client` method throws `StateError('IotCommandClient called while unauthenticated')`
internally. That exception **is** caught and converted to a normal `CameraFailure` by every
`Wan*Client` wrapper — so it stays within this package's `CameraResult` contract and won't crash
a caller — but the failure text will be the raw `StateError` message (e.g.
`"StateError: IotCommandClient called while unauthenticated"`), not a friendly explanation, and
nothing about it distinguishes "not signed in" from any other failure unless the caller
recognizes that specific text.

**Practical effect:** gate any screen that calls a `Wan*Client` on `auth_api`'s
`AuthController.instance.status == AuthStatus.authenticated` first (or simply don't offer a
WAN-path control before sign-in completes — this app's own `AuthGate` already ensures no
camera-facing screen is reachable at all while unauthenticated, so in practice this mostly
matters for background/best-effort callers like `alerts_api`'s `CameraAlertsHub.ensureRunning()`,
which explicitly catches this failure and treats it as "nothing to sync yet" rather than
surfacing it — see that package's own docs). Don't rely on parsing `CameraFailure.reason`'s text
to detect this case in product code; check auth status up front instead.

### `wanCommandCapable` / `wanLiveViewCapable`

`wanCommandCapable` gates every `Wan*Client` listed anywhere in this guide — not just live view.
It means "this device has real AWS IoT credentials provisioned and the firmware build supports
the MQTT command channel at all." If it's `false`, no `Wan*Client` call — Imaging, MirrorFlip,
PrivacyMode, Mask, Osd, VideoEncoder, AudioVolume, SpeakerVolume, DeviceIdentity, ImageQuality,
none of them — will get a real response; they'll time out or fail against a camera that never
subscribes to the command topic in the first place. `wanLiveViewCapable` is a *stricter* subset
of the same flag, additionally requiring KVS build support — gates only
`WanLiveViewClient`/`startMediaSession`/`WanPreviewSnapshotClient`, not the command-relay
clients above.

Practical effect: don't reach for `isWan`/"is the transport currently WAN" as your only signal
for whether a `Wan*Client` call is safe to attempt — that's a *connectivity* decision (see
`.claude/rules/mobile-app-screen-conventions.md` § "LAN/WAN transport selection"), not a *capability* one. A camera
can be currently reached over WAN connectivity-wise while still having `wanCommandCapable ==
false` (e.g. no AWS credentials provisioned on that unit) — the settings entry point should
already be disabled from the cached capabilities check at onboarding, the same way it's disabled
until `_lastKnownTransport` is known (see that rule file's item 2).

### Per-setting Options-response capability flags — not the same idea as the two above

The flags above come from a dedicated `Get*Capabilities` call, checked once at onboarding. A
second, easily-confused kind of flag lives *inside* a setting's own `Get*Options` response —
still "is this supported," but scoped to one setting rather than the whole device, and (per the
Options-caching convention in `.claude/rules/mobile-app-screen-conventions.md`) fetched/cached alongside that
setting's bounds rather than at a separate onboarding step. These are noted individually in each
section above, collected here for a single lookup:

| Flag | On | From | Gates |
|---|---|---|---|
| `ImagingOptions.wdrSupported` | `OnvifImagingClient`/analogous WAN record | `getImagingOptions()` | [WDR](#wdr-wide-dynamic-range) control — hide, don't disable, when `false`. |
| `ImagingOptions.irCutFilterModes` (empty list) | same | same | [Day/Night Mode](#daynight-mode-ir-cut-filter) picker — no valid choices to offer. |
| `NightVisionStatus.colorCapable` / `.smartCapable` | `NightVisionStatus` | `getNightVisionType()` itself (embedded in the status response, not a separate Options call) | [Night Vision Type](#night-vision-type)'s Color/Smart choice chips respectively. |
| `EncodingOptions.supportsCbr` (**per-encoding** — H264 and H265 can differ) | `VideoEncoderSettingsOptions` | `getVideoEncoderSettingsOptions()` | [Video Encoder](#video-encoder-settings-stream-0-high-res)'s CBR/VBR toggle — only editable when the *currently selected* encoding's own flag is `true`. |
| `MaskOptions.rectangleOnly` / `.singleColorOnly` | `MaskOptions` | `getMaskOptions()` | [Privacy Masks](#privacy-masks) editor's shape freedom / color-picker availability. `maxMasks == 0` (the fallback when `GetMaskOptions`'s `<Options>` element is absent entirely) doubles as "masks not supported at all." |
| `OsdOptions.fontColorRangeAvailable` | `OsdOptions` | `getOsdOptions()` | [OSD](#osd-on-screen-display)'s RGB slider color picker — `true` when the camera reports a continuous `ColorspaceRange` rather than only a discrete list; without checking this the color UI can silently fail to render even though `fontColors` alone looks non-empty in some builds. |

**The pattern to internalize:** almost every settings screen in this package has *two* separate
things to check before trusting a control is usable — the device-wide capability flag (this
section) and the setting's own Options-response support flag (the table above) — and neither
substitutes for the other. `osdSupported` (device advertises OSD at all) and
`OsdOptions.fontColorRangeAvailable` (this specific OSD feature's color mode) are a real example
of both applying to the same screen at once.

---

## Hand-written vs. generated REST clients

A handful of settings (Mirror/Flip, Privacy Mode, and others under `lan/nuraeye/rest_*.dart`)
are reachable through **two different Dart client wrappers for the identical wire endpoint**:
the hand-written client listed in this guide (`MirrorFlipClient`, `PrivacyModeClient`, etc.) and
a machine-generated `Rest*Client` (`RestVideoImageClient`, `RestPrivacyClient`, ...) produced
from `design/Camera-REST-API.openapi.yaml`. These are not two different settings and not two
different camera behaviors — they hit the same `/nuraeye/*` path.

**Always use the hand-written client listed in this guide.** The generated clients are current
unused reserve API surface (`NuraeyeClient`/the hand-written wrappers do not call through them)
kept for a future consumer that wants the REST API's native shape — see `API_REFERENCE.md`'s
"Generated REST clients" section. Never hand-edit a `rest_*.dart` file; regenerate via
`/generate_dart_client` if the OpenAPI spec changes.
