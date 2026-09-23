import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:alerts_api/alerts_api.dart';
import 'package:camera_api/camera_api.dart';

import 'camera_network.dart';
import 'transport_preference.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';
import 'package:video_player/video_player.dart';

import '../rtsp/rtsp_live_view_proxy.dart';
import '../rtsp/rtsp_talk_session.dart';

enum LiveViewStatus { connecting, connected, reconnecting, failed, stopped }

/// Which transport actually delivered the current/last [LiveViewStatus]
/// `connected` session — [LiveViewStatus] alone doesn't say whether the
/// video came from the LAN WebRTC path or WAN KVS playback, and the UI
/// (`RTCVideoView` vs a plain HLS `VideoPlayerController`) needs to know
/// which. See `STREAMING_GUIDE.md` §1's transport-selection rule.
enum LiveViewTransport { lan, wan }

/// `TWO_WAY_TALK_GUIDE.md` §5's call-style state machine. [busy] is the
/// camera's `HTTP 409` response (another talk session already active) —
/// deliberately distinct from [error], since it means "try again later,"
/// not "something is broken."
enum TalkStatus { idle, connecting, talking, busy, error }

/// LAN WebRTC live-view session for one camera — implements
/// `packages/camera_api/STREAMING_GUIDE.md`'s §2 LAN path end to end:
/// `GetLiveStreamUri` discovery, offer/answer signaling (no STUN/TURN — host
/// candidates only, per the guide), a grace window before an ICE
/// `disconnected` blip is treated as a real drop (the guide flags skipping
/// this as a real bug hit before), fresh-offer reconnect on a genuine drop,
/// and a best-effort `POST /webrtc/stop` on teardown even if the session
/// never fully connected (also flagged in the guide — skipping it can leave
/// the camera believing a viewer is still attached).
///
/// One instance per `CameraLiveScreen` visit, not cached/shared — the
/// camera supports exactly one peer connection per signaling port (guide
/// §2.3). Two-way talk ([startTalk]/[endTalk]) also lives here rather than
/// a separate class, precisely because `TWO_WAY_TALK_GUIDE.md` §2 requires
/// renegotiating *this* connection (a fresh offer with `talk: true` against
/// the existing audio transceiver) rather than opening a second one —
/// opening an independent connection for talk was a real bug during this
/// app's own development (the two connections evicted each other in a
/// loop).
class LiveViewController extends ChangeNotifier {
  /// [initialProfile] — one of [_profileLadder] (`Profile_1`/`Profile_2`/
  /// `Profile_3`). Lets a caller that already knows it only has a small
  /// display budget for this session (e.g. a Multiview grid tile) start
  /// below full resolution — the automatic ladder in
  /// [_maybeStepDownProfile]/[_maybeStepUpProfile] still applies on top of
  /// whatever this starts at.
  ///
  /// **Real bug fix, 2026-09-11**: when omitted, this used to default to
  /// [_profileLadder]'s first entry (`Profile_1`, the full-resolution
  /// NVR/VMS-facing main stream) — per `STREAMING_GUIDE.md` §2.1, this
  /// app's own live view must always default to
  /// `kMobileOnlyStreamProfileToken` (`Profile_3`, the dedicated
  /// mobile-only stream) instead, never fall through to `Profile_1`/
  /// `Profile_2`. Only a caller that explicitly passes a different valid
  /// profile (Multiview's own bandwidth-budget reasoning above) still gets
  /// it — this only changes the *unset* default.
  LiveViewController(
    this.connection, {
    http.Client? httpClient,
    String? initialProfile,
    this.forceTransport,
  }) : _http = httpClient ?? http.Client(),
       _profileLadderEnabled =
           initialProfile != null && _profileLadder.contains(initialProfile),
       _profileToken =
           (initialProfile != null && _profileLadder.contains(initialProfile))
           ? initialProfile
           : kMobileOnlyStreamProfileToken;

  /// Real bug fix, 2026-09-11: fixing just the *default* starting profile
  /// (above) wasn't enough — [_nextLowerProfile]/[_nextHigherProfile]'s
  /// ladder-stepping could still auto-*promote* a healthy `Profile_3`
  /// session up to `Profile_2`/`Profile_1` later (on a sustained good-link
  /// run), which `STREAMING_GUIDE.md` §2.1 forbids outright: "live view
  /// must never fall through to `Profile_1`/`Profile_2` under any
  /// circumstance, including sustained LAN trouble." True only when a
  /// caller explicitly passed a valid [initialProfile] — i.e. Multiview's
  /// own per-tile bandwidth-budget use case, which legitimately wants
  /// automatic quality adjustment across all three tiers. The Live tab's
  /// default (no [initialProfile]) gets `false` here, pinning it to
  /// `Profile_3` permanently — [_nextLowerProfile]/[_nextHigherProfile]
  /// short-circuit to `null` in that case, so the ladder can never move it.
  bool _profileLadderEnabled;

  /// Opts this session into (or out of) the automatic profile ladder after
  /// construction — used by the Live tab's Stream Quality picker when the
  /// user selects/deselects "Auto" (`CameraStreamQuality.auto`). Historically
  /// (STREAMING_GUIDE.md §2.1) the Live tab's default session was pinned to
  /// never auto-switch at all, since a background change the user didn't ask
  /// for was found confusing; as of 2026-09-15 automatic switching is
  /// allowed again, but only while "Auto" is the user's own explicit choice
  /// — a manual High/Medium/Low pick must still stay pinned exactly as
  /// selected. [camera_live_screen.dart]'s `_onLiveViewChanged` surfaces
  /// every automatic change via [autoQualityChangeMessage] so it's never
  /// silent this time.
  void setAutoQualityLadder(bool enabled) {
    _profileLadderEnabled = enabled;
  }

  final CameraConnection connection;
  final http.Client _http;
  final renderer = RTCVideoRenderer();

  /// Grace window before an ICE `disconnected` state is treated as a real
  /// drop — see STREAMING_GUIDE.md §2.4.
  static const _iceDisconnectGrace = Duration(seconds: 5);

  /// How long the LAN discovery probe (`GetLiveStreamUri`) waits before deciding
  /// the camera isn't reachable on this network — tuned against real WiFi
  /// testing (matches the sibling `nuraeye-rt` app's `lanProbeTimeout`): long
  /// enough to absorb normal same-subnet variance, short enough that a phone
  /// genuinely off the camera's LAN doesn't wait needlessly before WAN is
  /// even attempted.
  static const _lanProbeTimeout = Duration(seconds: 4);

  /// How many times [_connectLan] retries `GetLiveStreamUri` before falling
  /// through to [_handleLanExhausted]'s reachability recheck. Raised from 1
  /// to 2, 2026-09-08, per a direct user report of the Live tab
  /// intermittently landing on the "Remote" (WAN) badge while genuinely on
  /// the same LAN as the camera — a single retry gives a real same-LAN
  /// camera only one extra chance to answer `GetLiveStreamUri` before this whole
  /// controller escalates to the much-higher-latency WAN path; a transient
  /// hiccup (the camera's embedded HTTP server briefly busy serving another
  /// concurrent LAN request from this same screen's other polls — signal
  /// strength, shortcut state, etc. — or ordinary same-subnet jitter) can
  /// plausibly outlast that in real conditions. This doesn't weaken the
  /// LAN-first/WAN-only-after-genuine-failure policy — [_handleLanExhausted]
  /// still independently reachability-checks before conceding to WAN either
  /// way — it just gives a real LAN camera a little more slack before that
  /// escalation happens at all.
  static const _maxLanReconnectAttempts = 2;
  static const _lanRetryPollInterval = Duration(seconds: 1);

  /// Once `GetLiveStreamUri` has exhausted its retries, how long the independent
  /// `AreYouNuraeyeDevice` reachability probe waits — distinguishes "camera
  /// isn't on this network at all" (falls to WAN) from "camera IS on this
  /// network but the signaling call itself glitched" (retries LAN instead of
  /// wrongly falling back to the much-higher-latency WAN path).
  static const _lanReachabilityCheckTimeout = Duration(seconds: 5);

  /// The health monitor's "are we back on the camera's LAN yet?" probe runs
  /// every tick for the whole life of a WAN session, and on WAN it can only
  /// ever time out — so its cost is paid over and over. A camera that *is* on
  /// the LAN answers `AreYouNuraeyeDevice` in milliseconds, so this needs to
  /// be only long enough to cover a slow local round trip, not the 3s default
  /// that left every WAN session stalling for 3s out of every tick (measured
  /// on real hardware, where it sat directly in front of user actions that
  /// then completed in ~300ms).
  static const _lanSwitchBackProbeTimeout = Duration(milliseconds: 1200);

  /// WebRTC signaling POST timeout — tightened from an earlier unbounded/10s
  /// value; a genuinely-unreachable-mid-negotiation camera should fail out
  /// quickly enough for reconnect/fallback logic to actually kick in.
  static const _webrtcSignalingTimeout = Duration(seconds: 5);

  /// Bound on waiting for ICE gathering to complete before sending the offer
  /// — see [_negotiate]'s doc comment for why this step exists at all.
  static const _iceGatheringTimeout = Duration(seconds: 3);

  /// `Profile_1` (highest resolution) down to `Profile_3` (lowest) — this
  /// firmware's fixed, compile-time profile set. [_profileToken] steps down
  /// this ladder on sustained LAN trouble and back up once the link recovers
  /// — see [_maybeStepDownProfile]/[_maybeStepUpProfile].
  static const _profileLadder = ['Profile_1', 'Profile_2', 'Profile_3'];
  static const _profileDisplayName = {
    'Profile_1': 'High',
    'Profile_2': 'Medium',
    'Profile_3': 'Low',
  };
  String _profileToken;

  /// The ONVIF profile token this session is currently requesting on LAN —
  /// read by the Stream Quality sheet to cross-reference against
  /// [lanProfiles] and highlight the actually-active tile.
  String get currentProfileToken => _profileToken;

  /// Set right before an automatic (ladder- or stall-driven, not a direct
  /// user pick) quality change reconnects — the screen shows this once as a
  /// SnackBar and clears it, so an "Auto" adjustment is always visible
  /// rather than a silent background change. `null` most of the time.
  String? autoQualityChangeMessage;

  /// Every media profile this camera currently reports (token/name/native
  /// resolution) — the real backing for the Stream Quality picker
  /// (LIVE-058/059), added 2026-09-11 alongside `OnvifVideoEncoderClient
  /// .getProfiles()`. `null` until [loadLanProfiles] has resolved at least
  /// once; a camera unreachable on LAN never populates this.
  List<MediaProfile>? get lanProfiles => _lanProfiles;
  List<MediaProfile>? _lanProfiles;

