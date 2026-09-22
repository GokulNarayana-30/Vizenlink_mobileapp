# camera_api — Live View Streaming Guide (WebRTC/RTSP LAN + KVS WAN)

This file explains how to implement live-view playback end-to-end, on both transports. It exists
because `API_REFERENCE.md` documents `camera_api`'s clients one class at a time (what each
method does), and `SETTINGS_API_GUIDE.md`'s "Cloud Streaming" entry is a one-paragraph pointer —
neither walks through the actual multi-step sequence, the wire formats a from-scratch
implementation needs, or the failure modes a robust client has to anticipate. This guide does
that, for a team implementing its own live-view session/reconnect logic on top of the existing
`camera_api` clients — the same way this app's own `LiveViewController`/`LiveViewScreen`
(`mobile_app/lib/features/live_view/`) do, rather than a working implementation handed to you.
Those two files are non-`flutter_webrtc`-package code specifically because `camera_api` is
pure-Dart with no `package:flutter` import — session-level WebRTC/video-player orchestration is
intentionally left as app-level business logic, not something this package provides.

## 1. Two transports, one decision rule (LAN itself has two sub-transports)

| | LAN — WebRTC | LAN — RTSP fallback | WAN (KVS) |
|---|---|---|---|
| When | Phone and camera on the same network, camera build has `WEBRTC_STREAMING` | Same network, but `WEBRTC_STREAMING` disabled camera-side (current default) | Phone away from home, or LAN unreachable |
| Latency | Sub-second (real-time peer connection) | Low (local remux, no cloud round trip) but not peer-to-peer real-time | ~3s above LAN observed on real hardware (encode → AWS ingestion → `GetMedia` fetch → remux) |
| Mechanism | Direct signaling to the camera, then a peer-to-peer media stream | Real RTSP session, remuxed to fMP4 over a local HTTP loopback for `video_player` (§2.5) | Camera pushes to AWS Kinesis Video Streams; phone pulls directly via `GetMedia`, remuxed to fMP4 over the same kind of local HTTP loopback (§3) |
| Audio | Playback only (downlink) | Playback only (downlink) | Playback only (downlink) |

Two-way talk is **not** part of any of these transports — it is a separate, dedicated audio-only
RTSPS connection on its own port, described in [TWO_WAY_TALK_GUIDE.md](TWO_WAY_TALK_GUIDE.md). It
works on LAN only (`FR-NE-081` WAN relay is `Planned`).

Which of the two LAN sub-transports you get is **decided by the camera, not the app** —
`GetLiveStreamUri`'s `output.transport` field says which one (§2.1). The app never chooses.

**Which to use is decided by real connectivity, never by comparing IP addresses or guessing from
network type.** Try LAN first; only fall back to WAN after a genuine LAN reachability failure
(§2's discovery call actually failing, confirmed by an independent reachability probe, not just a
slow response). Comparing the phone's current IP against a saved camera IP is fragile — VPNs,
mobile hotspots, guest WiFi VLANs, or a camera whose LAN IP simply changed since onboarding all
give a wrong answer.

**Capability-gate WAN before attempting it at all.** The camera reports `wanLiveViewCapable` via
`GetCapabilities` at onboarding time (`FR-NE-092`) — cache it, and skip the entire WAN sequence
(no Lambda/KVS calls at all) for a camera known not to support it, going straight to an explicit
"this camera doesn't support remote viewing" state instead of a wasted round trip ending in a raw
error. Treat an unknown/uncached value as capable (fail open) rather than blocking WAN for an
already-onboarded camera.

## 2. LAN path — WebRTC signaling, or RTSP fallback

**2026-09-07: the camera itself now picks the LAN transport** — WebRTC when its firmware build
has `WEBRTC_STREAMING` compiled in, RTSP(S) otherwise (the current default: `WEBRTC_STREAMING`
was disabled camera-side, module kept intact, not removed). This supersedes this guide's earlier
"RTSP is reserved for VMS/NVR, WebRTC is the LAN mobile path" framing (root `CLAUDE.md`'s Stream
consumer mapping) — that conclusion no longer holds, since a build with `WEBRTC_STREAMING` off
has no other LAN transport, and this app now actually plays that RTSP stream too (§2.3).

