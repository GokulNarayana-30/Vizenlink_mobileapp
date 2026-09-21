# UI ↔ API Coverage Gap Report

**Date:** 2026-09-21

> ## ⚠️ Status update — later on 2026-09-21, after two `camera_api` swaps
>
> Parts of this report below are now **out of date**. What changed since it was written:
>
> - **The pending `client_code_inbox` drop was integrated** (twice — a second drop landed after
>   review feedback). The callout below saying it is un-integrated, and the "provisional" caveat
>   on the WAN/streaming ✅ rows, no longer apply. `KvsPlaybackClient`/HLS is gone; WAN live view
>   now runs on `startMediaSession` → `KvsMediaLiveViewSession` with credential refresh,
>   transparent `GetMedia` reconnect and per-client backpressure.
> - **WAN recordings and WAN clip playback now exist** (`WanRecordingsClient`,
>   `WanClipPlaybackClient`) and are integrated into `camera_live_screen.dart`'s Playback tab and
>   `storage_screen.dart`'s Recordings tab. The Playback tab was LAN-only before.
> - **Resolutions are no longer bucketed** — the `CameraResolution` enum is gone; encoder
>   screens use the camera's own `width×height`.
> - **The video-encoder stream list is discovered** via `getProfiles()` instead of three
>   hardcoded rows.
> - **Imaging sliders use camera-reported ranges** — `getImagingOptions()`'s four ISP ranges and
>   `wdrLevel` were already fetched and cached but never reached the sliders.
> - **New blocked item:** `OsdOptions` exposes `fontSizeMin`/`fontSizeMax` but **no OSD setter
>   accepts a font size**, so the planned font-size control on `on_screen_display_screen.dart`
>   was not built. Needs a `font_size` parameter on SetOSD from the senior engineer.
> - **Still open from this report's Quick Wins:** the events flow is unchanged —
>   `events_controller.dart`'s `_seedEvents()` is still hardcoded, and `events_screen.dart` still
>   uses `_mockRecordedRanges`. These are now *easier*, since recordings work on both transports.
> - **Still open:** the stale `docs/client_code/camera_api.md` rows this report flagged have been
>   corrected; the `WanDeviceIdentityClient` → `active_sessions_screen` mapping was wrong and is
>   now fixed there.
>
> **None of the above has been verified on real hardware yet.**

**Scope:** Cross-references built screens in `lib/screens/**/*.dart` against documented client/API
code (`docs/client_code/*.md`, plus `packages/camera_api/API_REFERENCE.md` and
`SETTINGS_API_GUIDE.md` for capability-level detail). Complements `scenario-gap-audit` (spec vs.
UI); this report is UI vs. API-wiring only. Read-only analysis — no screen code, docs, or client
files were modified.

## Summary counts

**Part A — 54 screen files in `lib/screens/`** checked against `docs/client_code/*.md`
(`camera_api.md`, `auth_api.md`, `alerts_api_config.md`, `camera_alerts_hub.md`):