  /// Discovers (and caches) this camera's real media profiles via ONVIF
  /// Media2 `GetProfiles`. Cached after the first successful call — pass
  /// [forceRefresh] to re-fetch (e.g. the picker's own pull-to-refresh, or
  /// after a Video Encoder settings change that could have altered a
  /// profile's resolution).
  Future<List<MediaProfile>?> loadLanProfiles({
    bool forceRefresh = false,
  }) async {
    if (_lanProfiles != null && !forceRefresh) return _lanProfiles;
    final client = OnvifVideoEncoderClient(
      connection,
      httpClient: CameraNetwork.clientFor(connection.host),
      endpoint: CameraNetwork.media2EndpointFor(connection.host),
    );
    final result = await client.getProfiles();
    CameraNetwork.rememberMedia2Endpoint(
      connection.host,
      client.resolvedEndpoint,
    );
    client.close();
    debugPrint('[LiveView] getProfiles() -> $result');
    if (_disposed) return _lanProfiles;
    if (result case CameraSuccess<List<MediaProfile>>(:final value)) {
      _lanProfiles = value;
      debugPrint(
        '[LiveView] discovered profiles: '
        '${value.map((p) => '${p.token}(${p.name}, ${p.videoEncoderConfigToken}, '
            '${p.resolution.width}x${p.resolution.height})').join(', ')}',
      );
      notifyListeners();
    }
    return _lanProfiles;
  }

  /// Switches which profile [connect]/[_tryLan] requests next — e.g. the
  /// user picking a specific quality tier from LIVE-059. [token] should be
  /// one of [lanProfiles]' tokens (typically `Profile_1`/`_2`/`_3`), though
  /// any token the camera accepts works. Reconnects immediately so the
  /// switch actually takes effect on-screen rather than only on the next
  /// unrelated reconnect. A no-op if [token] already matches the live
  /// profile — avoids tearing down and rebuilding an already-correct
  /// session (e.g. re-selecting the same chip twice).
  Future<void> setPreferredProfile(String token) async {
    if (_disposed || token == _profileToken) return;
    _profileToken = token;
    await _reconnect();
  }

  /// Recent ICE drops within [_lanTroubleWindow] — [_lanTroubleThreshold] or
  /// more within that window steps the resolution ladder down a tier instead
  /// of just reconnecting at the same (evidently struggling) profile.
  final List<DateTime> _recentLanDrops = [];
  static const _lanTroubleWindow = Duration(minutes: 2);
  static const _lanTroubleThreshold = 3;

  /// Stats-based trouble detection — catches a session that stays nominally
  /// ICE-`connected` while actually stalled/starved, which ICE state alone
  /// never sees. See [_pollBitrate].
  int _stallPollCount = 0;
  int _lowBitratePollCount = 0;
  int _healthyPollCount = 0;
  static const _stallPollThreshold = 3;
  static const _lowBitrateThresholdKbps = 100.0;
  static const _lowBitratePollThreshold = 3;
  static const _healthyPollThreshold = 10;

  LiveViewStatus status = LiveViewStatus.connecting;
  String? errorMessage;

  TalkStatus talkStatus = TalkStatus.idle;
  String? talkErrorMessage;

  /// Defaulted on — TWO_WAY_TALK_GUIDE.md §6.2: a quiet earpiece-routed
  /// default reproduces a real "too quiet" complaint this app hit before.
  bool speakerphoneOn = true;

  /// The active dedicated talk RTSPS session (`RtspTalkSession`), or `null`
  /// when [talkStatus] is [TalkStatus.idle]. Entirely independent of [_pc] —
  /// see [startTalk]'s doc comment.
  RtspTalkSession? _talkSession;
  StreamSubscription<void>? _talkEndedSub;

  RTCPeerConnection? _pc;
  Uri? _signalingUrl;
  Timer? _disconnectGraceTimer;
  bool _rendererInitialized = false;
  bool _disposed = false;

  /// Real, measured inbound video bitrate for the current LAN session —
  /// derived from `RTCPeerConnection.getStats()`'s `inbound-rtp` report
  /// (`bytesReceived` delta over the polling interval), not a stub. Null
  /// until the first two samples land after connecting (one sample alone
  /// can't produce a rate), and reset on every reconnect since a fresh peer
  /// connection means a fresh stats baseline. No WAN equivalent —
  /// STREAMING_GUIDE.md §8 notes HLS gives no equivalent of WebRTC's
  /// `inbound-rtp` stats, so this stays null on WAN.
  double? measuredBitrateKbps;
  Timer? _statsTimer;
  int? _lastStatsBytesReceived;
  double? _lastStatsTimestampMs;
  int? _lastFramesDecoded;

  static const _statsPollInterval = Duration(seconds: 2);

  /// How many more stats-poll ticks should also re-apply the speakerphone
  /// route (see [_applySpeakerphoneRoute]'s doc) — the immediate + 800ms
  /// re-applies in [_handleIceConnectionState] weren't always enough on
  /// real hardware (a route reset reported happening even later than that
  /// on some devices/Android versions); piggybacking a few more attempts
  /// onto the stats timer that's already running covers a later reset
  /// without adding a second timer. Sourced from [_statsPollInterval]'s own
  /// cadence — 5 ticks covers roughly the first 10s of a session.
  int _speakerReapplyTicksRemaining = 0;
  static const _speakerReapplyTicks = 5;

  /// Which transport last reached [LiveViewStatus.connected] — [lan] until
  /// a real WAN session takes over. The UI switches its video widget on
  /// this, not on [status] alone.
  LiveViewTransport transport = LiveViewTransport.lan;

  /// Test-only manual transport override (see `DebugTransportOverride`'s
  /// doc) — `null` is normal automatic LAN-first/WAN-fallback behavior.
  /// [LiveViewTransport.wan] skips the LAN attempt entirely in [connect]
  /// and stops [_checkWanHealth] from ever switching back to LAN just
  /// because the camera happens to be reachable there; [LiveViewTransport.lan]
  /// stops [connect] from falling back to WAN when the LAN attempt fails.
  final LiveViewTransport? forceTransport;

  /// Non-null only while [transport] is [LiveViewTransport.wan] and a
  /// session is live — plays the resolved HLS URL (STREAMING_GUIDE.md §3
  /// step 4). Owned by this controller so it tears down alongside
  /// everything else; the UI just renders it.
  VideoPlayerController? wanVideoController;

  /// Non-null only while [transport] is [LiveViewTransport.lan] *and* the
  /// camera resolved `LiveStreamTransport.rtsp` for this profile (its
  /// firmware build has `WEBRTC_STREAMING` disabled — the documented
  /// current default, STREAMING_GUIDE.md §2.5) — plays the local loopback
  /// URL [_rtspProxy] serves. The UI checks this (not just [transport])
  /// to decide between `RTCVideoView` (WebRTC) and a plain
  /// `video_player`-backed surface (this, same as the WAN path) for a
  /// `lan`-transport session.
  VideoPlayerController? lanRtspVideoController;

  RtspLiveViewProxy? _rtspProxy;
  Timer? _rtspHealthTimer;
  static const _rtspHealthCheckInterval = Duration(seconds: 5);

  /// Same delta-over-interval bitrate computation [_pollBitrate] does from
  /// WebRTC's `getStats()`, fed from [RtspLiveViewProxy.bytesReceived]
  /// instead — this camera's firmware has WebRTC disabled, so RTSP-over-LAN
  /// is this app's actual default LAN path, and it never populated
  /// [measuredBitrateKbps] (the LIVE-038 badge's number) at all before this
  /// (real gap, 2026-09-15).
  int? _lastRtspBytesReceived;
  double? _lastRtspStatsTimestampMs;

  /// Tracks whether `StartCloudStreaming` was actually sent, independent of
  /// [status]/[transport] — STREAMING_GUIDE.md §3 "Ending the session" is
  /// explicit that Stop must be sent even if the session never reached
  /// "playing" (a real bug found in this app: skipping it left the camera
  /// publishing to KVS with no viewer).
  bool _wanStreamStarted = false;

  /// This viewer's lease token from `startCloudStreaming` (`FR-CF-154`,
  /// 2026-09-15) — every later `getCloudStreamingStatus`/`stopCloudStreaming`
  /// call for this session must pass it back. `null` until a WAN session has
  /// actually started.
  int? _wanLeaseToken;

  /// The KVS quality tier this app requests over WAN. Defaults to
  /// [StreamQuality.medium] — matches this class's own pre-`FR-CF-154`
  /// implicit default ("Stream 1", `Profile_2`/`VideoEncoderCfg_2` — the
  /// medium tier, per `onvif_video_encoder_client.dart`'s token mapping)
  /// rather than surprising a WAN viewer with a heavier "high" request.
  /// Settable via [setWanQuality] (the Stream Quality sheet's WAN branch).
  StreamQuality _wanQuality = StreamQuality.medium;

  /// The WAN quality tier currently requested — read by the Stream Quality
  /// sheet to highlight the active choice.
  StreamQuality get wanQuality => _wanQuality;

  /// Whether WAN is currently in "Auto" mode — [_pollWanStall] then steps
  /// [_wanQuality] up/down on its own instead of the user picking a fixed
  /// tier. Added 2026-09-15 alongside the LAN ladder reopening (see
  /// [setAutoQualityLadder]) — HLS has no bitrate telemetry (STREAMING_GUIDE
  /// .md §8), so this is driven by stall/rebuffer detection instead, the
  /// guide's own suggested fallback signal.
  bool get wanAutoQuality => _wanAutoEnabled;
  bool _wanAutoEnabled = false;

  /// How many consecutive non-stalled [_pollWanStall] ticks (at
  /// [_wanStallPollInterval]) justify stepping [_wanQuality] up a tier —
  /// deliberately slower than stepping down (immediate on
  /// [_wanStallThreshold]), same asymmetric reasoning as the LAN ladder's
  /// [_healthyPollThreshold]: a marginal link should recover fast, but
  /// shouldn't flap back to the heaviest, most expensive tier on one good
  /// sample.
  int _wanHealthyPollCount = 0;
  static const _wanHealthyPollThreshold = 10;

  void setWanAutoQuality(bool enabled) {
    _wanAutoEnabled = enabled;
    _wanHealthyPollCount = 0;
    _wanStallPollCount = 0;
  }

  StreamQuality? _nextLowerWanQuality() {
    final i = StreamQuality.values.indexOf(_wanQuality);
    if (i == -1 || i + 1 >= StreamQuality.values.length) return null;
    return StreamQuality.values[i + 1];
  }

  StreamQuality? _nextHigherWanQuality() {
    final i = StreamQuality.values.indexOf(_wanQuality);
    if (i <= 0) return null;
    return StreamQuality.values[i - 1];
  }

  String _wanQualityDisplayName(StreamQuality quality) => switch (quality) {
    StreamQuality.high => 'High',
    StreamQuality.medium => 'Medium',
    StreamQuality.low => 'Low',
  };

  /// User-driven quality switch — the Stream Quality sheet's manual
  /// High/Medium/Low picks. See [_switchWanQuality] for the shared
  /// teardown/reconnect mechanics this and the automatic ladder both use.
  Future<void> setWanQuality(StreamQuality quality) =>
      _switchWanQuality(quality);

  /// Switches the WAN quality tier (`FR-CF-154`). A no-op field update if no
  /// WAN session is active yet — the next [_connectWan] call already picks
  /// up the new value. Otherwise tears down the current KVS viewer lease and
  /// reconnects directly on the new tier. [automatic] marks a
  /// [_pollWanStall]-driven change (as opposed to [setWanQuality]'s direct
  /// user pick) so [autoQualityChangeMessage] surfaces it instead of leaving
  /// it silent.
  ///
  /// Goes straight to [_connectWan] rather than the general
  /// [_reconnect]/[connect] path: [transport] can only be
  /// [LiveViewTransport.wan] right now because LAN was already confirmed
  /// unreachable for this session (or [forceTransport] is `wan`) — retrying
  /// LAN first would just cost a predictable couple of `AreYouNuraeyeDevice`
  /// timeouts (per [_maxLanReconnectAttempts]) before falling back to WAN
  /// anyway, stalling the quality switch for no benefit.
  Future<void> _switchWanQuality(
    StreamQuality quality, {
    bool automatic = false,
  }) async {
    if (quality == _wanQuality) return;
    _wanQuality = quality;
    _wanHealthyPollCount = 0;
    _wanStallPollCount = 0;
    if (automatic) {
      autoQualityChangeMessage =
          'Auto adjusted stream quality to ${_wanQualityDisplayName(quality)}';
    }
    if (_disposed ||
        transport != LiveViewTransport.wan ||
        status != LiveViewStatus.connected) {
      return;
    }
    status = LiveViewStatus.reconnecting;
    notifyListeners();
    await _stopWanIfNeeded();
    if (_disposed) return;
    if (!await _connectWan() && !_disposed) {
      _fail(errorMessage ?? 'Could not switch stream quality');
    }
  }

  /// Best-effort fast-path for a camera-initiated `CloudStreamStopped`
  /// (`STREAMING_GUIDE.md` §6, `FR-CF-154`) — reacts immediately instead of
  /// waiting for the next up-to-10s [_wanHealthTimer] poll to notice via
  /// `idle`/`degraded`. Purely additive: [CameraAlertsHub.events] is an
  /// already-running, app-wide relay (`alerts_api`), so this adds no new
  /// connection — and if the event name/shape here turns out wrong or never
  /// fires, the poll-based recovery above still catches it regardless, just
  /// up to 10s slower. **Event name unconfirmed against real hardware** —
  /// unlike the rest of this rework, no wire-format sample exists for it;
  /// the debug log below makes a mismatch obvious on a real device.
  StreamSubscription<CameraAlertEvent>? _cloudStreamStoppedSub;
  Timer? _wanHealthTimer;

  /// STREAMING_GUIDE.md §5 — poll cadence for `GetCloudStreamingStatus`
  /// while a WAN session is playing.
  static const _wanHealthCheckInterval = Duration(seconds: 10);

  /// The live `GetMedia` session backing [wanVideoController] — a real
  /// resource (background AWS connection + local loopback HTTP server), not
  /// the long-lived static HLS URL this replaced on 2026-09-17. It must be
  /// stopped on every teardown, transport switch, and re-resolve, or its
  /// socket and server outlive the playback attempt that created it.
  ///
  /// Its [KvsMediaLiveViewSession.url] still backs [_pollWanStall]'s
  /// local-first recovery: while the session is alive its loopback server is
  /// already serving, so a purely phone-side decoder stall can re-init the
  /// player against the same URL without a fresh AWS round trip.
  KvsMediaLiveViewSession? _wanMediaSession;
  Timer? _wanStallTimer;
  Duration? _lastWanPosition;
  int _wanStallPollCount = 0;
  static const _wanStallPollInterval = Duration(seconds: 3);
  static const _wanStallThreshold = 3;

  /// Camera reports this via `GetCapabilities` at onboarding — cached on
  /// [CameraConnection]. An unknown (`null`) value fails open (treated as
  /// capable) per STREAMING_GUIDE.md §1, so an already-onboarded camera
  /// whose capability just hasn't been synced yet isn't wrongly blocked.
  bool get _wanEligible =>
      connection.wanLiveViewCapable != false && connection.thingName != null;

  /// Auto-retry after [_fail] — the camera may come back (e.g. powered back
  /// on) with nobody watching the screen to tap the manual Retry button.
  /// Fixed 10s cadence for the first few attempts (fast recovery for a brief
  /// blip), then backs off to 30s so a camera that's genuinely gone for a
  /// while doesn't get hammered indefinitely.
  Timer? _autoRetryTimer;
  int _retryAttempt = 0;
  static const _autoRetryFastDelay = Duration(seconds: 10);
  static const _autoRetrySlowDelay = Duration(seconds: 30);
  static const _autoRetryFastAttempts = 3;

  /// Orchestrates transport selection per STREAMING_GUIDE.md §1: try LAN
  /// first, only fall back to WAN after a genuine LAN failure (never by
  /// comparing IP addresses or guessing from network type), and skip WAN
  /// entirely for a camera known not to support it ([_wanEligible]). See
  /// [forceTransport]'s doc for the test-only override this defers to
  /// before any of that normal logic runs.
  Future<void> connect() async {
    if (_disposed) return;
    _autoRetryTimer?.cancel();
    _autoRetryTimer = null;
    status = LiveViewStatus.connecting;
    errorMessage = null;
    notifyListeners();

    if (forceTransport == LiveViewTransport.wan) {
      if (_wanEligible && await _connectWan()) return;
      if (_disposed) return;
      _fail(
        errorMessage ?? 'Could not connect to the camera over WAN (forced)',
      );
      return;
    }

    // Try WAN first when a probe has already proved this camera isn't on the
    // LAN. Rediscovering that through the LAN ladder costs ~20s before the
    // WAN attempt it was always going to need (3 x 4s GetLiveStreamUri plus
    // retry gaps, then a 5s reachability recheck) — measured on real
    // hardware, 22s to first frame of which 20s was doomed LAN work. LAN
    // still runs below if WAN fails, so a stale answer costs latency, never
    // a failed connect.
    // Nothing proved yet — the usual case on a cold start, since the learned
    // map is process-lifetime and the background probes that fill it lose the
    // race against this first connect. Settle it here with one short probe
    // instead of discovering the same fact through the LAN ladder's ~20s of
    // timeouts: a camera on the LAN answers in milliseconds, so this costs
    // nothing there, and off-LAN it costs 1.2s rather than 20s.
    if (learnedTransportIsWan(connection.thingName) == null &&
        forceTransport == null &&
        connection.thingName != null) {
      final nuraeye = NuraeyeClient(connection);
      final bool reachable;
      try {
        reachable = await LiveStreamUriClient(
          nuraeye,
        ).checkReachable(timeout: lanReachabilityProbeTimeout);
      } finally {
        nuraeye.close();
      }
      if (_disposed) return;
      recordTransportFromProbe(connection.thingName, reachableOnLan: reachable);
    }

    final knownWan = learnedTransportIsWan(connection.thingName) == true;
    if (knownWan && forceTransport != LiveViewTransport.lan) {
      if (_wanEligible && await _connectWan()) return;
      if (_disposed) return;
    }

    if (await _connectLan()) return;
    if (_disposed) return;

    if (forceTransport == LiveViewTransport.lan) {
      _fail(errorMessage ?? 'Could not connect to the camera (forced LAN)');
      return;
    }
    if (knownWan) {
      // Already tried WAN above and it failed; LAN just failed too.
      _fail(errorMessage ?? 'Could not connect to the camera');
      return;
    }

    if (_wanEligible && await _connectWan()) return;
    if (_disposed) return;

    _fail(errorMessage ?? 'Could not connect to the camera');
  }

  /// `RECORD_AUDIO`/`BLUETOOTH_CONNECT` are Android *runtime* permissions
  /// (API 23+/31+) — a manifest `<uses-permission>` declaration alone is not
  /// enough. `flutter_webrtc`'s native audio device module can crash the
  /// whole process (not a catchable Dart exception) if it touches
  /// audio-routing/Bluetooth APIs without these actually granted, even for
  /// a recvonly-only (non-talk) live-view session — the ADM initializes
  /// audio routing regardless of transceiver direction. Requested here, not
  /// at app startup, so the user only sees the permission prompt when they
  /// actually open live view.
  Future<void> _ensureRuntimePermissions() async {
    if (!Platform.isAndroid) return;
    await [Permission.microphone, Permission.bluetoothConnect].request();
  }

  /// LAN WebRTC path (STREAMING_GUIDE.md §2). Retries `GetLiveStreamUri` up to
  /// [_maxLanReconnectAttempts] times before falling through to
  /// [_handleLanExhausted]'s independent reachability recheck — a single
  /// transient failure no longer sends this straight to the much
  /// higher-latency WAN path. Returns true and leaves [status] as
  /// [LiveViewStatus.connected] on success; on failure, sets [errorMessage]
  /// and returns false without touching [status] — the caller ([connect])
  /// decides whether a WAN attempt follows or this is the final failure.
  Future<bool> _connectLan() async {
    await _ensureRuntimePermissions();
    if (_disposed) return false;

    if (!_rendererInitialized) {
      await renderer.initialize();
      _rendererInitialized = true;
    }
    if (_disposed) return false;

    return _tryLan(attempt: 0);
  }

  Future<bool> _tryLan({
    required int attempt,
    bool afterReachabilityRecheck = false,
  }) async {
    if (_disposed) return false;

    final nuraeye = NuraeyeClient(connection);
    final result = await LiveStreamUriClient(
      nuraeye,
    ).getLiveStreamUri(_profileToken, timeout: _lanProbeTimeout);
    nuraeye.close();
    if (_disposed) return false;

    final String failureReason;
    switch (result) {
      case CameraSuccess(:final value):
        switch (value.transport) {
          case LiveStreamTransport.webrtc:
            return _negotiate(value.mediaUri);
          case LiveStreamTransport.rtsp:
            // The camera's firmware build has WEBRTC_STREAMING disabled —
            // the documented current default (STREAMING_GUIDE.md §1/§2) —
            // so it reports RTSP for this profile instead. Same
            // return-immediately contract as the webrtc case just above:
            // a failure here is downstream of discovery (a bad RTSP
            // negotiation, not a bad GetLiveStreamUri call), so retrying
            // the same discovery call wouldn't help — go straight to
            // connect()'s WAN fallback instead of this method's own LAN
            // retry loop below.
            return _connectRtsp(value);
        }
      case CameraFailure(:final reason):
        failureReason = reason;
      case CameraTimeout():
        failureReason = 'Timed out reaching the camera';
    }

    if (attempt < _maxLanReconnectAttempts) {
      await Future.delayed(_lanRetryPollInterval);
      if (_disposed) return false;
      return _tryLan(
        attempt: attempt + 1,
        afterReachabilityRecheck: afterReachabilityRecheck,
      );
    }
    // Already gave this one extra shot after confirming the camera was
    // reachable — stop here and let the outer connect()/auto-retry cadence
    // (not a tight recursive loop) handle any further attempts.
    if (afterReachabilityRecheck) {
      errorMessage = failureReason;
      return false;
    }
    return _handleLanExhausted(failureReason);
  }

  /// `GetLiveStreamUri` has exhausted its retries — before treating that as
  /// "camera isn't on this network" and falling to WAN, confirm that verdict
  /// with one cheap, independent reachability probe (`AreYouNuraeyeDevice`).
  /// A camera that's still genuinely on this LAN gets one more LAN attempt
  /// instead of being needlessly bounced to the much higher-latency WAN path
  /// on what was actually just a signaling hiccup.
  Future<bool> _handleLanExhausted(String lanFailureReason) async {
    if (_disposed) return false;

    final nuraeye = NuraeyeClient(connection);
    final bool reachable;
    try {
      reachable = await LiveStreamUriClient(
        nuraeye,
      ).checkReachable(timeout: _lanReachabilityCheckTimeout);
    } finally {
      nuraeye.close();
    }
    // Hand this free answer to the settings layer so it never has to discover
    // the transport by wasting a real call's timeout on it.
    recordTransportFromProbe(connection.thingName, reachableOnLan: reachable);
    if (_disposed) return false;

    if (reachable) {
      return _tryLan(attempt: 0, afterReachabilityRecheck: true);
    }

    errorMessage = lanFailureReason;
    return false;
  }

  /// Opens the RTSP fallback session against [target] (STREAMING_GUIDE.md
  /// §2.5), remuxes it to fMP4 over a local loopback via
  /// [RtspLiveViewProxy], and points [lanRtspVideoController] at that
  /// loopback URL — same `video_player`-backed rendering path the WAN/KVS
  /// transport already uses, just fed by a local URI instead of a remote
  /// one. [transport] stays [LiveViewTransport.lan] (this is still a LAN
  /// session, just not the WebRTC leg) — the UI distinguishes the two by
  /// checking [lanRtspVideoController] rather than transport alone. Tears
  /// down its own proxy on any failure before returning false.
  Future<bool> _connectRtsp(LiveStreamTarget target) async {
    // Only use profiles that are *already* discovered — never await discovery
    // here. `loadLanProfiles()` is GetServices + GetProfiles over TLS, and
    // awaiting it put those round trips between the user tapping Live and the
    // first frame, purely to pick a fallback resolution that
    // [RtspLiveViewProxy]'s own 1280x720 default already covers. The comment
    // that used to sit here called this "best-effort", which the `await` made
    // untrue. Kick discovery off unawaited so it's ready for the next connect.
    // Refreshed in the background on every connect, not just the first:
    // STREAMING_GUIDE.md §1 wants profiles re-read live before a reconnect
    // rather than trusted from cache, since a stream's encoder config — and
    // so its resolution and codec — can change while a session is down. Still
    // never awaited, so it stays off the path to first frame.
    final profiles = _lanProfiles;
    unawaited(loadLanProfiles(forceRefresh: true));
    final matchedResolution = profiles
        ?.where((p) => p.token == _profileToken)
        .map((p) => p.resolution)
        .firstOrNull;
    final proxy = RtspLiveViewProxy(
      host: target.mediaUri.host,
      port: target.port,
      path: target.mediaUri.path,
      username: connection.username,
      password: connection.password,
      fallbackResolution: matchedResolution ?? (width: 1280, height: 720),
    );
    try {
      await proxy.start();
    } catch (e) {
      await proxy.stop();
      if (!_disposed) errorMessage = 'Could not start RTSP live view: $e';
      return false;
    }
    if (_disposed) {
      await proxy.stop();
      return false;
    }

    final playUrl = proxy.url;
    if (playUrl == null || !await _playLanRtspUrl(playUrl)) {
      await proxy.stop();
      if (!_disposed) {
        errorMessage = 'Could not start RTSP live view playback';
      }
      return false;
    }
    if (_disposed) {
      await proxy.stop();
      return false;
    }

    _rtspProxy = proxy;
    transport = LiveViewTransport.lan;
    status = LiveViewStatus.connected;
    _startRtspHealthMonitor();
    notifyListeners();
    return true;
  }

  /// Initializes and starts playback of [uri] (the RTSP proxy's local
  /// loopback URL) on [lanRtspVideoController] — mirrors [_playWanUrl]
  /// exactly, just for the LAN-RTSP-fallback case instead of WAN. Returns
  /// whether playback actually started.
  Future<bool> _playLanRtspUrl(Uri uri) async {
    final videoController = VideoPlayerController.networkUrl(uri);
    try {
      await videoController.initialize();
    } catch (_) {
      await videoController.dispose();
      return false;
    }
    if (_disposed) {
      await videoController.dispose();
      return false;
    }
    await videoController.setLooping(false);
    await videoController.play();
    final oldController = lanRtspVideoController;
    lanRtspVideoController = videoController;
    if (oldController != null) unawaited(oldController.dispose());
    return true;
  }

  void _startRtspHealthMonitor() {
    _rtspHealthTimer?.cancel();
    _rtspHealthTimer = Timer.periodic(
      _rtspHealthCheckInterval,
      (_) => _pollRtspHealth(),
    );
  }

  /// Client-side stall detection for the RTSP-over-LAN path — same
  /// reasoning [_pollWanStall] documents for the WAN transport: the
  /// underlying RTSP feed can die (camera reboot, network drop) without
  /// `video_player`'s own state necessarily reflecting it promptly, and
  /// [RtspLiveViewProxy.isSessionEnded] is the server-side-authoritative
  /// signal for "this feed is genuinely gone," same role
  /// `RtspRemuxProxy.isSessionEnded` plays for Playback's own stall
  /// detection. Either signal triggers the same [_reconnect] a dropped
  /// WebRTC/WAN session already uses — a plain retry against a
  /// freshly-resolved `getLiveStreamUri()` target, per STREAMING_GUIDE.md
  /// §2.4's reconnect posture.
  void _pollRtspHealth() {
    if (_disposed ||
        transport != LiveViewTransport.lan ||
        status != LiveViewStatus.connected ||
        lanRtspVideoController == null) {
      return;
    }
    _pollRtspBitrate();
    final proxyEnded = _rtspProxy?.isSessionEnded ?? false;
    final playerErrored = lanRtspVideoController?.value.hasError ?? false;
    if (proxyEnded || playerErrored) {
      unawaited(_reconnect());
    }
  }

  void _pollRtspBitrate() {
    final proxy = _rtspProxy;
    if (proxy == null) return;
    final bytesReceived = proxy.bytesReceived;
    final timestampMs = DateTime.now().millisecondsSinceEpoch.toDouble();

    final prevBytes = _lastRtspBytesReceived;
    final prevTimestampMs = _lastRtspStatsTimestampMs;
    _lastRtspBytesReceived = bytesReceived;
    _lastRtspStatsTimestampMs = timestampMs;

    if (prevBytes == null || prevTimestampMs == null) return;
    final deltaBytes = bytesReceived - prevBytes;
    final deltaSeconds = (timestampMs - prevTimestampMs) / 1000;
    if (deltaSeconds <= 0 || deltaBytes < 0) return;
    measuredBitrateKbps = (deltaBytes * 8) / 1000 / deltaSeconds;
    if (!_disposed) notifyListeners();
  }

  Future<void> _stopRtspIfNeeded() async {
    _rtspHealthTimer?.cancel();
    _rtspHealthTimer = null;
    _lastRtspBytesReceived = null;
    _lastRtspStatsTimestampMs = null;
    if (measuredBitrateKbps != null) {
      measuredBitrateKbps = null;
      if (!_disposed) notifyListeners();
    }
    final proxy = _rtspProxy;
    _rtspProxy = null;
    final controller = lanRtspVideoController;
    lanRtspVideoController = null;
    if (controller != null) {
      try {
        await controller.pause();
      } catch (_) {
        // Best-effort — nothing more to do if the player's already broken.
      }
      unawaited(controller.dispose());
    }
    if (proxy != null) await proxy.stop();
  }

  /// Negotiates a brand-new `RTCPeerConnection` against [signalingUrl] for
  /// plain live view — video recvonly, plus a recvonly audio leg (for
  /// hearing the camera's own ambient mic, rendered implicitly by
  /// `renderer.srcObject`'s associated audio track — unrelated to two-way
  /// talk). **Always builds a fresh peer connection — never renegotiates an
  /// existing one.** `module_webrtc.c` holds exactly one `RTCPeerConnection`
  /// per signaling port and tears down whatever connection currently exists
  /// on every accepted offer before rebuilding it server-side
  /// (STREAMING_GUIDE.md §2.3).
  ///
  /// **No longer used for two-way talk** (2026-09-15) — talk moved to its
  /// own dedicated RTSPS connection ([RtspTalkSession],
  /// `TWO_WAY_TALK_GUIDE.md`) after the camera's firmware removed the
  /// `{"talk": true}` flag on `POST /webrtc` entirely (2026-09-11); the old
  /// approach of renegotiating this exact peer connection with a sendrecv
  /// audio leg is stale — see git history if that mechanism is ever needed
  /// for reference. Callers ([_connectLan]) must have already torn down any
  /// previous [_pc] before calling this. Returns true on success.
  Future<bool> _negotiate(Uri signalingUrl) async {
    // iOS-only (no-op elsewhere, see AppleNativeAudioManagement's own
    // platform check): configures AVAudioSession for receive-only remote
    // audio playback before the peer connection exists. Without this, the
    // native WebRTC audio engine renders against an unconfigured session —
    // reproduced as a real SIGSEGV inside WebRTC's own audio unit callback
    // (crash report 2026-08-14, iOS Simulator) once the remote audio track
    // went live.
    await AppleNativeAudioManagement.setAppleAudioConfiguration(
      AppleNativeAudioManagement.getAppleAudioConfigurationForMode(
        AppleAudioIOMode.remoteOnly,
      ),
    );
    if (_disposed) return false;

    try {
      // No STUN/TURN — this is a same-LAN connection with host candidates
      // only (guide §2.2).
      final pc = await createPeerConnection({'iceServers': <dynamic>[]});
      if (_disposed) {
        await pc.close();
        return false;
      }
      _pc = pc;

      pc.onTrack = (event) {
        if (event.track.kind == 'video' && event.streams.isNotEmpty) {
          renderer.srcObject = event.streams.first;
          notifyListeners();
        }
      };
      pc.onIceConnectionState = _handleIceConnectionState;

      await pc.addTransceiver(
        kind: RTCRtpMediaType.RTCRtpMediaTypeVideo,
        init: RTCRtpTransceiverInit(direction: TransceiverDirection.RecvOnly),
      );
      await pc.addTransceiver(
        kind: RTCRtpMediaType.RTCRtpMediaTypeAudio,
        init: RTCRtpTransceiverInit(direction: TransceiverDirection.RecvOnly),
      );

      final offer = await pc.createOffer();
      await pc.setLocalDescription(offer);

      // This camera's WebRTC signaling is non-trickle — it needs host ICE
      // candidates already embedded in the offer SDP, not delivered
      // separately after the fact. Waiting for gathering to finish (bounded,
      // since gathering host-only candidates with no STUN/TURN is normally
      // near-instant but nothing guarantees it can never stall) and
      // re-reading the local description picks those candidates up before
      // the offer is sent — skipping this step can produce a negotiation
      // that "connects" at the SDP level but never actually carries media.
      await _waitForIceGatheringComplete(pc);
      if (_disposed) {
        await pc.close();
        return false;
      }
      final localDescription = await pc.getLocalDescription();
      final offerSdp = localDescription?.sdp ?? offer.sdp;

      final response = await _http
          .post(
            signalingUrl,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'type': 'offer', 'sdp': offerSdp}),
          )
          .timeout(_webrtcSignalingTimeout);
      if (_disposed) return false;

      if (response.statusCode == 409) {
        errorMessage = 'Camera rejected the connection (409)';
        await _teardownPeerConnection();
        return false;
      }
      if (response.statusCode != 200) {
        errorMessage =
            'Camera rejected the connection (${response.statusCode})';
        await _teardownPeerConnection();
        return false;
      }
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      final answerSdp = body['sdp'] as String?;
      final answerType = body['type'] as String?;
      if (answerSdp == null || answerType == null) {
        errorMessage = 'Malformed answer from camera';
        await _teardownPeerConnection();
        return false;
      }
      await pc.setRemoteDescription(
        RTCSessionDescription(answerSdp, answerType),
      );
      if (_disposed) return false;

      _signalingUrl = signalingUrl;
      transport = LiveViewTransport.lan;
      status = LiveViewStatus.connected;
      _retryAttempt = 0;
      _startStatsPolling();
      // See _applySpeakerphoneRoute's doc comment — a single call right
      // after signaling isn't reliable, the native audio device module can
      // reset the route once media actually starts flowing.
      unawaited(_applySpeakerphoneRoute());
      unawaited(
        Future.delayed(
          const Duration(milliseconds: 800),
          _applySpeakerphoneRoute,
        ),
      );
      notifyListeners();
      return true;
    } catch (e) {
      if (_disposed) return false;
      errorMessage = e.toString();
      await _teardownPeerConnection();
      return false;
    }
  }

  /// Bounded wait for [pc]'s ICE gathering to reach
  /// [RTCIceGatheringState.RTCIceGatheringStateComplete] — see the call site
  /// in [_negotiate] for why this matters for this camera's non-trickle
  /// signaling. Proceeding with whatever candidates were gathered so far on
  /// timeout is standard WebRTC practice, not a degraded state.
  Future<void> _waitForIceGatheringComplete(RTCPeerConnection pc) async {
    if (pc.iceGatheringState ==
        RTCIceGatheringState.RTCIceGatheringStateComplete) {
      return;
    }
    final completer = Completer<void>();
    pc.onIceGatheringState = (state) {
      if (state == RTCIceGatheringState.RTCIceGatheringStateComplete &&
          !completer.isCompleted) {
        completer.complete();
      }
    };
    await completer.future.timeout(_iceGatheringTimeout, onTimeout: () {});
  }

  void _fail(String reason) {
    status = LiveViewStatus.failed;
    errorMessage = reason;
    notifyListeners();
    _scheduleAutoRetry();
  }

  void _scheduleAutoRetry() {
    _autoRetryTimer?.cancel();
    final delay = _retryAttempt < _autoRetryFastAttempts
        ? _autoRetryFastDelay
        : _autoRetrySlowDelay;
    _retryAttempt++;
    _autoRetryTimer = Timer(delay, () {
      _autoRetryTimer = null;
      if (!_disposed && status == LiveViewStatus.failed) {
        unawaited(connect());
      }
    });
  }

  void _handleIceConnectionState(RTCIceConnectionState state) {
    if (_disposed) return;
    switch (state) {
      case RTCIceConnectionState.RTCIceConnectionStateConnected:
      case RTCIceConnectionState.RTCIceConnectionStateCompleted:
        _disconnectGraceTimer?.cancel();
        _disconnectGraceTimer = null;
        if (status != LiveViewStatus.connected) {
          status = LiveViewStatus.connected;
          notifyListeners();
        }
        // Applying this at signaling time (right after setRemoteDescription)
        // isn't reliable — the native WebRTC audio device module does its
        // own routing setup once media actually starts flowing, which can
        // happen *after* signaling and silently reset the route back to the
        // earpiece. Re-applying here, once ICE is actually connected and
        // audio is genuinely flowing, plus once more after a short delay
        // (some devices apply the ADM's own routing decision a beat later
        // still) is what reliably sticks.
        unawaited(_applySpeakerphoneRoute());
        unawaited(
          Future.delayed(
            const Duration(milliseconds: 800),
            _applySpeakerphoneRoute,
          ),
        );
      case RTCIceConnectionState.RTCIceConnectionStateDisconnected:
        // A momentary `disconnected` is routine on a no-STUN/TURN LAN
        // connection (WebRTC's own periodic consent-freshness check) — give
        // it a few seconds to self-recover before treating it as a real
        // drop. See STREAMING_GUIDE.md §2.4.
        _disconnectGraceTimer ??= Timer(_iceDisconnectGrace, () {
          _disconnectGraceTimer = null;
          if (!_disposed) unawaited(_recordLanDropAndReconnect());
        });
      case RTCIceConnectionState.RTCIceConnectionStateFailed:
      case RTCIceConnectionState.RTCIceConnectionStateClosed:
        _disconnectGraceTimer?.cancel();
        _disconnectGraceTimer = null;
        unawaited(_recordLanDropAndReconnect());
      case RTCIceConnectionState.RTCIceConnectionStateNew:
      case RTCIceConnectionState.RTCIceConnectionStateChecking:
      case RTCIceConnectionState.RTCIceConnectionStateCount:
        break;
    }
  }

  /// WebRTC's default audio route is the phone's quiet earpiece speaker,
  /// not the loudspeaker — without forcing this, the camera's audio plays
  /// but is barely audible unless the phone is held to your ear. Same
  /// reasoning `TWO_WAY_TALK_GUIDE.md` §5.2 documents for talk specifically,
  /// applied here to plain live view too. See the call sites in
  /// [_handleIceConnectionState] for why this needs re-applying rather than
  /// a single call right after signaling.
  Future<void> _applySpeakerphoneRoute() async {
    if (_disposed) return;
    try {
      await Helper.setSpeakerphoneOn(speakerphoneOn);
    } catch (_) {
      // Best-effort — a platform-level audio routing failure shouldn't
      // block the connection itself.
    }
  }

  String? _nextLowerProfile() {
    if (!_profileLadderEnabled) return null;
    final i = _profileLadder.indexOf(_profileToken);
    if (i == -1 || i + 1 >= _profileLadder.length) return null;
    return _profileLadder[i + 1];
  }

  String? _nextHigherProfile() {
    if (!_profileLadderEnabled) return null;
    final i = _profileLadder.indexOf(_profileToken);
    if (i <= 0) return null;
    return _profileLadder[i - 1];
  }

  /// Funnel for every LAN WebRTC drop (disconnect-grace expiry, or a hard
  /// `failed`/`closed` state) — counts drops within [_lanTroubleWindow] and,
  /// once [_lanTroubleThreshold] is hit, steps the resolution ladder down a
  /// tier instead of just reconnecting at the same (evidently struggling)
  /// profile. A marginal LAN link then self-heals into something watchable
  /// rather than repeatedly stalling/reconnecting at full resolution.
  Future<void> _recordLanDropAndReconnect() async {
    if (_disposed) return;
    final now = DateTime.now();
    _recentLanDrops.removeWhere((t) => now.difference(t) > _lanTroubleWindow);
    _recentLanDrops.add(now);
    final lowerProfile = _nextLowerProfile();
    if (transport == LiveViewTransport.lan &&
        _recentLanDrops.length >= _lanTroubleThreshold &&
        lowerProfile != null) {
      await _switchProfile(lowerProfile);
      return;
    }
    await _reconnect();
  }

  /// Moves live view to a different rung of [_profileLadder] — one tier
  /// down on sustained trouble ([_recordLanDropAndReconnect]'s ICE-drop
  /// counter, or a stats-detected stall/low-bitrate run in [_pollBitrate]),
  /// or one tier up after a sustained healthy run. Tears down the current
  /// peer connection and reconnects fresh on [newProfile] via the normal
  /// [connect] path (which still tries LAN-then-WAN, but LAN will now
  /// request the new profile).
  Future<void> _switchProfile(String newProfile) async {
    if (_disposed || transport != LiveViewTransport.lan) return;
    _profileToken = newProfile;
    _recentLanDrops.clear();
    _healthyPollCount = 0;
    _stallPollCount = 0;
    _lowBitratePollCount = 0;
    // Every caller of _switchProfile is the automatic ladder (a direct user
    // pick goes through setPreferredProfile/_reconnect instead) — always an
    // Auto-driven change, so always worth a message.
    autoQualityChangeMessage =
        'Auto adjusted stream quality to '
        '${_profileDisplayName[newProfile] ?? newProfile}';
    status = LiveViewStatus.reconnecting;
    notifyListeners();
    await _teardownPeerConnection();
    if (!_disposed) await connect();
  }

  /// [preferLan] — set only by [_checkWanHealth]'s own LAN-reachability
  /// precheck, which has *just* confirmed the camera is reachable directly —
  /// threaded down to [_stopWanIfNeeded] so that one call skips straight to
  /// the LAN `StopCloudStreaming` action instead of paying its normal
  /// AWS/MQTT round trip (STREAMING_GUIDE.md §3 "Ending the session"). Every
  /// other caller has no such signal and must not guess one — see
  /// [_stopWanIfNeeded]'s own doc for why guessing was itself a real,
  /// user-facing latency bug.
  Future<void> _reconnect({bool preferLan = false}) async {
    if (_disposed) return;
    // Talk runs on its own dedicated RTSPS connection now (2026-09-15),
    // entirely independent of live view's own connection — a live-view
    // reconnect (ICE failure, RTSP/WAN health check) no longer touches
    // `talkStatus`/[_talkSession] at all, matching TWO_WAY_TALK_GUIDE.md §1
    // ("completely independent of whatever the live-view screen is doing").
    status = LiveViewStatus.reconnecting;
    notifyListeners();
    await _teardownPeerConnection();
    await _stopWanIfNeeded(preferLan: preferLan);
    await _stopRtspIfNeeded();
    if (!_disposed) await connect();
  }

  Future<void> _teardownPeerConnection() async {
    final pc = _pc;
    _pc = null;
    if (pc != null) {
      pc.onTrack = null;
      pc.onIceConnectionState = null;
      await pc.close();
    }
    _stopStatsPolling();
  }

  void _startStatsPolling() {
    _stopStatsPolling();
    _speakerReapplyTicksRemaining = _speakerReapplyTicks;
    _statsTimer = Timer.periodic(
      _statsPollInterval,
      (_) => unawaited(_pollBitrate()),
    );
  }

  void _stopStatsPolling() {
    _statsTimer?.cancel();
    _statsTimer = null;
    _lastStatsBytesReceived = null;
    _lastStatsTimestampMs = null;
    _lastFramesDecoded = null;
    _stallPollCount = 0;
    _lowBitratePollCount = 0;
    if (measuredBitrateKbps != null) {
      measuredBitrateKbps = null;
      if (!_disposed) notifyListeners();
    }
  }

  /// One `getStats()` sample — computes a rate from the delta against the
  /// previous sample, so the first tick after (re)connecting only seeds the
  /// baseline and doesn't yet update [measuredBitrateKbps]. Also feeds
  /// [_maybeAdjustProfile]'s stall/low-bitrate detection — catches a session
  /// that stays nominally ICE-`connected` while actually stalled/starved,
  /// which [_handleIceConnectionState] alone never sees.
  Future<void> _pollBitrate() async {
    final pc = _pc;
    if (_disposed || pc == null) return;
    if (_speakerReapplyTicksRemaining > 0) {
      _speakerReapplyTicksRemaining--;
      unawaited(_applySpeakerphoneRoute());
    }
    try {
      final reports = await pc.getStats();
      for (final report in reports) {
        if (report.type != 'inbound-rtp') continue;
        final kind = report.values['kind'] ?? report.values['mediaType'];
        if (kind != 'video') continue;
        final bytesReceivedRaw = report.values['bytesReceived'];
        final framesDecoded = (report.values['framesDecoded'] as num?)?.toInt();
        if (bytesReceivedRaw is! num) continue;
        final bytesReceived = bytesReceivedRaw.toInt();
        final timestampMs = report.timestamp;

        final prevBytes = _lastStatsBytesReceived;
        final prevTimestampMs = _lastStatsTimestampMs;
        _lastStatsBytesReceived = bytesReceived;
        _lastStatsTimestampMs = timestampMs;

        double? bitrateKbps;
        if (prevBytes != null && prevTimestampMs != null) {
          final deltaBytes = bytesReceived - prevBytes;
          final deltaSeconds = (timestampMs - prevTimestampMs) / 1000;
          if (deltaSeconds > 0 && deltaBytes >= 0) {
            bitrateKbps = (deltaBytes * 8) / 1000 / deltaSeconds;
            measuredBitrateKbps = bitrateKbps;
            if (!_disposed) notifyListeners();
          }
        }

        final stalled =
            framesDecoded != null &&
            _lastFramesDecoded != null &&
            framesDecoded == _lastFramesDecoded;
        _lastFramesDecoded = framesDecoded;
        await _maybeAdjustProfile(stalled: stalled, bitrateKbps: bitrateKbps);
        return;
      }
    } catch (_) {
      // Best-effort — stats aren't critical to the connection itself.
    }
  }

  /// Steps [_profileToken] down a tier on a sustained stall/low-bitrate run,
  /// or up a tier after a sustained healthy run — the counterpart to
  /// [_recordLanDropAndReconnect]'s ICE-drop-based trigger. Deliberately
  /// slower to step up than down: a marginal link should recover fast, but
  /// shouldn't flap back to full resolution on one good sample.
  Future<void> _maybeAdjustProfile({
    required bool stalled,
    required double? bitrateKbps,
  }) async {
    if (_disposed || transport != LiveViewTransport.lan) return;

    _stallPollCount = stalled ? _stallPollCount + 1 : 0;
    final lowBitrate =
        bitrateKbps != null && bitrateKbps < _lowBitrateThresholdKbps;
    _lowBitratePollCount = lowBitrate ? _lowBitratePollCount + 1 : 0;

    final troubled =
        _stallPollCount >= _stallPollThreshold ||
        _lowBitratePollCount >= _lowBitratePollThreshold;
    final lowerProfile = _nextLowerProfile();
    if (troubled && lowerProfile != null) {
      _healthyPollCount = 0;
      await _switchProfile(lowerProfile);
      return;
    }

    final higherProfile = _nextHigherProfile();
    if (!troubled && higherProfile != null) {
      _healthyPollCount++;
      if (_healthyPollCount >= _healthyPollThreshold) {
        _healthyPollCount = 0;
        await _switchProfile(higherProfile);
      }
    } else if (!troubled) {
      _healthyPollCount = 0;
    }
  }

  /// Wraps `AwsWanLiveViewClient.getCloudStreamingStatus()` — unlike its
  /// three sibling methods on that same class, it doesn't catch
  /// `IotCommandClient`'s relay/transport exceptions internally (a real
  /// crash hit on-device: an unhandled `SocketException` when the phone had
  /// no network path to the relay at all). Every other WAN call site in
  /// this file already gets `CameraFailure` back for that case instead of a
  /// thrown exception; this normalizes the one that doesn't, without
  /// needing to change `camera_api` itself.
  Future<CameraResult<StreamStatus>> _getCloudStreamingStatus(
    AwsWanLiveViewClient client,
    int token,
  ) async {
    try {
      return await client.getCloudStreamingStatus(token);
    } catch (e) {
      return CameraFailure(e.toString());
    }
  }

  /// WAN path (STREAMING_GUIDE.md §3's four-step sequence). Returns true
  /// and leaves [status]/[transport] set on success; on failure, sets
  /// [errorMessage] and returns false, same contract as [_connectLan].
  /// Only called when [_wanEligible].
  Future<bool> _connectWan() async {
    final thingName = connection.thingName;
    if (thingName == null) return false;
    final client = AwsWanLiveViewClient(thingName);

    final startResult = await client.startCloudStreaming(_wanQuality);
    if (startResult is! CameraSuccess<int>) {
      if (_disposed) return false;
      errorMessage = 'Could not reach this camera remotely';
      return false;
    }
    // Captured and stored *before* the `_disposed` check below, even
    // though nothing else has run yet — `startCloudStreaming` already
    // succeeded by this point, meaning a real, billable camera-side lease
    // now exists whether or not this controller is still around to use it.
    // Checking `_disposed` first (the old order) could skip storing the
    // token entirely on a `dispose()` that raced this call, leaking the
    // lease with no record of it anywhere — worse than the bug described
    // below, since there'd be no token left to even send a Stop for.
    // Independent of status/transport from here — STREAMING_GUIDE.md §3
    // "Ending the session" requires Stop to be sent even if the rest of
    // this sequence never completes.
    _wanStreamStarted = true;
    final leaseToken = startResult.value;
    _wanLeaseToken = leaseToken;
    if (_disposed) return _stopWanIfNeeded().then((_) => false);

    // Real bug fix, 2026-09-15: every return-false path below this point
    // used to abandon the lease just acquired above instead of releasing
    // it — `_wanStreamStarted`/`_wanLeaseToken` stayed set, so a later
    // retry's `startCloudStreaming` silently overwrote `_wanLeaseToken`
    // with a new lease, permanently losing the reference to this one. That
    // orphaned lease was never stopped by this app again — only the
    // camera's own 30s idle-lease timeout would eventually release it.
    // `_stopWanIfNeeded` is idempotent/safe to call here (every timer/
    // controller it tears down is still null at this point) and does the
    // one thing that actually matters: send the Stop for `leaseToken`
    // before this method's own state moves on.
    Future<bool> failWan(String reason) async {
      errorMessage = reason;
      await _stopWanIfNeeded();
      return false;
    }

    Future<bool> abortWanForDispose() async {
      await _stopWanIfNeeded();
      return false;
    }

    // Step 2 — `idle` is a normal transient state right after Start while
    // the substream spins up; retry before treating it as a real problem.
    // (`AwsWanLiveViewClient.getCloudStreamingStatus` already retries a
    // couple of times internally on transient `idle` — this outer loop
    // covers the longer spin-up window a fresh Start can still need.)
    var active = false;
    for (var attempt = 0; attempt < 5 && !_disposed; attempt++) {
      final statusResult = await _getCloudStreamingStatus(client, leaseToken);
      if (statusResult case CameraSuccess(:final value)) {
        if (value == StreamStatus.active) {
          active = true;
          break;
        }
        if (value == StreamStatus.notCompiled) {
          return failWan('This camera does not support remote viewing');
        }
      }
      if (attempt < 4) await Future.delayed(const Duration(seconds: 2));
    }
    if (_disposed) return abortWanForDispose();
    if (!active) {
      return failWan('Camera is not streaming to the cloud right now');
    }

    // Step 3 — open a GetMedia session, retrying a few times since the
    // substream can still be spinning up for a few seconds after `active`.
    final playbackUri = await _openWanMediaSession(client);
    if (_disposed) return abortWanForDispose();
    if (playbackUri == null) {
      return failWan('Could not start remote playback');
    }

    // Step 4 — play the session's local loopback URL.
    if (!await _playWanUrl(playbackUri)) {
      return failWan('Could not play the remote stream');
    }
    if (_disposed) return abortWanForDispose();

    transport = LiveViewTransport.wan;
    status = LiveViewStatus.connected;
    _retryAttempt = 0;
    notifyListeners();
    _startWanHealthMonitor();
    _startWanStallMonitor();
    _startCloudStreamStoppedWatch();
    return true;
  }

  void _startCloudStreamStoppedWatch() {
    _cloudStreamStoppedSub?.cancel();
    final thingName = connection.thingName;
    if (thingName == null) return;
    _cloudStreamStoppedSub = CameraAlertsHub.instance.events.listen((event) {
      if (event.thingName != thingName || event.event != 'CloudStreamStopped') {
        return;
      }
      debugPrint(
        '[LiveView] CloudStreamStopped alert for $thingName — reconnecting immediately',
      );
      if (_disposed || transport != LiveViewTransport.wan) return;
      unawaited(_reconnect());
    });
  }

  /// Stops any open session, opens a fresh `GetMedia` one, and returns its
  /// loopback URL — `null` if every attempt failed.
  ///
  /// Retries because the camera's substream can still be spinning up for a
  /// few seconds after `GetCloudStreamingStatus` first reports `active`. The
  /// session is stored in [_wanMediaSession] the moment it exists, so a
  /// dispose racing this still tears it down via [_stopWanIfNeeded].
  Future<Uri?> _openWanMediaSession(AwsWanLiveViewClient client) async {
    await _stopWanMediaSession();
    for (var attempt = 0; attempt < 3 && !_disposed; attempt++) {
      final result = await client.startMediaSession(_wanQuality);
      if (result case CameraSuccess(:final value)) {
        value.onLog = (message) => debugPrint('[LiveView] $message');
        _wanMediaSession = value;
        final url = value.url;
        if (url != null) return url;
        await _stopWanMediaSession();
      }
      if (attempt < 2) await Future.delayed(const Duration(seconds: 2));
    }
    return null;
  }

  /// Tears down [_wanMediaSession] — its background `GetMedia` connection and
  /// local loopback server — if one is open. Safe to call when none is.
  Future<void> _stopWanMediaSession() async {
    final session = _wanMediaSession;
    _wanMediaSession = null;
    if (session == null) return;
    try {
      await session.stop();
    } catch (_) {
      // Best-effort — a collapsed session has nothing left to free.
    }
  }

  /// Initializes and starts playback of [uri] on [wanVideoController],
  /// disposing whatever controller was there before. Returns whether
  /// playback actually started.
  Future<bool> _playWanUrl(Uri uri) async {
    final videoController = VideoPlayerController.networkUrl(uri);
    try {
      await videoController.initialize();
    } catch (_) {
      await videoController.dispose();
      return false;
    }
    if (_disposed) {
      await videoController.dispose();
      return false;
    }
    await videoController.setLooping(true);
    await videoController.play();
    final oldController = wanVideoController;
    wanVideoController = videoController;
    if (oldController != null) unawaited(oldController.dispose());
    return true;
  }

  void _startWanHealthMonitor() {
    _wanHealthTimer?.cancel();
    _wanHealthTimer = Timer.periodic(
      _wanHealthCheckInterval,
      (_) => unawaited(_checkWanHealth()),
    );
  }

  void _startWanStallMonitor() {
    _wanStallTimer?.cancel();
    _lastWanPosition = null;
    _wanStallPollCount = 0;
    _wanStallTimer = Timer.periodic(
      _wanStallPollInterval,
      (_) => unawaited(_pollWanStall()),
    );
  }

  void _stopWanStallMonitor() {
    _wanStallTimer?.cancel();
    _wanStallTimer = null;
    _lastWanPosition = null;
    _wanStallPollCount = 0;
  }

  /// Client-side counterpart to [_checkWanHealth]'s server-side poll — a
  /// purely phone-side hiccup (decoder stall, a blip to the CloudFront/S3
  /// endpoint) with a perfectly healthy camera-side stream can leave
  /// [wanVideoController] frozen while `GetCloudStreamingStatus` keeps
  /// reporting `active`, since the camera side really is fine. Detects that
  /// case directly from the player's own state (an error, or playback
  /// position not advancing) rather than waiting for the next health tick.
  ///
  /// Doubles as the WAN "Auto" quality signal (2026-09-15) — with no
  /// bitrate telemetry available over HLS (STREAMING_GUIDE.md §8), a
  /// sustained stall is this app's only real proxy for "this tier is too
  /// heavy for the current connection." When [_wanAutoEnabled], a sustained
  /// stall steps [_wanQuality] down a tier instead of just retrying the same
  /// one, and a sustained stall-free run steps it back up.
  Future<void> _pollWanStall() async {
    if (_disposed ||
        transport != LiveViewTransport.wan ||
        status != LiveViewStatus.connected) {
      return;
    }
    final controller = wanVideoController;
    if (controller == null) return;
    final value = controller.value;

    final stalled =
        value.hasError ||
        (value.isPlaying && value.position == _lastWanPosition);
    _lastWanPosition = value.position;

    if (!stalled) {
      _wanStallPollCount = 0;
      if (_wanAutoEnabled) {
        final higher = _nextHigherWanQuality();
        if (higher == null) {
          _wanHealthyPollCount = 0;
        } else {
          _wanHealthyPollCount++;
          if (_wanHealthyPollCount >= _wanHealthyPollThreshold) {
            _wanHealthyPollCount = 0;
            await _switchWanQuality(higher, automatic: true);
          }
        }
      }
      return;
    }

    _wanStallPollCount++;
    if (_wanStallPollCount < _wanStallThreshold) return;
    _wanStallPollCount = 0;
    if (_wanAutoEnabled) {
      final lower = _nextLowerWanQuality();
      if (lower != null) {
        await _switchWanQuality(lower, automatic: true);
        return;
      }
    }
    await _recoverWanStallLocalFirst();
  }

  /// Re-inits playback against the open session's own loopback URL first — no
  /// AWS round trip needed for a purely phone-side hiccup, since that
  /// session's local server is still serving — only escalating to a fresh
  /// session ([_recoverWanPlayback]) if that fails, or if the session has
  /// already ended (its `GetMedia` stream closed), where replaying the same
  /// URL can only fail.
  Future<void> _recoverWanStallLocalFirst() async {
    if (_disposed || transport != LiveViewTransport.wan) return;
    final session = _wanMediaSession;
    final uri = session?.url;
    if (session != null && uri != null && !session.isSessionEnded) {
      for (var attempt = 0; attempt < 3 && !_disposed; attempt++) {
        if (transport != LiveViewTransport.wan) return;
        if (await _playWanUrl(uri)) {
          if (!_disposed) notifyListeners();
          return;
        }
        if (attempt < 2) await Future.delayed(const Duration(seconds: 2));
      }
    }
    if (_disposed || transport != LiveViewTransport.wan) return;
    unawaited(_recoverWanPlayback());
  }

  /// STREAMING_GUIDE.md §5 — two separate watchers, since WAN has no single
  /// live push signal the way LAN's ICE state is one: a cheap LAN
  /// reachability probe first each tick (switch back to LAN the moment the
  /// phone is back on the camera's network, before spending a paid
  /// AWS/Lambda call), then `GetCloudStreamingStatus` itself. **Skips the
  /// LAN probe (and any switch-back) entirely when [forceTransport] is
  /// [LiveViewTransport.wan]** — the whole point of forcing WAN for a test
  /// is to exercise it even when LAN is available, so this must never
  /// switch a forced-WAN session back to LAN just because the camera
  /// happens to be reachable there.
  Future<void> _checkWanHealth() async {
    if (_disposed ||
        transport != LiveViewTransport.wan ||
        status != LiveViewStatus.connected) {
      return;
    }

    if (forceTransport != LiveViewTransport.wan) {
      final nuraeye = NuraeyeClient(connection);
      final bool reachableOnLan;
      try {
        reachableOnLan = await LiveStreamUriClient(
          nuraeye,
        ).checkReachable(timeout: _lanSwitchBackProbeTimeout);
      } finally {
        nuraeye.close();
      }
      recordTransportFromProbe(
        connection.thingName,
        reachableOnLan: reachableOnLan,
      );
      if (_disposed || transport != LiveViewTransport.wan) return;
      if (reachableOnLan) {
        unawaited(_reconnect(preferLan: true));
        return;
      }
    }

    final thingName = connection.thingName;
    final leaseToken = _wanLeaseToken;
    if (thingName == null || leaseToken == null) return;
    final result = await _getCloudStreamingStatus(
      AwsWanLiveViewClient(thingName),
      leaseToken,
    );
    if (_disposed || transport != LiveViewTransport.wan) return;
    switch (result) {
      case CameraSuccess(:final value) when value == StreamStatus.active:
        return; // Healthy — nothing to do this tick.
      case CameraSuccess(:final value) when value == StreamStatus.notCompiled:
        await _stopWanIfNeeded();
        _fail('This camera no longer supports remote viewing');
      case CameraSuccess():
        // idle/degraded — real integration gap found and fixed 2026-09-15:
        // `FR-CF-154` changed what this means. The camera no longer
        // self-restarts its KVS producer on a mic-toggle/resolution-change
        // trigger (§6) — it just stops the stream outright, and won't bring
        // it back without a fresh `startCloudStreaming` (Step 1). Calling
        // `_recoverWanPlayback` here (a fresh `GetMedia` session against a
        // producer that has stopped, no new Start) would now reliably fail
        // its own 3-attempt budget
        // every single time before falling through to `_reconnect` anyway
        // — wasting ~6s. Go straight to a full reconnect instead, per
        // STREAMING_GUIDE.md §5's explicit recommendation. (`_recoverWanPlayback`
        // itself stays correct for the *other* caller, [_recoverWanStallLocalFirst]
        // — a purely client-side player stall where the camera's own KVS
        // session is presumed still alive, a genuinely different case.)
        unawaited(_reconnect());
      case CameraFailure():
      case CameraTimeout():
        // Transient relay hiccup — leave the current session alone and
        // try again next tick rather than tearing down on one bad poll.
        break;
    }
  }

  /// Opens a *fresh* `GetMedia` session and switches to it without a full
  /// Start/Stop cycle — a stalled or ended session can't be recovered by
  /// replaying its own loopback URL, but a new session against the same
  /// still-running camera-side stream can. Falls through to a full
  /// [_reconnect] (a fresh §3 sequence from Step 1) if even that fails, per
  /// §5's explicit recommendation rather than looping a dead session.
  Future<void> _recoverWanPlayback() async {
    if (_disposed || transport != LiveViewTransport.wan) return;
    final thingName = connection.thingName;
    if (thingName == null) return;

    final playbackUri = await _openWanMediaSession(
      AwsWanLiveViewClient(thingName),
    );
    if (_disposed || transport != LiveViewTransport.wan) return;

    if (playbackUri == null || !await _playWanUrl(playbackUri)) {
      unawaited(_reconnect());
      return;
    }
    notifyListeners();
  }

  /// Tears down the WAN session, if one was started — cancels health
  /// polling, disposes the player, and sends `StopCloudStreaming`.
  /// **Sends Stop even if [_wanStreamStarted] is the only surviving fact**
  /// (status/transport may have already moved on) — see STREAMING_GUIDE.md
  /// §3's "Ending the session", and [_wanStreamStarted]'s own doc comment.
  ///
  /// [preferLan] — STREAMING_GUIDE.md §3 says to prefer the LAN stop call
  /// only "if you've just confirmed the camera is reachable on LAN", not
  /// unconditionally. **Real latency bug found 2026-09-15**: this method
  /// used to always attempt the LAN call first regardless of context, paying
  /// its full 3s timeout on every single teardown where LAN is predictably
  /// unreachable (a plain `stop()`/`dispose()` while genuinely WAN-only, or
  /// — the case that surfaced this — [setWanQuality] switching tiers, which
  /// stalled a full 3s before even starting the new tier's connect
  /// sequence). Now skipped by default; the one caller that's actually just
  /// confirmed reachability ([_checkWanHealth]'s LAN precheck, via
  /// [_reconnect]) opts in explicitly instead.
  Future<void> _stopWanIfNeeded({bool preferLan = false}) async {
    if (!_wanStreamStarted) return;
    _wanStreamStarted = false;
    final leaseToken = _wanLeaseToken;
    _wanLeaseToken = null;
    _wanHealthTimer?.cancel();
    _wanHealthTimer = null;
    unawaited(_cloudStreamStoppedSub?.cancel());
    _cloudStreamStoppedSub = null;
    _stopWanStallMonitor();
    final controller = wanVideoController;
    wanVideoController = null;
    if (controller != null) {
      try {
        await controller.pause();
      } catch (_) {
        // Best-effort — nothing more to do if the player's already broken.
      }
      unawaited(controller.dispose());
    }
    // After the player, not before — the session owns the loopback server the
    // player is reading from, so closing it first only makes the player throw
    // on the way down.
    await _stopWanMediaSession();

    if (preferLan) {
      final nuraeye = NuraeyeClient(connection);
      try {
        final lanResult = await CloudStreamingLanClient(
          nuraeye,
        ).stopCloudStreaming(timeout: const Duration(seconds: 3));
        if (lanResult is CameraSuccess) return;
      } finally {
        nuraeye.close();
      }
    }

    final thingName = connection.thingName;
    if (thingName == null || leaseToken == null) return;
    try {
      await AwsWanLiveViewClient(thingName).stopCloudStreaming(leaseToken);
    } catch (_) {
      // Best-effort — nothing more to do if the camera/relay is
      // unreachable at teardown time.
    }
  }

  /// Mutes/unmutes the received remote audio track — a real live-audio
  /// mute, distinct from the dummy-asset fallback's `VideoPlayerController`
  /// volume control.
  void setAudioEnabled(bool enabled) {
    for (final track in renderer.srcObject?.getAudioTracks() ?? const []) {
      track.enabled = enabled;
    }
  }

  MediaStreamTrack? get _remoteVideoTrack {
    final tracks = renderer.srcObject?.getVideoTracks();
    return (tracks == null || tracks.isEmpty) ? null : tracks.first;
  }

  /// Captures the current frame straight from the remote video track
  /// (`MediaStreamTrack.captureFrame()`, native-side) — not a
  /// `RenderRepaintBoundary` screenshot of the video widget, which is
  /// unreliable for a platform-view/texture-backed `RTCVideoView`. Returns
  /// null if there's no remote track yet (not connected).
  Future<Uint8List?> captureSnapshot() async {
    final track = _remoteVideoTrack;
    if (track == null) return null;
    try {
      final buffer = await track.captureFrame();
      return buffer.asUint8List();
    } catch (_) {
      return null;
    }
  }

  /// Starts a two-way-talk session over the camera's **dedicated** audio-only
  /// RTSPS talk module (`RtspTalkSession`, `TWO_WAY_TALK_GUIDE.md`) — a
  /// completely separate TLS connection from whatever live view is doing,
  /// discovered fresh via `TalkUriClient.getTalkUri()` every call (talk has
  /// no persistent URI to cache; §3 "no WAN leg" also means this is always
  /// a live LAN call). Requires [transport] to already be
  /// [LiveViewTransport.lan] as a proxy for "the phone is on this camera's
  /// LAN" (talk is LAN-only, §1) — no longer requires an existing WebRTC
  /// `_pc`, so talk now works during the RTSP-over-LAN live-view fallback
  /// too, not just when the camera reports WebRTC for this profile.
  ///
  /// **Replaces the old same-`RTCPeerConnection`-renegotiation mechanism**
  /// (2026-09-15) — see [_negotiate]'s doc comment for why that had to
  /// change: the camera's firmware removed the `{"talk": true}` flag on
  /// `POST /webrtc` entirely on 2026-09-11.
  Future<void> startTalk() async {
    if (_disposed || transport != LiveViewTransport.lan) return;

    talkStatus = TalkStatus.connecting;
    talkErrorMessage = null;
    notifyListeners();

    final nuraeye = NuraeyeClient(connection);
    final uriResult = await TalkUriClient(nuraeye).getTalkUri();
    nuraeye.close();
    if (_disposed) return;

    final TalkTarget target;
    switch (uriResult) {
      case CameraSuccess(:final value):
        target = value;
      case CameraFailure(:final reason):
        _failTalk(reason);
        return;
      case CameraTimeout():
        _failTalk('Timed out');
        return;
    }

    final session = RtspTalkSession(
      target.mediaUri,
      connection.username,
      connection.password,
    );
    final connectResult = await session.connect();
    if (_disposed) {
      await session.close();
      return;
    }
    switch (connectResult) {
      case TalkConnectResult.connected:
        _talkSession = session;
        _talkEndedSub = session.onEnded.listen(
          (_) => unawaited(_handleTalkSessionEnded()),
        );
        talkStatus = TalkStatus.talking;
        talkErrorMessage = null;
        await Helper.setSpeakerphoneOn(speakerphoneOn);
        notifyListeners();
      case TalkConnectResult.busy:
        talkStatus = TalkStatus.busy;
        notifyListeners();
      case TalkConnectResult.micPermissionDenied:
        _failTalk('Microphone permission denied');
      case TalkConnectResult.error:
        _failTalk('Could not start talk session');
    }
  }

  /// The talk session dropped on its own (network blip, camera-side
  /// eviction) — distinct from [endTalk], which the user triggers. Live
  /// view itself is untouched (talk no longer shares its connection).
  Future<void> _handleTalkSessionEnded() async {
    if (_disposed || talkStatus != TalkStatus.talking) return;
    await _releaseTalkSession();
    talkStatus = TalkStatus.error;
    talkErrorMessage = 'Talk ended: connection was interrupted';
    notifyListeners();
  }

  Future<void> _releaseTalkSession() async {
    await _talkEndedSub?.cancel();
    _talkEndedSub = null;
    final session = _talkSession;
    _talkSession = null;
    if (session != null) await session.close();
  }

  void _failTalk(String reason) {
    talkStatus = TalkStatus.error;
    talkErrorMessage = reason;
    notifyListeners();
  }

  /// Route-to-loudspeaker toggle, live during an active talk session —
  /// TWO_WAY_TALK_GUIDE.md §6.2. Distinct from [setAudioEnabled], which
  /// mutes plain live-view playback, not an active call.
  Future<void> setSpeakerphoneOn(bool enabled) async {
    speakerphoneOn = enabled;
    await Helper.setSpeakerphoneOn(enabled);
    notifyListeners();
  }

  /// Ends the talk session — [RtspTalkSession.close] (sends `TEARDOWN`,
  /// stops the mic/recorder and the return-audio player). **Live view is
  /// untouched** (2026-09-15) — talk runs on its own dedicated connection
  /// now, so ending a call no longer means reconnecting live view
  /// afterward the way the old shared-`RTCPeerConnection` mechanism did.
  Future<void> endTalk() async {
    if (talkStatus == TalkStatus.idle) return;
    await _releaseTalkSession();
    talkStatus = TalkStatus.idle;
    talkErrorMessage = null;
    if (!_disposed) notifyListeners();
  }

  /// Ends the session — best-effort `POST /webrtc/stop`, sent even if the
  /// session never reached [LiveViewStatus.connected] (see this class's own
  /// doc comment for why).
  Future<void> stop() async {
    if (_disposed) return;
    _disconnectGraceTimer?.cancel();
    _disconnectGraceTimer = null;
    _autoRetryTimer?.cancel();
    _autoRetryTimer = null;
    await _releaseTalkSession();
    talkStatus = TalkStatus.idle;
    await _teardownPeerConnection();
    final signalingUrl = _signalingUrl;
    if (signalingUrl != null) await _postStop(signalingUrl);
    await _stopWanIfNeeded();
    await _stopRtspIfNeeded();
    if (_disposed) return;
    status = LiveViewStatus.stopped;
    notifyListeners();
  }

  /// Best-effort `POST /webrtc/stop` — tells the camera to release the
  /// signaling slot immediately rather than waiting for it to notice the
  /// connection died on its own. Failures here don't block local teardown.
  Future<void> _postStop(Uri signalingUrl) async {
    try {
      await _http
          .post(signalingUrl.replace(path: '${signalingUrl.path}/stop'))
          .timeout(const Duration(seconds: 5));
    } catch (_) {
      // Best-effort — nothing more to do if the camera is already
      // unreachable at teardown time.
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _disconnectGraceTimer?.cancel();
    _autoRetryTimer?.cancel();
    _wanHealthTimer?.cancel();
    _wanStallTimer?.cancel();
    _statsTimer?.cancel();
    _rtspHealthTimer?.cancel();
    unawaited(_cloudStreamStoppedSub?.cancel());
    unawaited(_releaseTalkSession());
    unawaited(_teardownPeerConnection());
    unawaited(_stopWanIfNeeded());
    unawaited(_stopRtspIfNeeded());
    if (_rendererInitialized) unawaited(renderer.dispose());
    super.dispose();
  }
}