### 2.1 Discovery

There is no discovery mechanism built into the signaling socket (or the RTSP listener) itself —
resolve the live-view target first via the NuraEye REST endpoint `POST /nuraeye/live-stream-uri`
(`camera_api`'s `LiveStreamUriClient.getLiveStreamUri`, `FR-NE-127` — **replaces this guide's
former separate `GetWebRtcUri`, `FR-NE-090`**, merged into this one endpoint the same day):

```
Request:  POST /nuraeye/live-stream-uri  {"profile_token": "Profile_3"}
Response (WebRTC): {"error_code": 0, "error_msg": "Success",
           "output": {"transport": "webrtc", "port": <n>, "path": "/webrtc",
                      "url": "http://<camera-ip>:<port>/webrtc"}}
Response (RTSP):    {"error_code": 0, "error_msg": "Success",
           "output": {"transport": "rtsp", "port": <n>, "path": "/high"|"/medium"|"/low",
                      "url": "rtsps://<camera-ip>:<port><path>"}}
```

`profile_token` is `Profile_1`/`Profile_2`/`Profile_3` (Stream 0/1/2, high/medium/low — all three
are ordinary ONVIF profiles, reachable via `GetStreamUri` too, `FR-CF-010`). This call, and both
transports it can resolve, are **LAN-only by design** — there is no WAN counterpart and there
never will be one for either.

**Which profile live view requests (revised 2026-09-11):** the app no longer pins `Profile_3`.
`OnvifVideoEncoderClient.getProfiles()` returns every profile the camera has configured
(token, name, resolution, backing encoder config) and the live-view screens build a **Stream
Quality picker** from that list (`LIVE-058`/`LIVE-059`) — one chip per profile, labelled by its
resolution (`resolutionLabel`, e.g. "4MP"/"2MP"/"720p"), plus an **Auto** choice that maps WiFi
signal strength to a profile. Never hardcode "three streams": read the list and its length. The
chosen profile's `token` is what goes in `profile_token` above. `getProfiles()` is always re-fetched
live before a reconnect (never from the cache), because a stream's encoder config — and so its
resolution/codec — can change while a session is down. The old rule "only ever `Profile_3`" (a
2026-09-08 fix for a `LiveViewScreen` that requested the NVR-facing main stream by accident) is
superseded: the fix that mattered was replacing a bare `'Profile_1'` literal with an explicit,
user-visible choice.

Branch on `output.transport`, not on any assumption about which one you'll get:
- `"webrtc"`: `url` is **plain `http://`, not `https://`** — the signaling socket is
  unauthenticated and unencrypted by firmware design. This is acceptable because it never leaves
  the LAN. Continue with §2.2 below.
- `"rtsp"`: `url` is an RTSPS stream URL (RTSP-level Digest auth applies, same credentials as
  `/nuraeye`/`/onvif`). See §2.5.

### 2.2 Offer/answer

`POST` to the resolved URL (i.e. `POST /webrtc` on the camera) with:

```json
{"type": "offer", "sdp": "<your SDP offer>"}
```

- On success: `HTTP 200`, `Content-Type: application/json`, body `{"type": "answer", "sdp":
  "<answer SDP>"}` — negotiate this as your `RTCPeerConnection`'s remote description exactly as
  you would any other WebRTC answer.
- **No STUN/TURN — host candidates only.** This is a same-LAN connection; don't configure ICE
  servers expecting them to be used.

To end a session explicitly, `POST /webrtc/stop` (no body) — `HTTP 200` on success, tears down
the peer connection immediately camera-side.

### 2.3 The one-peer-connection-per-signaling-port constraint — read this before building anything else

**The camera supports exactly one `RTCPeerConnection` per signaling port.** Every accepted
`POST /webrtc` offer tears down whatever connection currently exists on that port first, no
exceptions — "Check if a connection was already established; if so, tear it down and rebuild a
new one" is literally what the firmware does on every offer (this is deliberate, to support rapid
start/stop/start reconnect attempts from a client).

