# VideoEncoderScreen

- **Dart file:** `lib/screens/camera_settings/video_encoder_screen.dart`
- **Route:** `/dashboard/live/:cameraId/settings/video-display/video-encoder`
- **Purpose:** Reached from the "Video Encoder" row on [video_display_screen.md](video_display_screen.md). **Redesigned 2026-09-10** from a single settings form into a landing list: the camera has multiple independently-configurable encoder streams, so this screen now lists one row per stream (High-res / Medium / Low), each with a live summary of that stream's current settings, and tapping a row opens [video_stream_encoder_screen.md](video_stream_encoder_screen.md) — the same full settings form as before — scoped to just that stream. Each stream keeps its own separate Save / Reset / Reload cycle and its own unsaved-changes prompt on the detail screen; there is no combined "save all streams" action, matching the ONVIF API shape (one `SetVideoEncoderConfiguration` call per configuration token).

## Elements

| Design ID | Element | Type | Notes |
|-----------|---------|------|-------|
| ENC-001 | Screen title (AppBar) | Text | "Video Encoder" |
| ENC-019 | High-res stream row | `ListTile` in a `GlassCard` | title "High-res stream"; subtitle is a live one-line summary of the stream's current settings from `camera.encoderConfigFor(VideoStream.highRes)` (e.g. "2560×1440 · H.265 · 4.0 Mbps · 15 fps" — real pixels, not a bucketed tier); trailing chevron; tapping pushes [video_stream_encoder_screen.md](video_stream_encoder_screen.md) with `(camera, VideoStream.highRes)`. Backed by `OnvifVideoEncoderClient` (`VideoEncoderCfg_1`). **Rendered only if the camera reports this encoder config** — see the note below. |
| ENC-020 | Medium stream row | `ListTile` in a `GlassCard` | title "Medium stream"; subtitle summary from `camera.encoderConfigFor(VideoStream.medium)`; trailing chevron; tapping pushes the detail screen with `VideoStream.medium`. |
| ENC-021 | Low stream row | `ListTile` in a `GlassCard` | title "Low stream"; subtitle summary from `camera.encoderConfigFor(VideoStream.low)`; trailing chevron; tapping pushes the detail screen with `VideoStream.low`. |

**Stream reality (2026-09-11 — all three real):** `OnvifVideoEncoderClient`/`WanVideoEncoderClient` were generalized from being hardcoded to `VideoEncoderCfg_1` (high-res only) to addressing any video encoder config by token — `kHighResVideoEncoderToken`/`kMediumResVideoEncoderToken`/`kLowResVideoEncoderToken` (`VideoEncoderCfg_1`/`_2`/`_3`, `Profile_1`/`_2`/`_3`). Medium and Low are no longer local-only staged state — each has its own real LAN (ONVIF) + WAN Get/Set/Options round trip, exactly like High-res, just addressing a different config token (`video_stream_encoder_screen.md`'s `_configTokenFor`). Previously (through 2026-09-10) Medium/Low were local-only placeholders (`simulateCameraSave`) pending this client generalization — see git history if that placeholder behavior is ever needed for reference.

**Retired design IDs** (2026-09-10 — the single-form elements all moved to [video_stream_encoder_screen.md](video_stream_encoder_screen.md) as `SENC-*`): `ENC-002` (Save), `ENC-003` (Resolution), `ENC-007`–`ENC-013` (encoder/profile/frame-rate/GOV/quality/bitrate-mode/bitrate), `ENC-014` (Reset to Default), `ENC-015`–`ENC-017` (unsaved-changes dialog + buttons), `ENC-018` (Reload). Already-retired: `ENC-004` (Frame Rate radio), `ENC-005` (Bitrate radio), `ENC-006` (Codec radio).

## Stream list is discovered, not assumed (2026-09-21)

The three rows are no longer rendered unconditionally. On open, the screen calls
`OnvifVideoEncoderClient.getProfiles()` and shows only the streams whose encoder-config token
(`VideoEncoderCfg_1`/`_2`/`_3`) the camera actually reports — `SETTINGS_API_GUIDE.md` is explicit
that a count or a `VideoEncoderCfg_N` list must never be hardcoded.

ENC-019/020/021 keep their 1:1 meaning (High-res / Medium / Low); a stream the camera does not
report simply has no row. Until that call resolves — and on any camera with no saved connection,
a failed lookup, or an empty result — **all three rows are shown**, the previous behavior, so a
bad round trip never hides real streams.