| Status | Count | Meaning |
|---|---|---|
| ✅ Wired | 33 | Screen (directly or via an `app_state` controller it's constructed with) calls a documented, imported client-code method |
| ⚠️ Client code exists, not wired | 3 | Documented client code covers the need; screen still uses hardcoded/seed data |
| ❌ No client code available | 9 | Nothing in `docs/client_code/` (or `packages/camera_api`) covers this screen's need |
| N/A | 9 | Pure navigation menus or static content with no data-backed element to wire (not counted as a gap) |

**Part B — ~55 documented client classes** (`camera_api.md`'s screen mapping +
`API_REFERENCE.md`'s `###`/`####` entries, summarized by class per the audit's own allowance) +
`auth_api`'s 10 `AuthController` methods + `alerts_api`'s `CameraAlertsHub`/`AlertsAuth` surface,
grepped against `lib/` for actual reference:

| Status | Count | Meaning |
|---|---|---|
| 🆕 Available, no UI yet | 0 | — see note below |

Only two client classes were found with zero references anywhere in `lib/`: `OnvifRecordingClient`
and `OnvifSearchClient`. Both are explicitly marked in `docs/client_code/camera_api.md` as
**"Superseded, not for integration"** (replaced by `RecordingsClient`'s plain-REST design after
the sibling app found ONVIF Search's job-polling model a poor fit for a phone client) — so they
are not listed as 🆕 gaps. `WanLiveViewClient` also shows no direct reference, but its concrete
implementation `AwsWanLiveViewClient` (used extensively in `live_view_controller.dart`) is the
class the codebase actually calls — a naming variant, not a gap. Every other documented capability,
including recently-added ones (`LoiteringDurationClient`, `BboxOverlayClient`, `HealthClient`/
`WanHealthClient`, `DeterrenceClient`/`WanDeterrenceClient`, `TalkUriClient`), is already
referenced from a screen or the `app_state` controller that feeds one — this app's `camera_api`
integration is broad. Auth (`auth_api`) is fully wired: all 10 `AuthController` methods
(`signUp`/`confirmSignUp`/`resendConfirmationCode`/`signIn`/`awsCredentials`/`forgotPassword`/
`confirmForgotPassword`/`changePassword`/`signOut`/`restore`) are called from exactly the screens
`auth_api.md` maps them to. `alerts_api`'s `CameraAlertsHub` is wired via
`lib/app_state/alerts_controller.dart` (consumed by `alerts_screen.dart`).

---

## ⚠️ Pending, undocumented `client_code_inbox/packages/camera_api` update

`git status` shows a large, currently **modified/added/deleted** set of files under
`client_code_inbox/packages/camera_api/` that the senior engineer has dropped but that have
**not** gone through `client-code-docs` review or `integrate-client-code` yet. Per this audit's
scope, inbox content is treated as "incoming, not yet real" and was **not** used for any ✅/⚠️/❌
classification above — but several of these files touch the same WAN/streaming clients this
report just classified as ✅ wired (`WanLiveViewClient`, `AwsWanLiveViewClient`,
`IotCommandClient`, `WanDeviceIdentityClient`, `WanAuth`, `OnvifDeviceClient`), plus a brand-new
`kvs_media/`/`media/` module replacing the deleted `kvs_playback_client.dart`. **Treat this
report's WAN/streaming-related ✅ classifications (`camera_live_screen.dart`,
`live_view_controller.dart`'s WAN paths, `wifi_config_screen.dart`/`camera_info_screen.dart`'s
`OnvifDeviceClient` usage) as provisional until this drop is reviewed** — the currently-integrated
`packages/camera_api` behavior these screens call may not match what's coming.

Changed files (`git status --porcelain` under `client_code_inbox/packages/camera_api/`):

```
M  API_REFERENCE.md
M  SETTINGS_API_GUIDE.md
M  STREAMING_GUIDE.md
M  lib/camera_api.dart
M  lib/src/lan/onvif/onvif_device_client.dart
M  lib/src/wan/aws_sigv4.dart
M  lib/src/wan/aws_wan_live_view_client.dart
M  lib/src/wan/iot_command_client.dart
D  lib/src/wan/kvs_playback_client.dart
M  lib/src/wan/wan_auth.dart
M  lib/src/wan/wan_device_identity_client.dart
M  lib/src/wan/wan_live_view_client.dart
M  test/iot_command_client_test.dart
D  test/kvs_playback_client_test.dart
?? lib/src/media/                (new, untracked)
?? lib/src/wan/kvs_media/        (new, untracked)
?? test/fixtures/                (new, untracked)
?? test/mkv_demuxer_test.dart    (new, untracked)
```

Recommended next step: run `client-code-docs` on the changed/new files before relying on this
report's WAN/streaming rows for planning.

---

## Quick Wins (⚠️ — client code exists, integrate now)

Sorted smallest-remaining-gap-first.

| Screen (file) | Client code covering it | What's missing | Est. effort |
|---|---|---|---|
| `lib/screens/events/events_screen.dart` | `packages/camera_api/API_REFERENCE.md` § `RecordingsClient` (`getRecordings`) — already imported/used elsewhere in `lib/screens/camera_live/camera_live_screen.dart` | The `EVT-025` recording-coverage band still renders the hardcoded `const _mockRecordedRanges` (line 16) instead of a `RecordingsClient.getRecordings()`-derived `List<TimelineRange>`, same pattern `camera_live_screen.dart`'s Playback tab already uses | S |
| `lib/screens/events/event_detail_screen.dart` | `RecordingsClient.downloadClip()`/clip-URI methods (`API_REFERENCE.md` § `RecordingsClient`) | `_MediaView` is thumbnail-only by explicit design (dummy video removed 2026-09-07 "per direct user request") — no inline clip playback wired to a real per-event clip URL, even though `RecordingsClient` now supports exactly that (it's already used for playback in `camera_live_screen.dart`) | M |
| `lib/app_state/events_controller.dart` (feeds `events_screen.dart`, `events_summary_screen.dart`, `event_detail_screen.dart`) | `RecordingsClient.getRecordings()` | `_seedEvents()` (line 18) returns a fixed, hardcoded `List<RecordedEvent>` — the controller never calls into `camera_api` at all, so every event-related screen (list, detail, day/week/month summary chart) is downstream of this one hardcoded seed | M |

---

## Blocked (needs new client code)

Nothing in `docs/client_code/` (or `packages/camera_api`/`packages/auth_api`) covers these needs
yet — each needs a new file/capability from the senior engineer before `integrate-client-code` can
do anything.

**Camera-side capabilities with no matching client:**
- `lib/screens/camera_settings/recording_screen.dart` — Continuous/Scheduled/Event-Triggered/Off
  recording mode + day/time schedule editor. Explicitly documented in the screen's own header
  comment as "Persisted through `HomesController.updateCamera`" — local app state only, no
  `camera_api` call. `SETTINGS_API_GUIDE.md` has no "recording mode/schedule" section (closest
  neighbors — Local Storage, Event Preferences — don't cover it).
- `lib/screens/camera_settings/parking_monitoring_screen.dart` — per-zone vehicle occupancy
  classification (Marked-Bay / Open-Area / Restricted zones). The screen's own header comment
  says this directly: **"Entirely local-only for now — no `camera_api` capability exists yet for
  per-zone vehicle occupancy classification (only a plain `VehicleDetected` boolean exists,
  confirmed via `ui-api-gap-audit`)."**

**Account/session capabilities with no matching client:**
- `lib/screens/account/active_sessions_screen.dart` — list of devices signed into the account.
  `docs/client_code/camera_api.md`'s screen-mapping table points `WanDeviceIdentityClient` at this
  screen ("Authentication" card), but `WanDeviceIdentityClient` (per `API_REFERENCE.md` §1283) only
  covers a *camera's* name/location/timezone/password/reboot — nothing about listing a *phone
  account's* active Cognito sessions. `auth_api.md`'s `AuthController` exposes only the current
  single `session`, no multi-device listing endpoint. That screen-mapping row appears stale/
  mistaken; flag for correction next time `camera_api.md` is touched.
- `lib/screens/account/users_invites_screen.dart`, `create_user_screen.dart`,
  `invite_user_screen.dart`, `camera_access_screen.dart` — household member/invite management and
  per-member camera-access scopes. Each screen's own header comment confirms this is local-widget-
  state only ("static mock data held in local widget state", "no auth backend to store them",
  "caller only adds the result to its local pending-invites list", "returned scope is only held in
  the caller's local widget state"). `auth_api.md` documents only single-account sign-up/sign-in/
  session — no multi-user/household/invite surface exists in any documented client.

**No backend concept documented at all:**
- `lib/screens/camera_live/ai_mode_screen.dart` — natural-language object/person query over a
  captured frame. `_ask()` (line 278) does `await Future<void>.delayed(...900ms)` then always
  returns a canned "AI object recognition isn't connected yet" / "AI search isn't connected yet"
  string. No AI/vision-language client is documented anywhere (the on-device chatbot was removed
  per commit `852df01`).
- `lib/screens/account/notification_preferences_screen.dart` — push/email alert-type toggles and
  quiet-hours. Screen's own header comment: "No notification backend is wired up yet... every
  toggle just lives in local widget state — nothing is actually sent." Distinct from `alerts_api`'s
  `CameraAlertsHub` (which delivers live alerts once received) — no documented API exists for
  *subscribing/opting into* categories of alerts.

---

## Available APIs With No UI Yet

None found as a genuine gap. See the Summary-counts note above: the only two fully-unreferenced
client classes (`OnvifRecordingClient`, `OnvifSearchClient`) are explicitly superseded/excluded
from integration per `docs/client_code/camera_api.md`, and `WanLiveViewClient` is a naming variant
of the already-wired `AwsWanLiveViewClient`. Every other documented `camera_api`, `auth_api`, and
`alerts_api` capability — including the newer `LoiteringDurationClient`, `BboxOverlayClient`,
`HealthClient`/`WanHealthClient`, and `DeterrenceClient`/`WanDeterrenceClient` — is already
referenced from at least one screen or the controller feeding it.

---

## Full detail table

Screen-level rows for fully ✅/❌ screens (element-level detail already given above for the
Quick Wins / Blocked entries to avoid repetition).

| Screen (file) | Element/action | Status | Client code covering it | Notes |
|---|---|---|---|---|
| `login/login_screen.dart` | Sign in | ✅ | `auth_api.md` (`AuthController.signIn`) | |
| `login/forgot_password_screen.dart` | Request/confirm reset code | ✅ | `auth_api.md` (`forgotPassword`/`confirmForgotPassword`) | |
| `signup/signup_screen.dart` | Sign up | ✅ | `auth_api.md` (`signUp`) | |
| `signup/confirm_signup_screen.dart` | Confirm code / resend | ✅ | `auth_api.md` (`confirmSignUp`/`resendConfirmationCode`) | |
| `splash/splash_screen.dart` | Session restore / initial route | ✅ | `auth_api.md` (`AuthController.restore`) | |
| `account/account_screen.dart` | Sign out | ✅ | `auth_api.md` (`signOut`) | `_mockAppVersion` literal string is cosmetic, not a data gap |
| `account/change_password_screen.dart` | Change password | ✅ | `auth_api.md` (`changePassword`) | |
| `account/active_sessions_screen.dart` | Device list, remote sign-out | ❌ | — | see Blocked |
| `account/users_invites_screen.dart` | Member/invite list | ❌ | — | see Blocked |
| `account/create_user_screen.dart` | Create member | ❌ | — | see Blocked |
| `account/invite_user_screen.dart` | Send invite | ❌ | — | see Blocked |
| `account/camera_access_screen.dart` | Per-camera access scope picker | ❌ | — | see Blocked |
| `account/notification_preferences_screen.dart` | Alert-category/quiet-hours toggles | ❌ | — | see Blocked |
| `account/account_settings_screen.dart` | Navigation menu | N/A | — | Pure nav to sub-screens above |
| `account/help_support_screen.dart` | FAQ list | N/A | — | Static content, no API needed |
| `alerts/alerts_screen.dart` | Live alert list/filter | ✅ | `camera_alerts_hub.md` (`CameraAlertsHub.events`, via `AlertsController`) | |
| `alerts/alert_detail_screen.dart` | Alert detail view | ✅ | `camera_alerts_hub.md` / `alerts_api_config.md` (`Alert` data passed in) | Media view is thumbnail-only by design (dummy video removed 2026-09-07) |
| `alerts/alert_settings_screen.dart` | Deterrence durations, response actions | ✅ | `camera_api.md` (`DeterrenceClient`/`WanDeterrenceClient`) | |
| `events/events_screen.dart` | Event list/filter | ✅ | `events_controller.dart` (real, but seeded — see Quick Wins) | EVT-025 recording band ⚠️, see Quick Wins |
| `events/event_detail_screen.dart` | Event detail | ⚠️ | `RecordingsClient` | see Quick Wins |
| `events/events_summary_screen.dart` | Analytics/breakdown charts | ⚠️ (inherited) | `events_controller.dart` | Derived entirely from the same seeded `EventsController` data; screen's own comment: "Mock/local data only" |
| `camera_live/camera_live_screen.dart` | Live view, playback, snapshot, deterrence, talk | ✅ | `camera_api.md` (`SnapshotClient`, `WebRtcUriClient`/`AwsWanLiveViewClient`, `RecordingsClient`, `DeterrenceClient`/`WanDeterrenceClient`, `TalkUriClient`) | Extensively wired; see inbox callout re: WAN/streaming provisional status |
| `camera_live/ai_mode_screen.dart` | Object/person Q&A | ❌ | — | see Blocked |
| `camera_settings/audio_screen.dart` | Mic gain, speaker volume | ✅ | `camera_api.md` (`AudioCapabilityClient`/`SpeakerVolumeClient`/`AudioVolumeClient`) | |
| `camera_settings/camera_info_screen.dart` | Device identity, health, timezone | ✅ | `camera_api.md` (`OnvifDeviceClient`, `WanHealthClient`/`HealthClient` via `clockSyncUncertain`) | Timezone picker falls back to a static `_dummyTimezones` list only when the camera reports none — acceptable fallback, not a wiring gap |
| `camera_settings/danger_zone_screen.dart` | Reboot / factory reset | ✅ | `camera_api.md` (`OnvifDeviceClient`/`WanDeviceIdentityClient`) | |
| `camera_settings/imaging_screen.dart` | Brightness/contrast/WDR/etc. | ✅ | `camera_api.md` (`OnvifImagingClient`/`WanImagingClient`/`WanImageQualityClient`) | |
| `camera_settings/night_mode_screen.dart` | Night vision type | ✅ | `camera_api.md` (`NightVisionClient`/`WanNightVisionClient`) | |
| `camera_settings/on_screen_display_screen.dart` | OSD text/position | ✅ | `camera_api.md` (`OsdClient`/`WanOsdClient`) | |
| `camera_settings/person_detection_screen.dart` | Loitering duration, bbox overlay | ✅ | `camera_api.md` (`LoiteringDurationClient`/`WanLoiteringDurationClient`, `BboxOverlayClient`/`WanBboxOverlayClient`) | `camera_api.md`'s own "New in the 2026-09-07 drop" table still lists this as an unwired gap — code has since caught up; doc is stale |
| `camera_settings/privacy_mode_screen.dart` | Privacy masks/toggle | ✅ | `camera_api.md` (`MaskClient`/`WanMaskClient`, `PrivacyModeClient`/`WanPrivacyModeClient`) | |
| `camera_settings/storage_screen.dart` | SD card status/format | ✅ | `camera_api.md` (`LocalStorageClient`/`WanLocalStorageClient`) | |
| `camera_settings/video_mode_screen.dart` | Mirror/flip | ✅ | `camera_api.md` (`MirrorFlipClient`/`WanMirrorFlipClient`) | |
| `camera_settings/video_encoder_screen.dart` | Per-stream summary/landing list | ✅ | Reads already-synced `Camera` fields | Pure landing list; real settings wiring is in `video_stream_encoder_screen.dart` |
| `camera_settings/video_stream_encoder_screen.dart` | Resolution/bitrate/codec per stream | ✅ | `camera_api.md` (`OnvifVideoEncoderClient`/`WanVideoEncoderClient`) | |
| `camera_settings/wifi_config_screen.dart` | WiFi SSID/signal/setup | ✅ | `camera_api.md` (`NetworkInfoClient`) | |
| `camera_settings/recording_screen.dart` | Recording mode + schedule | ❌ | — | see Blocked |
| `camera_settings/parking_monitoring_screen.dart` | Parking zone config | ❌ | — | see Blocked |
| `camera_settings/intrusion_detection_screen.dart` | Intrusion zone config | ✅ | `camera_api.md` (via `app_state/camera_sync.dart` → `MaskClient`-family) | |
| `camera_settings/line_crossing_screen.dart` | Line-crossing config | ✅ | `camera_api.md` (via `camera_sync.dart`) | |
| `camera_settings/motion_detection_screen.dart` | Motion detection toggle | ✅ | `camera_api.md` (via `camera_sync.dart`) | |
| `camera_settings/vehicle_detection_screen.dart` | Vehicle detection toggle | ✅ | `camera_api.md` (via `camera_sync.dart`) | |
| `camera_settings/tags_screen.dart` | Camera tags | ✅ | `camera_api.md` (via `camera_sync.dart`) | |
| `camera_settings/detections_screen.dart`, `video_display_screen.dart`, `camera_settings_screen.dart` | Navigation menus | N/A | — | Pure nav to sub-screens above |
| `multiview/multiview_screen.dart` | Grid live view, deterrence | ✅ | `camera_api.md` (`SnapshotClient`, `DeterrenceClient`/`WanDeterrenceClient`) | |
| `multiview/multiview_reorder_screen.dart` | Reorder tiles | N/A | `homes_controller.dart` | Local ordering preference, no camera-side API needed |
| `scan/scanned_devices_screen.dart` | LAN discovery, connect | ✅ | `camera_api.md` (`WsDiscoveryClient`) | |
| `scan/add_camera_manually_dialog.dart` | Manual host entry | ✅ | `camera_api.md` (`CameraConnection`) | |
| `scan/scanning_popup.dart` | Scan progress UI | N/A | `app_state/camera_scan.dart` | UI shell around the scan controller, no direct element to wire |
| `dashboard/dashboard_screen.dart` | Camera tiles, quick actions | ✅ | `camera_sync.dart`, `live_view_controller.dart`, `alerts_controller.dart` | Aggregates already-wired controllers; any embedded events preview inherits the `events_controller.dart` seed-data gap above |
| `homes/manage_homes_screen.dart` | Home/camera list management | N/A | `homes_controller.dart` | Local grouping/naming, no camera-side API needed |
| `shell/main_shell.dart` | Bottom-nav shell | N/A | — | Pure routing shell |

## What this means for next steps

- **⚠️ Quick Wins** (`events_screen.dart`, `event_detail_screen.dart`, `events_controller.dart`):
  `/integrate-client-code` can close these now — `RecordingsClient` is already documented and
  already integrated elsewhere in this app (`camera_live_screen.dart`), so this is wiring, not new
  client work.
- **❌ Blocked** items (`recording_screen.dart`, `parking_monitoring_screen.dart`,
  `active_sessions_screen.dart`, `users_invites_screen.dart`, `create_user_screen.dart`,
  `invite_user_screen.dart`, `camera_access_screen.dart`, `ai_mode_screen.dart`,
  `notification_preferences_screen.dart`): each needs a new file/capability from the senior
  engineer first — nothing to integrate yet.
- **🆕** — none found this pass; nothing here is new-screen/new-element work subject to the
  plan-before-code rule.