**Practical consequence: never open a second, independent connection to the same signaling port
for a second purpose while a live-view connection is already open.** Doing so silently kills the
first connection the moment the second offer is accepted — this app's original two-way-talk
feature hit exactly this bug (talk opened a second connection, the two evicted each other in a
loop). Any future multi-purpose WebRTC feature must **renegotiate the existing connection** (fresh
offer, changed transceiver, same signaling exchange), never open a second one. (Two-way talk no
longer uses WebRTC at all — it has its own dedicated RTSPS connection, see
[TWO_WAY_TALK_GUIDE.md](TWO_WAY_TALK_GUIDE.md).)

### 2.4 Reconnect and health

- No push signal exists for "the camera closed the connection" beyond your own peer connection's
  `connectionState`/ICE state changes — watch those directly.
- With no STUN/TURN, a momentary ICE `disconnected` state is normal and routinely self-recovers
  within a few seconds (WebRTC's own periodic consent-freshness check causes this on an otherwise
  healthy LAN connection). **Don't tear down and reconnect on the first `disconnected` blip** —
  give it a grace window (a few seconds) to recover to `connected`/`completed` before treating it
  as a real drop. Ending the session on the first blip is a real bug this app hit and fixed.
- A genuinely dropped/failed connection should trigger a fresh `POST /webrtc` offer — this both
  re-establishes the connection and (per §2.3) cleanly replaces whatever stale connection state
  might be left camera-side, so a plain retry is the correct recovery, not something requiring
  special-casing.

### 2.5 RTSP fallback (`transport: "rtsp"`)

New 2026-09-07, added when the camera itself has no other LAN transport
(`WEBRTC_STREAMING` disabled camera-side). The RTSP(S) listener speaks a real RTSP/1.0 protocol
(`OPTIONS`/`DESCRIBE`/`SETUP`/`PLAY`/`TEARDOWN`, TCP-interleaved RTP, RFC 2617 Digest auth) — not
directly consumable by `video_player`/ExoPlayer/AVPlayer, so this app doesn't speak RTSP straight
to the player. Instead:

1. `RtspLiveViewSession` (`mobile_app/lib/features/live_view/rtsp/rtsp_live_view_session.dart`)
   is a real RTSP client — `DESCRIBE`+`SETUP`+`PLAY` against the resolved `url`, then depacketizes
   H.264 (RFC 6184 single-NAL/FU-A) and, if present, AAC (RFC 3640 AAC-hbr) off the interleaved
   RTP stream. **Adapted from** the pre-existing recorded-clip playback client
   (`../recordings/rtsp/rtsp_replay_client.dart`'s `RtspReplaySession`, itself the reason this
   app doesn't use `media_kit`/libmpv at all — see that file's own doc for the ten-iteration
   real-hardware history) — same protocol engine, with clip-specific concepts (seek, a bound
   clip's start/end epoch) dropped, since live view has neither.
2. `RtspLiveViewProxy` (`rtsp_live_view_proxy.dart`, adapted from `rtsp_remux_proxy.dart`) remuxes
   what that session reads into fragmented MP4 (`camera_api`'s `media/fmp4_muxer.dart`'s
   `RtspFmp4Muxer`, reused unchanged — its `totalDurationSeconds: null` is exactly the "unbounded
   live content" signal ExoPlayer needs) and serves it over a local HTTP loopback server
   (`http://127.0.0.1:<port>/live.mp4`).
3. `LiveViewScreen` points `VideoPlayerController.networkUrl()` at that loopback URL — from there
   it's rendered, muted, and snapshotted through the exact same code path the WAN (KVS `GetMedia`)
   transport already uses (both are just "a `video_player` session fed by a local loopback URI" —
   `KvsMediaLiveViewSession` reuses this same `RtspFmp4Muxer` too, see §3).

No seek, no pause/resume at the RTSP level (the camera's live-view RTSPS listener has no `PAUSE`
method — same limitation `../recordings/rtsp/rtsp_remux_proxy.dart`'s own doc describes for clip
playback). A dropped connection surfaces as the proxy's `isSessionEnded` going true (or a
`video_player` `hasError`) — reconnect by constructing a fresh `RtspLiveViewProxy` against a
freshly-resolved `getLiveStreamUri()` target, mirroring §2.4's WebRTC reconnect posture (a plain
retry, no special-casing).

