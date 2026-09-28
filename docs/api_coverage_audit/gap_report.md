# UI ↔ API Coverage Gap Report

**Date:** 2026-09-28

> ## ⚠️ Status update — later on 2026-09-28
>
> `recording_screen.dart` has moved from ❌ Blocked to ✅ Wired since this report was generated.
> The inbox drop flagged below as "un-reviewed" (`recording_mode_client.dart`,
> `recording_mode_types.dart`, `wan_recording_mode_client.dart`) has been swapped into
> `packages/camera_api` and integrated: Continuous/Scheduled/Event-Triggered now load/save through
> `RecordingModeClient`/`WanRecordingModeClient`, gated by `CameraCapabilities
> .supportedRecordingModes`/`maxRecordingScheduleWindows`. Off remains local-only by design (see
> `docs/client_code/camera_api.md`'s 2026-09-28 entry) — it has no wire representation.
>
> The same drop also carried two bug fixes affecting already-✅ screens, described in
> `docs/client_code/camera_api.md`: `RecordingsClient.getAllRecordings()` (a pagination fix now
> used by `camera_live_screen.dart`'s Playback tab and `storage_screen.dart`'s Recordings tab,
> replacing the single-page `getRecordings()` call both used before) and an ONVIF SOAP-fault
> ordering fix that changed the exact error string `camera_live_screen.dart`'s PlaybackBusy retry
> matches on (now handles both the old and new string).
>
> This does not change this report's Part A count (33→34 ✅, 9→8 ❌) or the totals below, which
> are frozen as of generation time — see `docs/client_code/camera_api.md` for the current source
> of truth.

**Scope:** Cross-references built screens in `lib/screens/**/*.dart` against documented client/API
code (`docs/client_code/*.md`, plus `packages/camera_api/API_REFERENCE.md` and
`SETTINGS_API_GUIDE.md` for capability-level detail). Complements `scenario-gap-audit` (spec vs.
UI); this report is UI vs. API-wiring only. Read-only analysis — no screen code, docs, or client
files were modified. This pass re-verified every row from scratch against current source rather
than copying the 2026-09-21/22 report forward.

## Summary counts

**Part A — 54 screen files in `lib/screens/`** checked against `docs/client_code/*.md`
(`camera_api.md`, `auth_api.md`, `alerts_api_config.md`, `camera_alerts_hub.md`):

| Status | Count | Meaning |
|---|---|---|
| ✅ Wired | 33 | Screen (directly or via an `app_state` controller it's constructed with) calls a documented, imported client-code method |
| ⚠️ Client code exists, not wired | 3 | Documented client code covers the need; screen still uses hardcoded/seed data |
| ❌ No client code available | 9 | Nothing in `docs/client_code/` (or `packages/camera_api`) covers this screen's need |
| N/A | 9 | Pure navigation menus or static content with no data-backed element to wire (not counted as a gap) |

**Part B — ~61 documented client classes** (`camera_api.md`'s screen mapping + `API_REFERENCE.md`'s
`###` entries, summarized by class per the audit's own allowance) + `auth_api`'s 10
`AuthController` methods + `alerts_api`'s `CameraAlertsHub`/`AlertsAuth` surface, grepped against
`lib/` for actual reference:

| Status | Count | Meaning |
|---|---|---|
| 🆕 Available, no UI yet | 0 | — see note below |

Only `OnvifRecordingClient` and `OnvifSearchClient` show zero references anywhere in `lib/`, and
both remain explicitly marked in `docs/client_code/camera_api.md` as **"Superseded, not for
integration"**. `KvsMediaViewerCredentialsClient` also shows no direct screen/controller reference,
but it's pure credential-vending plumbing consumed internally by `KvsMediaLiveViewSession`
(skipped per this audit's "skip pure transport/plumbing" rule, same treatment as `WanAuth`/
`IotCommandClient`'s internals). Every other documented capability — including the newest
additions, `WanRecordingsClient`, `WanClipPlaybackClient`, and `KvsMediaLiveViewSession` (with its
`heartbeat()`) — is referenced from a screen or the `app_state` controller feeding one. Auth
(`auth_api`) remains fully wired (all 10 `AuthController` methods); `alerts_api`'s
`CameraAlertsHub` remains wired via `alerts_controller.dart`.

---

## What changed since the 2026-09-21/22 report

- **`WanRecordingsClient`, `WanClipPlaybackClient`, `KvsMediaLiveViewSession` are confirmed wired**
  (were previously flagged "provisional, pending review of an inbox drop"). Verified directly in
  `lib/screens/camera_live/camera_live_screen.dart` (`_WanClipSession` class at L3539+: fields
  `_control` (`WanClipPlaybackClient`), `_media` (`KvsMediaLiveViewSession`), a 10s
  `_heartbeatTimer` calling `_control.heartbeat()`) and `lib/screens/camera_settings/
  storage_screen.dart` (L630, `WanRecordingsClient` on the Recordings tab). No longer provisional
  — this is live, committed code, not an unreviewed inbox drop.
- **H.265 fixes (live view + recorded playback) and the LAN "one session at a time" playback fix**
  (commits `0786737`, `8c4d810`) are bug fixes inside screens that were already ✅ wired
  (`camera_live_screen.dart` / `live_view_controller.dart` / `rtsp/`) — they don't change any
  row's status, since the client-code coverage was already present; they just made existing calls
  behave correctly.
- **The ~9-screen "timed-out Apply misreported as rejected" fix** (commits `68f191c`, `542e8e7`,
  and the "eight more settings screens" commit) likewise lands inside already-✅ settings screens
  — no status changes, just correctness.
- **Imaging camera-reported ranges, the `CameraResolution`→`width×height` swap, and
  `video_encoder_screen.dart`'s `getProfiles()`-based stream discovery** were already reflected as
  done in the prior report's late update; re-verified still true (`imaging_screen.dart` reads
  `getImagingOptions()`'s ranges, no `CameraResolution` enum exists anywhere in `lib/` or
  `packages/camera_api/`, `video_encoder_screen.dart` has no hardcoded 3-row stream list).
- **No regressions found.** All previously-✅ classes/screens re-grepped clean; the three ⚠️ Quick
  Wins (`events_screen.dart`, `event_detail_screen.dart`, `events_controller.dart`) and all nine ❌
  Blocked screens are unchanged — none have moved.
- **New heads-up (not scored):** `client_code_inbox/packages/camera_api/` currently has a large
  set of modified files *plus* three brand-new untracked ones — `lib/src/lan/nuraeye/
  recording_mode_client.dart`, `lib/src/recording_mode_types.dart`, `lib/src/wan/
  wan_recording_mode_client.dart` (plus matching tests) — that do not exist yet in the committed
  `packages/camera_api/`. This looks like it may directly address the `recording_screen.dart` ❌
  Blocked gap below (Continuous/Scheduled/Event-Triggered/Off recording mode + schedule), but per
  this audit's scope, inbox content is staging-only and untouched by `client-code-docs`/
  `integrate-client-code` yet, so it is **not** counted as ✅/⚠️/🆕 here. Flag for `client-code-docs`
  next time this inbox drop is reviewed — `recording_screen.dart` may drop off the Blocked list
  once it lands.

---

## Quick Wins (⚠️ — client code exists, integrate now)

Sorted smallest-remaining-gap-first.

| Screen (file) | Client code covering it | What's missing | Est. effort |
|---|---|---|---|
| `lib/screens/events/events_screen.dart` | `packages/camera_api/API_REFERENCE.md` § `RecordingsClient` (`getRecordings`) — already imported/used in `lib/screens/camera_live/camera_live_screen.dart` and now `storage_screen.dart` | The `EVT-025` recording-coverage band still renders the hardcoded `const _mockRecordedRanges` (L16) instead of a `RecordingsClient`/`WanRecordingsClient`-derived `List<TimelineRange>`, same pattern the Playback tab already uses | S |
| `lib/screens/events/event_detail_screen.dart` | `RecordingsClient`/`WanRecordingsClient` clip-URI methods | `_MediaView` (L346) is thumbnail-only by explicit design (dummy video removed 2026-09-07) — no inline clip playback wired to a real per-event clip URL, even though this exact pattern (`WanClipPlaybackClient` + `KvsMediaLiveViewSession`) is now proven out in `camera_live_screen.dart`'s Playback tab | M |
| `lib/app_state/events_controller.dart` (feeds `events_screen.dart`, `events_summary_screen.dart`, `event_detail_screen.dart`) | `RecordingsClient.getRecordings()` / `WanRecordingsClient.getRecordings()` | `_seedEvents()` (L18) still returns a fixed, hardcoded `List<RecordedEvent>` — the controller never calls into `camera_api`, so every event-related screen (list, detail, day/week/month summary chart) is downstream of this one hardcoded seed | M |

`/integrate-client-code` can close all three now — no new client file needed, this is wiring
already-integrated-elsewhere client code into the events flow.

---

## Blocked (needs new client code)

Nothing in `docs/client_code/` (or the committed `packages/camera_api`) covers these needs yet —
each needs a new file/capability from the senior engineer, reviewed via `client-code-docs`, before
`/integrate-client-code` can do anything. (For `recording_screen.dart`, see the inbox heads-up
above — a candidate file may already be sitting in `client_code_inbox/`, just not reviewed yet.)

**Camera-side capabilities with no matching client:**
- `lib/screens/camera_settings/recording_screen.dart` — Continuous/Scheduled/Event-Triggered/Off
  recording mode + day/time schedule editor. Screen's own header comment: persisted only through
  `HomesController.updateCamera` — local app state, no `camera_api` call. The committed
  `SETTINGS_API_GUIDE.md`/`API_REFERENCE.md` still have no recording-mode/schedule section.
- `lib/screens/camera_settings/parking_monitoring_screen.dart` — per-zone vehicle occupancy
  classification (Marked-Bay / Open-Area / Restricted zones). Screen's own header comment: "no
  `camera_api` capability exists yet for per-zone vehicle occupancy classification (only a plain
  `VehicleDetected` boolean exists)."

**Account/session capabilities with no matching client:**
- `lib/screens/account/active_sessions_screen.dart` — list of devices signed into the account. No
  documented client covers listing a *phone account's* active sessions; `WanDeviceIdentityClient`
  (per `API_REFERENCE.md` §1418) covers only a *camera's* identity/config, and `auth_api.md`'s
  `AuthController` exposes only the current single session.
- `lib/screens/account/users_invites_screen.dart`, `create_user_screen.dart`,
  `invite_user_screen.dart`, `camera_access_screen.dart` — household member/invite management and
  per-member camera-access scopes. Each screen's own header comment confirms local-widget-state
  only, no backend. No multi-user/household/invite surface exists in any documented client.

**No backend concept documented at all:**
- `lib/screens/camera_live/ai_mode_screen.dart` — natural-language object/person query over a
  captured frame. `_ask()` (L278) still does a fixed-delay `Future.delayed` then always returns a
  canned "not connected yet" string. No AI/vision-language client is documented anywhere.
- `lib/screens/account/notification_preferences_screen.dart` — push/email alert-type toggles and
  quiet-hours. Screen's own header comment: "No notification backend is wired up yet... nothing is
  actually sent." Distinct from `alerts_api`'s `CameraAlertsHub` (delivers live alerts already
  received) — no documented API for *subscribing/opting into* categories.

---

## Available APIs With No UI Yet

None found as a genuine gap this pass either. `OnvifRecordingClient`/`OnvifSearchClient` remain
explicitly superseded/excluded from integration. `KvsMediaViewerCredentialsClient` is internal
transport plumbing for `KvsMediaLiveViewSession`, skipped per this audit's plumbing exclusion.
Every other documented `camera_api`, `auth_api`, and `alerts_api` capability — including
`WanRecordingsClient`, `WanClipPlaybackClient`, `KvsMediaLiveViewSession.heartbeat()`,
`LoiteringDurationClient`, `BboxOverlayClient`, `HealthClient`/`WanHealthClient`, and
`DeterrenceClient`/`WanDeterrenceClient` — is already referenced from at least one screen or the
controller feeding it.

---

## Full detail table

| Screen (file) | Element/action | Status | Client code covering it | Notes |
|---|---|---|---|---|
| `login/login_screen.dart` | Sign in | ✅ | `auth_api.md` (`AuthController.signIn`) | |
| `login/forgot_password_screen.dart` | Request/confirm reset code | ✅ | `auth_api.md` (`forgotPassword`/`confirmForgotPassword`) | |
| `signup/signup_screen.dart` | Sign up | ✅ | `auth_api.md` (`signUp`) | |
| `signup/confirm_signup_screen.dart` | Confirm code / resend | ✅ | `auth_api.md` (`confirmSignUp`/`resendConfirmationCode`) | |
| `splash/splash_screen.dart` | Session restore / initial route | ✅ | `auth_api.md` (`AuthController.restore`) | |
| `account/account_screen.dart` | Sign out | ✅ | `auth_api.md` (`signOut`) | `_mockAppVersion` literal is cosmetic, not a data gap |
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
| `alerts/alert_detail_screen.dart` | Alert detail view | ✅ | `camera_alerts_hub.md` / `alerts_api_config.md` (`Alert` data passed in) | Media view thumbnail-only by design |
| `alerts/alert_settings_screen.dart` | Deterrence durations, response actions | ✅ | `camera_api.md` (`WanEventPreferencesClient`/`WanEventResponseActionsClient`/`DeterrenceClient`/`WanDeterrenceClient`) | |
| `events/events_screen.dart` | Event list/filter | ✅ (recording band ⚠️) | `events_controller.dart` (real, but seeded — see Quick Wins) | EVT-025 band, see Quick Wins |
| `events/event_detail_screen.dart` | Event detail | ⚠️ | `RecordingsClient`/`WanRecordingsClient` | see Quick Wins |
| `events/events_summary_screen.dart` | Analytics/breakdown charts | ⚠️ (inherited) | `events_controller.dart` | Derived from the same seeded data |
| `camera_live/camera_live_screen.dart` | Live view, playback, snapshot, deterrence, talk | ✅ | `camera_api.md` (`SnapshotClient`/`WanPreviewSnapshotClient`, `AwsWanLiveViewClient`, `RecordingsClient`/`WanRecordingsClient`, `WanClipPlaybackClient`+`KvsMediaLiveViewSession` (with `heartbeat()`), `OnvifReplayControlClient`, `DeterrenceClient`/`WanDeterrenceClient`) | Confirmed live (no longer provisional) — H.265 live/playback and LAN one-session fixes landed here |
| `camera_live/ai_mode_screen.dart` | Object/person Q&A | ❌ | — | see Blocked |
| `camera_settings/audio_screen.dart` | Mic gain, speaker volume | ✅ | `camera_api.md` (`AudioCapabilityClient`/`SpeakerVolumeClient`/`AudioVolumeClient`/`WanAudioVolumeClient`/`WanSpeakerVolumeClient`) | |
| `camera_settings/camera_info_screen.dart` | Device identity, health, timezone | ✅ | `camera_api.md` (`OnvifDeviceClient`, `WanDeviceIdentityClient`, `WanHealthClient`/`HealthClient`) | Timezone falls back to static list only when camera reports none |
| `camera_settings/danger_zone_screen.dart` | Reboot / factory reset | ✅ | `camera_api.md` (`OnvifDeviceClient`/`WanDeviceIdentityClient`) | |
| `camera_settings/imaging_screen.dart` | Brightness/contrast/WDR/anti-flicker/mirror-flip/etc. | ✅ | `camera_api.md` (`OnvifImagingClient`/`WanImagingClient`/`WanImageQualityClient`/`WanAntiFlickerClient`/`WanMirrorFlipClient`) | Sliders use camera-reported ranges, not hardcoded 0–100 |
| `camera_settings/night_mode_screen.dart` | Night vision type | ✅ | `camera_api.md` (`NightVisionClient`/`WanNightVisionClient`) | |
| `camera_settings/on_screen_display_screen.dart` | OSD text/position | ✅ | `camera_api.md` (`OsdClient`/`WanOsdClient`, `Media2CapabilitiesClient`) | Font-size control still unbuildable (no setter accepts font size) — pre-existing, unrelated to this pass |
| `camera_settings/person_detection_screen.dart` | Loitering duration, bbox overlay, event prefs | ✅ | `camera_api.md` (`LoiteringDurationClient`/`WanLoiteringDurationClient`, `BboxOverlayClient`/`WanBboxOverlayClient`, `WanEventPreferencesClient`) | |
| `camera_settings/privacy_mode_screen.dart` | Privacy masks/toggle | ✅ | `camera_api.md` (`MaskClient`/`WanMaskClient`, `PrivacyModeClient`/`WanPrivacyModeClient`) | |
| `camera_settings/storage_screen.dart` | SD card status/format, recordings list | ✅ | `camera_api.md` (`LocalStorageClient`/`WanLocalStorageClient`, `RecordingsClient`/`WanRecordingsClient`) | Recordings tab: LAN first, WAN fallback |
| `camera_settings/video_mode_screen.dart` | Mirror/flip | ✅ | `camera_api.md` (`MirrorFlipClient`/`WanImagingClient`) | |
| `camera_settings/video_encoder_screen.dart` | Per-stream summary/landing list | ✅ | `OnvifVideoEncoderClient.getProfiles()` (discovers streams live; no hardcoded 3-row list) | Real settings wiring in `video_stream_encoder_screen.dart` |
| `camera_settings/video_stream_encoder_screen.dart` | Resolution (width×height)/bitrate/codec per stream | ✅ | `camera_api.md` (`OnvifVideoEncoderClient`/`WanVideoEncoderClient`) | No `CameraResolution` enum remains; real width×height used |
| `camera_settings/wifi_config_screen.dart` | WiFi SSID/signal/setup | ✅ | `camera_api.md` (`NetworkInfoClient`) | |
| `camera_settings/recording_screen.dart` | Recording mode + schedule | ❌ | — | see Blocked (candidate file sitting un-reviewed in inbox) |
| `camera_settings/parking_monitoring_screen.dart` | Parking zone config | ❌ | — | see Blocked |
| `camera_settings/intrusion_detection_screen.dart` | Intrusion zone config | ✅ | `camera_api.md` (via `camera_sync.dart` → `MaskClient` family) | |
| `camera_settings/line_crossing_screen.dart` | Line-crossing config | ✅ | `camera_api.md` (via `camera_sync.dart`) | |
| `camera_settings/motion_detection_screen.dart` | Motion detection toggle | ✅ | `camera_api.md` (via `camera_sync.dart`) | |
| `camera_settings/vehicle_detection_screen.dart` | Vehicle detection toggle | ✅ | `camera_api.md` (via `camera_sync.dart`) | |
| `camera_settings/tags_screen.dart` | Camera tags | ✅ | `camera_api.md` (via `camera_sync.dart`) | |
| `camera_settings/detections_screen.dart`, `video_display_screen.dart`, `camera_settings_screen.dart` | Navigation menus | N/A | — | Pure nav to sub-screens above |
| `multiview/multiview_screen.dart` | Grid live view, deterrence | ✅ | `camera_api.md` (`SnapshotClient`/`WanPreviewSnapshotClient`, `DeterrenceClient`/`WanDeterrenceClient`) | |
| `multiview/multiview_reorder_screen.dart` | Reorder tiles | N/A | `homes_controller.dart` | Local ordering preference |
| `scan/scanned_devices_screen.dart` | LAN discovery, connect | ✅ | `camera_api.md` (`WsDiscoveryClient`, `OnvifDeviceClient`) | |
| `scan/add_camera_manually_dialog.dart` | Manual host entry | ✅ | `camera_api.md` (`CameraConnection`, `OnvifDeviceClient`) | |
| `scan/scanning_popup.dart` | Scan progress UI | N/A | `app_state/camera_scan.dart` | UI shell around scan controller |
| `dashboard/dashboard_screen.dart` | Camera tiles, quick actions | ✅ | `camera_sync.dart`, `live_view_controller.dart`, `alerts_controller.dart` | Aggregates already-wired controllers; embedded events preview inherits `events_controller.dart`'s seed-data gap |
| `homes/manage_homes_screen.dart` | Home/camera list management | N/A | `homes_controller.dart` | Local grouping/naming |
| `shell/main_shell.dart` | Bottom-nav shell | N/A | — | Pure routing shell |

## What this means for next steps

- **⚠️ Quick Wins** (`events_screen.dart`, `event_detail_screen.dart`, `events_controller.dart`):
  `/integrate-client-code` can close these now — `RecordingsClient`/`WanRecordingsClient` and the
  `WanClipPlaybackClient`+`KvsMediaLiveViewSession` pattern are already documented and already
  integrated elsewhere (`camera_live_screen.dart`), so this is wiring, not new client work.
- **❌ Blocked** items (`recording_screen.dart`, `parking_monitoring_screen.dart`,
  `active_sessions_screen.dart`, `users_invites_screen.dart`, `create_user_screen.dart`,
  `invite_user_screen.dart`, `camera_access_screen.dart`, `ai_mode_screen.dart`,
  `notification_preferences_screen.dart`): each needs a new file/capability from the senior
  engineer first, run through `client-code-docs`, before there's anything to integrate.
  `recording_screen.dart` may be closest — a `RecordingModeClient`/`WanRecordingModeClient`
  candidate already sits un-reviewed in `client_code_inbox/packages/camera_api/`.
- **🆕** — none found this pass; nothing here is new-screen/new-element work subject to the
  plan-before-code rule.