## 3. WAN path — the three-step sequence

**Rewritten 2026-09-17 (`GetMedia` replaces HLS entirely) — this section previously described a
four-step HLS-based sequence (`resolvePlaybackUri` → a long-lived signed HLS URL → any HLS-capable
player). That path is gone.** It was replaced outright, not just for H.265 (which AWS's HLS/DASH
session-URL APIs reject outright — `UnsupportedStreamMediaTypeException` on
`GetHLSStreamingSessionURL`, `GetDASHStreamingSessionURL` has the identical restriction despite
more permissive-sounding prose) but for H.264 too, so the app has exactly one WAN playback code
path regardless of codec. If you're looking at an old integration or a stale mental model built
before 2026-09-17, the mental model to discard is "resolve a URL, hand it to an HLS player, the
URL stays valid for hours." The mental model below replaces it.

There is no single "connect" call — WAN live view is a sequence of independent steps, each with
its own failure modes. Steps 1-2 go through AWS IoT Core (MQTT command relay); step 3 vends
short-lived AWS credentials via a Lambda proxy and then talks to AWS KVS's `GetMedia` API
**directly from the app** — never a direct-from-app AWS SDK call for anything else in this
sequence (see §4 for why Steps 1-2 still go through the camera).

**`FR-CF-154` (2026-09-14): quality-selective, reference-counted, per-viewer leases.** Every KVS
stream (`high`/`medium`/`low`, one per `StreamQuality` value, named `<thing_name>-high`/
`-medium`/`-low` — the app must let the user pick which tier to watch, mirroring the LAN
RTSPS `/high`/`/medium`/`/low` picker) is a real, independently-billed AWS resource. The camera
never starts more than the requested tier, reference-counts concurrent viewers of the same tier
so they share one AWS session, and issues each `StartCloudStreaming` caller its own lease
**token** — `camera_api`'s `WanLiveViewClient` interface reflects this shape directly (see below);
there is no fire-and-forget "just start it" call anymore.

### Step 1 — `StartCloudStreaming(quality)`

Request/response MQTT command (`WanLiveViewClient.startCloudStreaming(StreamQuality quality)`,
`params.quality` = `"high"`/`"medium"`/`"low"`). Tells the camera to begin pushing that one
quality tier to its configured KVS channel (or, if another viewer already has it running, just
increments the camera-side reference count — no new AWS session). Returns the viewer's lease
**token** (an `int`) on success — keep it, every later call for this session needs it. This call
succeeding only means the command was delivered — it does not mean video is flowing yet (see §4
on why `stream_status: active` isn't sufficient evidence either).

**Only call this when the user actually wants to watch — never from a screen's own "just check
reachability" path.** Direct user hardware report, 2026-09-18: each `quality` tier is a real,
individually-billed AWS resource (see the `FR-CF-154` note above), and this app's own
`LiveViewController` was calling this step unconditionally from several silent "ping the camera"
call sites (screen open, network reconnect, app resume) — starting real cloud billing every time
the live-view screen was merely opened, not actually watched. Fixed via
`LiveViewController.start({bool allowWan})`: every eager/silent call site passes `allowWan: false`
(a cheap LAN-only reachability check, stopping short of ever reaching this step); only an explicit
user action (tapping play, or a manual retry) uses the default `allowWan: true`. Any WAN client you
build should keep the same separation between "is the camera reachable" and "the user wants to
watch" as two distinct questions, with only the second one ever reaching this call.

### Step 2 — `GetCloudStreamingStatus(token)`, with retry — also the heartbeat

Request/response MQTT command (`getCloudStreamingStatus(token)`) returning one of:

| Value | Meaning |
|---|---|
| `active` | Camera believes it is currently pushing frames for this viewer's tier. **Does not guarantee AWS is accepting them** — see §4. |
| `idle` | Not streaming, no known failure — the normal resting state before any client requests it. Also a **normal transient state immediately after `StartCloudStreaming`** while the substream spins up — retry a couple of times before treating this as a real problem. |
| `degraded` | Not streaming, and the last 3+ consecutive connection attempts failed. |
| `notCompiled` | This firmware build doesn't have KVS support compiled in at all — don't retry, there's nothing to wait for. |

**This call is also the lease heartbeat.** Passing `token` refreshes the camera-side lease for
that viewer; a token not refreshed within **30 seconds** is dropped automatically
(`bsp_camera_pollKvsViewerLeases()`, firmware-side), and once the last viewer's reference drops,
the camera tears the AWS session down to stop paying for it. Call this **at least every 30s**
for the lifetime of the session, not just once at connect time — this app's own periodic WAN
health poll (`LiveViewController._checkWanHealth`, default every 10s) does this for free, since
its existing health check already calls `getCloudStreamingStatus` on that cadence.

### Step 3 — `startMediaSession(quality)` → a live `KvsMediaLiveViewSession`

Once `active`, start real playback: `WanLiveViewClient.startMediaSession(quality)` internally (a)
vends short-lived, stream-scoped AWS credentials via the Lambda proxy
(`KvsMediaViewerCredentialsClient` → the deployed `cloud_backend/kvs_playback_lambda` Function
URL's `mode=media` action — the Lambda's execution role is used only to *mint* these credentials;
no media bytes ever pass through the Lambda itself), then (b) opens a **direct** signed AWS KVS
`GetMedia` connection from the phone (`KvsGetMediaClient`), demuxes the raw MKV byte stream
(`MkvDemuxer`), remuxes it into fMP4, and serves that over a **local HTTP loopback server inside
the app**. `startMediaSession` returns the already-connected `KvsMediaLiveViewSession`; its `url`
field (`http://127.0.0.1:<port>/stream.mp4`) is what you hand to your player — never an
AWS/CloudFront URL directly.

**This is a live, per-attempt resource, not a reusable signed URL — the biggest behavioral change
from the old HLS model.** `KvsMediaLiveViewSession` owns a real background `GetMedia` connection
and a real local server for as long as it exists; there is no "the URL is still valid, just
reconnect the player to it" recovery path anymore (see §5). On any disconnect/error, `stop()` the
session and construct a **fresh** one via `startMediaSession` again — never retry against an old
instance's `url`.

The substream can legitimately still be spinning up for a few seconds after `StartCloudStreaming`
reports `active` — retry `startMediaSession` a few times (e.g. 3 attempts, ~2s apart) before
treating a failure here as terminal, mirroring step 2's own retry posture.

### Step 4 — play the local loopback URL

Play `KvsMediaLiveViewSession.url` with any ordinary progressive-MP4-capable player — this app
uses `video_player` (ExoPlayer/AVFoundation natively). From the player's point of view this is a
completely ordinary local HTTP source; it has no idea AWS or MKV are involved at all. Leave the
declared duration unbounded (`0`) — that's the correct "genuinely live content" signal for
ExoPlayer, not a bug to fix (see `camera_api`'s `media/fmp4_muxer.dart`'s `totalDurationSeconds`
doc for the real-hardware-tested reasoning, and `API_REFERENCE.md`'s `KvsMediaLiveViewSession`
entry for a case study of what goes wrong if you give it a fake non-zero duration instead).

### Ending the session

`stopCloudStreaming(token)` (fire-and-forget, same shape as the pre-`FR-CF-154` Stop) — available
on **both** transports: the WAN/MQTT command, and (added for exactly this reason) a LAN
`/nuraeye` action of the same name (`CloudStreamingLanClient.stopCloudStreaming()` — no token,
LAN's own action is the older blunt "stop every quality" behavior, unaffected by this rework). If
you've just confirmed the camera is reachable on LAN (e.g. switching back from WAN because the
phone came back onto the home network), prefer the LAN stop call — it avoids an unnecessary
AWS/Lambda round trip for a camera you can already reach directly. Fall back to the WAN stop only
if the LAN attempt itself fails.

**Send `stopCloudStreaming(token)` even if your session never fully reached "playing."** A real
bug found in this app: if `startCloudStreaming()` succeeds but the session is torn down before
playback resolution completes (steps 2-3 still in flight), the camera has *already* incremented
its reference count for this viewer. Skipping the stop call in that window leaves the lease to
expire on its own via the 30s heartbeat timeout rather than releasing it immediately — track "did
I get a token back from Start" as a fact independent of whatever UI/connection state your app
happens to be in, and always pair it with a Stop using that same token.

### Switching quality tier mid-session

There is no "change quality" command — switching tiers means stopping the current lease
(`stopCloudStreaming(oldToken)`) and starting a fresh one on the new quality
(`startCloudStreaming(newQuality)` → new token), same as a reconnect. See
`LiveViewController.setWanQuality` for the reference implementation (tears down the old lease,
re-runs the connect sequence above on the new tier).

### Session resilience (`KvsMediaLiveViewSession`)

The session keeps one continuous player-facing stream across `GetMedia` connection changes:
- **Credential refresh.** The vended credentials are re-vended `credentialRefreshMargin` (default
  60 s) before `expiration` and `GetMedia` is re-opened with them; the previous connection is
  retired only after the new one is attached.
- **Transparent re-establish.** If `GetMedia` ends (AWS connection cap, network drop) or errors,
  the session reconnects with exponential backoff (`reconnectBackoff`, `maxReconnectAttempts`,
  default 3). The muxer, init segment and connected loopback HTTP clients survive, so the player
  sees no restart. Consecutive failures reset on the first sample received; only when they
  exceed the cap (including connections that end without delivering any sample) does
  `isSessionEnded` become true and the caller need to rebuild a session. `stop()` also sets it.
- **Loopback backpressure.** Each HTTP client may have `maxPendingBytesPerClient` (default 2 MiB)
  queued. Over that, audio and non-keyframe video fragments are dropped for that client, which
  then waits for the next keyframe before receiving video again. Keyframes are never dropped.

### WAN recorded-clip playback

The same session plays recorded clips: `WanClipPlaybackClient` (commands 75–79) makes the camera
stream a clip into the dedicated KVS stream `<thingName>-playback`
(`wanClipPlaybackStreamName`), and `KvsMediaLiveViewSession(streamName: ...)` plays it.
`WanRecordingsClient` (commands 80/81) lists dates and clips first. The camera gives no end-of-clip
signal — treat a long silence in `lastSampleAt` as the end of the clip. One playback session
camera-wide; seek and pause in the app are stop + restart at the new offset. Credentials for the
`-playback` stream come from the same `mode=media` Lambda action.

## 4. What `stream_status` does and doesn't tell you

`GetCloudStreamingStatus`/`stream_status` is derived entirely from the camera's own view of its
publish loop — it does not observe AWS's fragment-acknowledgement responses at all. A real
incident (`BUG-023`, firmware-side) found `stream_status: active` reported continuously for over
30 seconds while **every single fragment was being silently rejected by AWS** — the firmware log
and the status query were both blind to it; the only way to get ground truth was checking AWS
directly:

```bash
ENDPOINT=$(aws kinesisvideo get-data-endpoint --stream-name <name> \
  --api-name LIST_FRAGMENTS --region <region> --query DataEndpoint --output text)
aws kinesis-video-archived-media list-fragments --stream-name <name> \
  --endpoint-url "$ENDPOINT" --region <region> \
  --fragment-selector '{"FragmentSelectorType":"PRODUCER_TIMESTAMP",
    "TimestampRange":{"StartTimestamp":"<start>","EndTimestamp":"<end>"}}' \
  --query 'length(Fragments)'
```

That specific defect is fixed camera-side now (see §6), but the underlying fact remains: **`active`
means "the producer believes it's pushing," not "video is actually landing."** If you're building
diagnostics or a "why isn't this working" support path, don't stop at `stream_status` — a stalled
player with `stream_status: active` and no picture is a real, distinct failure mode from a
`degraded` status, and needs different handling (the stream itself needs investigating, not just
"retry the connection").

## 5. Reconnect and failure semantics — read this before writing your recovery logic

**Rewritten 2026-09-18 — the "same URL, just reconnect" recovery model this section used to
describe no longer applies at all.** Since the 2026-09-17 `GetMedia` migration (§3),
`KvsMediaLiveViewSession` is an explicitly **non-reusable, one-per-attempt** resource — there is
no long-lived URL to fall back to; every recovery path below ends the same way, constructing a
fresh session via `startMediaSession` again.

Camera-visible trouble and phone-visible trouble are still two different signals needing two
different watchers — there is no single live push signal for WAN the way LAN's ICE connection
state is one:

1. **Camera-visible**: poll `GetCloudStreamingStatus` periodically while playing (this app uses a
   10s interval). A cheap LAN-reachability probe first, each tick, is worth doing before spending
   the paid AWS/Lambda call — if the phone has come back onto the camera's LAN, switch to the LAN
   path entirely rather than continuing to poll WAN. On `degraded`/`idle`/a failed status call,
   tear down and restart from Step 1.
2. **Phone-visible**: watch your player's own error signal (`hasError`), **and** a real
   data-arrival ground truth — `KvsMediaLiveViewSession.lastSampleAt`, a timestamp updated every
   time a real MKV sample is actually demuxed off the wire, independent of whatever the player
   itself reports.

**Do not use `video_player`'s own position as a stall signal — real-hardware finding, 2026-09-18:
for this genuinely live (unbounded-duration) stream, `VideoPlayerController.value.position` was
observed staying pinned at a near-zero constant (`~0.001s`) for an entire multi-minute session
*regardless of whether playback was actually healthy* — including sessions later confirmed, by
direct visual inspection, to be playing correctly.** A naive "has the position advanced in the
last N seconds" poll — the pattern this section previously recommended — produces exactly the same
reading whether the stream is frozen or perfectly fine, so it can't tell them apart on its own.
This app's `LiveViewScreen._pollWanStall` learned this the hard way twice: first it used a
position-only check and repeatedly tore down/reconnected a perfectly healthy KVS session (visible
as a freeze/reconnect cycle roughly every 20s, confirmed via `lastSampleAt` proving real data was
still arriving the whole time); the fix is to check `lastSampleAt` **first** and only fall through
to the position heuristic — treating it only as a *secondary, not-fully-trustworthy* signal — when
`lastSampleAt` itself shows no recent sample, i.e. a genuinely dead connection. See
`rtsp_live_view_session.dart`'s `lastPacketAt` (`BUG-030`) for the LAN-side twin of this same
ground-truth pattern — `lastSampleAt` is its direct WAN counterpart, added specifically because the
LAN fix was never extended to WAN until this incident.

**Reconnect is always "stop the old session (if any), start a fresh one" — never "retry the same
`url`."** The camera can also legitimately stop the KVS stream outright mid-session — this
happens, among other triggers, whenever a client toggles the camera's mic on/off while WAN
streaming is active (see §6). This is expected, correct camera-side behavior, not corruption, and
(since `FR-CF-154`, 2026-09-14) the camera does **not** bring the stream back on its own — a fresh
§3 sequence from Step 1 is required either way, which conveniently means this case and an ordinary
phone-side hiccup now need the *same* recovery code path (unlike the old HLS model, which drew a
real distinction between them). Prefer reacting to `CloudStreamStopped` (§6) over waiting to notice
via a failed poll/stall detection at all, where you can.

## 6. The audio-track/mic-toggle interaction, and camera-initiated stops in general

`SetAudioRecording`/`GetAudioRecording` (`FR-NE-078`, `AudioVolumeClient`/`WanAudioVolumeClient`
in `camera_api`) toggles whether the camera is capturing microphone audio at all — the same
underlying camera state on both LAN and WAN transports ("one state, two transports"). **If cloud
streaming is currently active, toggling this forces the camera to immediately stop the affected
KVS stream(s)** so the stream's track composition (whether an audio track is declared at all)
never drifts out of sync with what's actually being fed to it (the failure this guards against,
found and fixed in `BUG-023`, was a stream stuck declaring an audio track nobody was feeding,
which AWS rejects outright). A stream resolution change (video re-init) stops any of that specific
tier's active stream the same way.

**`FR-CF-154` (2026-09-14): the camera no longer self-reconnects after either trigger** — it was
a self-managed `STOP`+`RECONNECT` before, adding complexity the camera doesn't need to carry;
now it's a plain stop, matching how a LAN RTSP client is simply disconnected and left to redial
itself. A WAN viewer whose stream was stopped this way must reconnect from Step 1
(`startCloudStreaming`) — same as any other WAN session start — not assume the camera will bring
it back. To reconnect promptly rather than waiting for the next `GetCloudStreamingStatus` poll to
notice, subscribe to the `CloudStreamStopped` alert-topic event (fired once per stop, cause-
agnostic — covers both the audio toggle and a resolution change) and treat it as a trigger to
restart the connect sequence immediately.

## 7. Client reference

Everything above is implemented by these existing `camera_api` classes — see `API_REFERENCE.md`
for exact method signatures:

| Purpose | Class |
|---|---|
| LAN live-view discovery (`GetLiveStreamUri` — resolves WebRTC or RTSP) | `LiveStreamUriClient` |
| LAN reachability probe | `LiveStreamUriClient.checkReachable` |
| LAN cloud-streaming status/stop | `CloudStreamingLanClient` |
| WAN command relay (low-level) | `IotCommandClient` |
| WAN media-viewer AWS credential vending (Lambda `mode=media`) | `KvsMediaViewerCredentialsClient` |
| WAN direct `GetMedia` fetch | `KvsGetMediaClient` |
| WAN MKV demux (`GetMedia`'s raw wire format) | `MkvDemuxer` (`wan/kvs_media/mkv_demuxer.dart`) |
| fMP4 remux (init segment + fragments) — shared with the LAN RTSP path | `RtspFmp4Muxer` (`media/fmp4_muxer.dart`) |
| WAN live playback session (credentials + `GetMedia` + demux + remux + local HTTP loopback, one class) | `KvsMediaLiveViewSession` |
| WAN live-view session (quality-selective Start/Stop/Status/`startMediaSession`, lease token, one interface) | `WanLiveViewClient` / `AwsWanLiveViewClient` |
| WAN audio-recording toggle | `WanAudioVolumeClient` |

**`KvsPlaybackClient`/`resolvePlaybackUri` — removed 2026-09-17**, along with the HLS session-URL
flow it backed. If you see either name referenced anywhere (an old branch, a cached mental model,
search results from before that date), it no longer exists in this codebase — `startMediaSession`/
`KvsMediaLiveViewSession` replaced it outright, not alongside it.

None of these implement the offer/answer negotiation, the reconnect state machine, or the
transport-selection logic described above — that's the layer you build on top, same as this app's
own `LiveViewController`/`LiveViewScreen` do (not shipped as reusable `camera_api` code — see the
note at the top of this file for why).

## 8. Known limitations (as of 2026-09-18)

- **Medium-quality WAN playback (H.264) is hardware-verified end-to-end** as of 2026-09-18 (§3's
  `GetMedia`/`KvsMediaLiveViewSession` path, the `lastSampleAt` stall-detection fix in §5). **High
  quality is not** — a persistent KVS `PutMedia` `FRAMES_MISSING_FOR_TRACK` (`errorId=4011`)
  failure loop was found on the camera/KVS-producer side specifically for the high-quality stream,
  unrelated to the medium-quality fixes above and not yet root-caused. Low quality is untested.
- `FR-CF-154`'s server-side pieces (quality-selective start/stop, reference counting, 30s lease
  timeout, `CloudStreamStopped` event) are build-verified firmware-side only — **not yet
  hardware-verified** as of this writing.
- No WAN talk (two-way audio) — see `TWO_WAY_TALK_GUIDE.md`.
- `stream_status: active` is not sufficient evidence of a healthy stream (§4) — no fix planned,
  this is inherent to what the status derivation observes; build your own diagnostics around it
  rather than expecting a firmware change.
- No resolution/bitrate telemetry exists for the WAN path (`GetMedia` gives no equivalent of
  WebRTC's `inbound-rtp` stats report) — if you need live quality metrics on WAN, you'll need to
  derive them from player-level buffering/stall signals or `KvsMediaLiveViewSession`'s own sample
  arrival cadence, rather than a byte-count-based bitrate the way LAN can.
- WAN-vs-LAN latency is inherently higher (encode → AWS KVS ingestion → phone's `GetMedia` fetch →
  demux/remux, vs. LAN's near-zero-hop direct connection) — roughly ~3s observed on real hardware
  post-fix. Don't expect to close this gap to zero; a much larger, *growing* gap is a sign of the
  player-drift class of bug §5 describes, not normal WAN overhead.
