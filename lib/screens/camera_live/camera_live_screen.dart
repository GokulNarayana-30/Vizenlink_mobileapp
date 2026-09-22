import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:camera_api/camera_api.dart';

import '../../app_state/camera_network.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_quick_video_encoder/flutter_quick_video_encoder.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:gal/gal.dart';
import 'package:go_router/go_router.dart';
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';

import '../../app_state/debug_transport_override.dart';
import '../../app_state/homes_controller.dart';
import '../../app_state/live_view_controller.dart';
import '../../app_state/route_observer.dart';
import '../../models/camera.dart';
import '../../rtsp/rtsp_remux_proxy.dart';
import '../../theme/app_colors.dart';
import '../../widgets/camera_thumbnail_image.dart';
import '../../widgets/glass_card.dart';
import '../../widgets/gradient_background.dart';
import '../../widgets/live_status_badges.dart';
import '../../widgets/navigation_leave_guard.dart';
import '../../widgets/scrollable_recording_timeline.dart';
import '../../widgets/settings_save_button.dart' show simulateCameraSave;
import '../camera_settings/camera_settings_screen.dart';
import 'ai_mode_screen.dart';

/// `CameraVideoMode` <-> ONVIF `IrCutFilter` wire values — mirrors
/// `video_mode_screen.dart`'s private mapping of the same name (Dart
/// privacy means it can't be imported directly; this is the only other
/// place in the app that sets this field, so a small local copy is
/// simpler than threading a shared helper file just for this one mapping).
String _videoModeToIrCutFilter(CameraVideoMode mode) => switch (mode) {
  CameraVideoMode.day => 'ON',
  CameraVideoMode.night => 'OFF',
  CameraVideoMode.auto => 'AUTO',
};

/// Reverse of [_videoModeToIrCutFilter] — mirrors `video_mode_screen.dart`'s
/// private mapping of the same name, same "small local copy, Dart privacy
/// means it can't be imported directly" reasoning.
CameraVideoMode? _irCutFilterToVideoMode(String? wireValue) =>
    switch (wireValue?.toUpperCase()) {
      'ON' => CameraVideoMode.day,
      'OFF' => CameraVideoMode.night,
      'AUTO' => CameraVideoMode.auto,
      _ => null,
    };

/// Mirrors `privacy_mode_screen.dart`'s private mapping of the same name.
CameraPrivacyMode _fromWirePrivacyMode(PrivacyMode mode) => switch (mode) {
  PrivacyMode.none => CameraPrivacyMode.off,
  PrivacyMode.full => CameraPrivacyMode.full,
  PrivacyMode.zone => CameraPrivacyMode.zone,
};

const _recordingLimit = Duration(seconds: 30);
const _continuePromptCountdown = Duration(seconds: 5);

/// Frames/sec captured for a manual recording — a deliberate quality/perf
/// tradeoff (see [_startFrameCaptureTimer]): high enough to read as video,
/// low enough that a widget-boundary screenshot + RGBA->YUV conversion each
/// tick doesn't stall the UI thread.
const _recordingFps = 8;

/// Longest edge of the recorded clip, in pixels — bounds encoder
/// bitrate/CPU cost regardless of the device's actual screen density.
const _recordingMaxDimension = 960;

class CameraLiveScreen extends StatefulWidget {
  const CameraLiveScreen({
    super.key,
    required this.camera,
    required this.homesController,
  });

  static const routeName = 'live';

  /// Initial snapshot passed via navigation `extra`. The live, up-to-date
  /// camera (reflecting settings changes made elsewhere, e.g. On-Screen
  /// Display's OSD toggles) is looked up from [homesController] by id — see
  /// `_currentCamera`.
  final Camera camera;
  final HomesController homesController;

  @override
  State<CameraLiveScreen> createState() => _CameraLiveScreenState();
}

class _CameraLiveScreenState extends State<CameraLiveScreen>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver, RouteAware {
  late final TabController _tabController;
  final _videoBoundaryKey = GlobalKey();
  final _playbackTabKey = GlobalKey<_PlaybackTabState>();

  /// Real bug fix, 2026-09-15: this screen is pushed *inside* a
  /// `StatefulShellBranch` (`main.dart`), nested within `MainShell`'s own
  /// outer `Scaffold` — so `ScaffoldMessenger.of(context)` from this State's
  /// own `context` (an ancestor of this screen's own `Scaffold`, not a
  /// descendant of it) resolved to the app-wide messenger above `MainShell`,
  /// not this screen's own. A `MaterialBanner` shown that way rendered
  /// detached from this screen's own AppBar (a visible gap above LIVE-040's
  /// cellular banner, real device report). Every snackbar/banner this screen
  /// shows now goes through this screen's own dedicated `ScaffoldMessenger`
  /// instead (wrapped around `_buildScaffold`'s tree below) via this key, so
  /// they're always positioned relative to this screen's own Scaffold.
  /// `?.` everywhere it's used, not `!` — a callback that outlives this
  /// screen's own mount (rare, but not impossible) should silently skip a
  /// snackbar rather than crash.
  final _messengerKey = GlobalKey<ScaffoldMessengerState>();

  /// Real LAN WebRTC live-view session — null when this camera has no saved
  /// connection yet (shows [_LiveUnavailable] instead of any video — see its
  /// own doc for why this app never substitutes fake footage here). WAN
  /// fallback isn't wired up here yet — LAN only for now.
  LiveViewController? _liveViewController;
  bool _isMuted = false;

  /// LIVE-047/048/049 — tap-to-reveal play/pause + skip overlay on the
  /// Playback tab's video, matching standard video-player UX (tap the
  /// video to show controls, auto-hide after a few seconds of no
  /// interaction). Gated to the Playback tab in the Stack itself; reset
  /// whenever the user switches away from it so returning to Playback
  /// later starts hidden again, not mid-timer.
  bool _showPlaybackControls = false;
  Timer? _hidePlaybackControlsTimer;

  /// The real recorded clip currently open on the Playback tab, if any —
  /// owned/downloaded by `_PlaybackTabState`, reported up here (via
  /// [_onPlaybackClipStateChanged]) so the shared video Stack/`_HeroVideo`
  /// can render it. Null means show [_playbackAvailability] instead (a
  /// spinner while checking, or "No recording available").
  VideoPlayerController? _playbackClipController;
  _PlaybackAvailability _playbackAvailability = _PlaybackAvailability.loading;

  void _onPlaybackClipStateChanged(
    VideoPlayerController? controller,
    _PlaybackAvailability availability,
  ) {
    if (!mounted) return;
    setState(() {
      _playbackClipController = controller;
      _playbackAvailability = availability;
    });
    // Real bug, found 2026-09-07 from a direct user report ("camera live
    // page is showing offline" while Playback was actively streaming real
    // video): `_syncLiveConnectionForActiveTab` deliberately stops the Live
    // tab's WebRTC connection while Playback is active (to avoid resource
    // contention on the camera's limited concurrent-session capacity — see
    // that method's own doc), which freezes `_syncCameraOnlineStatus`'s own
    // updates too (a `stopped` controller status maps to `online: null`,
    // i.e. "don't touch it"). If the camera happened to be marked offline
    // before switching to Playback (e.g. from an earlier real outage) and
    // has since recovered, nothing on the Live side ever gets a chance to
    // notice — the badge just stays stuck. A real clip successfully opening
    // and playing here is exactly as strong a reachability signal as Live's
    // own `LiveViewStatus.connected` (same reasoning as
    // `_syncCameraOnlineStatus`'s own doc comment: a successful call to the
    // camera is a real reachability check), so it gets to write the same
    // way.
    if (availability == _PlaybackAvailability.ready) {
      _syncCameraOnlineFromPlayback();
    }
  }

  /// See [_onPlaybackClipStateChanged]'s own doc for why this exists —
  /// mirrors [_syncCameraOnlineStatus]'s write guard exactly (only writes
  /// when the derived value actually changed), just driven by Playback's
  /// own RTSP session succeeding instead of Live's WebRTC connecting.
  void _syncCameraOnlineFromPlayback() {
    final current = _currentCamera(widget.homesController.value);
    if (current.isOnline) return;
    widget.homesController.updateCamera(
      current.id,
      (camera) => camera.copyWith(isOnline: true, lastSeen: DateTime.now()),
    );
  }

  bool _isSpotlightOn = false;
  bool _isSpotlightShortcutBusy = false;
  bool _isSirenOn = false;
  bool _isSirenShortcutBusy = false;
  bool _isWarningOn = false;
  bool _isWarningShortcutBusy = false;
  bool _isPrivacyShortcutBusy = false;
  bool _isVideoModeShortcutBusy = false;

  bool _isRecording = false;
  DateTime? _recordingStartedAt;
  Timer? _recordingTicker;
  Duration _recordingElapsed = Duration.zero;

  /// Set only while a recording is in progress. See
  /// [_toggleRecording]/[_stopRecording].
  String? _liveRecordingPath;

  /// Periodic widget-boundary capture that feeds [FlutterQuickVideoEncoder]
  /// while a recording is in progress — see [_startFrameCaptureTimer].
  Timer? _recordingCaptureTimer;

  /// Guards against a new capture tick starting before the previous one's
  /// decode/encode round trip finishes — dropping an occasional frame under
  /// load beats letting captures queue up and fall further and further
  /// behind real time.
  bool _recordingFrameCaptureBusy = false;

  int _recordingWidth = 0;
  int _recordingHeight = 0;

  List<ConnectivityResult> _connectivity = [ConnectivityResult.none];
  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;

  /// Guards [_updateCellularReminder] against calling `showMaterialBanner`
  /// repeatedly on every connectivity-changed event while still on
  /// cellular (e.g. a Bluetooth toggle firing a new event with the same
  /// Wi-Fi/mobile state) — repeated calls would queue duplicate banners
  /// instead of just keeping the one already showing.
  bool _cellularBannerVisible = false;

  bool get _isOnCellular =>
      _connectivity.contains(ConnectivityResult.mobile) &&
      !_connectivity.contains(ConnectivityResult.wifi);

  /// Hardware-presence gate for the Talk control (TALK/LIVE-011) —
  /// `AudioCapabilityClient.getAudioCapability()`'s `hasSpeaker` (the
  /// camera needs a speaker to play back the phone's mic audio; this
  /// client's own doc calls it "the talk control's minimum requirement").
  /// Real gap fixed 2026-09-15: this was never checked anywhere — a camera
  /// with no speaker hardware still showed a working-looking Talk button
  /// that would only fail (or silently no-op) once actually tapped. `null`
  /// until loaded (or on a camera reachable only over WAN, since this check
  /// is LAN-only per its own doc) — [_toggleTalk] treats that the same as
  /// "assume supported" so a mid-onboarding/WAN-only camera isn't wrongly
  /// told it lacks hardware nobody's actually checked yet.
  AudioCapability? _audioCapability;

  Future<void> _loadAudioCapability() async {
    final connection = widget.camera.connection;
    if (connection == null) return;
    final client = AudioCapabilityClient(
      connection,
      httpClient: CameraNetwork.clientFor(connection.host),
      endpoint: CameraNetwork.media2EndpointFor(connection.host),
    );
    final result = await client.getAudioCapability();
    CameraNetwork.rememberMedia2Endpoint(
      connection.host,
      client.resolvedEndpoint,
    );
    client.close();
    if (!mounted) return;
    if (result case CameraSuccess(:final value)) {
      setState(() => _audioCapability = value);
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _tabController = TabController(length: 2, vsync: this)
      ..addListener(() {
        if (!_tabController.indexIsChanging) {
          if (_tabController.index != 1) _resetPlaybackControlsOverlay();
          _syncLiveConnectionForActiveTab();
          setState(() {});
        }
      });
    final connection = widget.camera.connection;
    if (connection != null) {
      _liveViewController = _createLiveViewController(connection)
        ..addListener(_onLiveViewChanged)
        ..connect();
      // Signal strength / bitrate / shortcut-tile state are deferred until
      // the connect attempt resolves — see [_maybeStartSecondaryLoads]'s doc
      // for why firing them concurrently with the initial connect used to
      // be a problem.
      unawaited(_loadAudioCapability());
    }
    _initConnectivity();
    DebugTransportOverride.instance.addListener(_onGlobalForceTransportChanged);
  }

  LiveViewController _createLiveViewController(CameraConnection connection) {
    final controller = LiveViewController(
      connection,
      forceTransport: DebugTransportOverride.instance.value,
    );
    // Seed both transports' auto-adjust from the same persisted preference
    // (Camera.streamQuality) — whichever transport ends up connecting starts
    // already in the mode the user last picked, rather than only LAN
    // honoring it.
    if (widget.camera.streamQuality == CameraStreamQuality.auto) {
      controller.setAutoQualityLadder(true);
      controller.setWanAutoQuality(true);
    }
    return controller;
  }

  /// Test-only — see [DebugTransportOverride]'s doc. Fires whenever the
  /// global Force LAN/WAN override changes (e.g. the user picked a
  /// different option from the Dashboard's app bar while this screen is
  /// already open) — tears down whatever session is active and starts a
  /// fresh one under the newly-selected override.
  Future<void> _onGlobalForceTransportChanged() async {
    if (!mounted) return;
    final connection = widget.camera.connection;
    if (connection == null) return;
    final oldController = _liveViewController;
    oldController?.removeListener(_onLiveViewChanged);
    await oldController?.stop();
    oldController?.dispose();
    if (!mounted) return;
    setState(() {
      _secondaryLoadsStarted = false;
      _liveViewController = _createLiveViewController(connection)
        ..addListener(_onLiveViewChanged)
        ..connect();
    });
  }

  /// Refreshes the Privacy Mode/Video Mode/Siren/Spotlight/Warning shortcut
  /// tiles with the camera's actual current state on screen open — without
  /// this, they only ever reflected whatever this app itself last set (via
  /// these same tiles, or a sync elsewhere), silently drifting out of date
  /// if changed by another client, the camera's own web UI, or (for
  /// deterrence) a Response Action auto-triggered by a detection event (see
  /// `alert_settings_screen.dart`). LAN-only, no WAN fallback — same
  /// "current-value read, best-effort" treatment as [_loadRealBitrate]/
  /// [_pollSignalStrength]; a failed fetch just leaves the tiles showing
  /// whatever they already had rather than blocking the screen.
  Future<void> _loadShortcutState() async {
    final connection = widget.camera.connection;
    if (connection == null) return;

    // Run one at a time, not concurrently — this camera's embedded HTTP
    // server can stall for seconds under a burst of concurrent requests
    // (same reasoning as `camera_settings_cache.dart`'s prefetch).
    final nuraeye = NuraeyeClient(connection);
    final imagingClient = OnvifImagingClient(
      connection,
      httpClient: CameraNetwork.clientFor(connection.host),
    );
    final privacyResult = await PrivacyModeClient(nuraeye).getPrivacyMode();
    final imagingResult = await imagingClient.getImagingSettings();
    final statusResult = await DeterrenceClient(nuraeye).getDeterrenceStatus();
    nuraeye.close();
    imagingClient.close();
    if (!mounted) return;

    if (privacyResult case CameraSuccess(:final value)) {
      widget.homesController.updateCamera(
        widget.camera.id,
        (current) => current.copyWith(privacyMode: _fromWirePrivacyMode(value)),
      );
    }
    if (imagingResult case CameraSuccess(:final value)) {
      final mode = _irCutFilterToVideoMode(value.irCutFilterMode);
      if (mode != null) {
        widget.homesController.updateCamera(
          widget.camera.id,
          (current) => current.copyWith(videoMode: mode),
        );
      }
    }
    if (statusResult case CameraSuccess(:final value)) {
      setState(() {
        _isSpotlightOn = value.spotlight;
        _isSirenOn = value.siren;
        _isWarningOn = value.warning;
      });
    }
  }

  /// Real configured encoder bitrate (LIVE-029's badge) — a stable
  /// configuration fact from Video Encoder settings, not a live
  /// measurement, so a one-time fetch on screen open is enough (unlike
  /// signal strength/bitrate telemetry, this doesn't change mid-session
  /// unless the user visits Video Encoder settings and changes it, which
  /// already persists a fresh value through `HomesController` itself).
  /// Previously `Camera.bitrateKbps` only ever got a real value if the user
  /// had specifically opened Video Encoder settings before — this screen
  /// showed a permanently-stale/default number otherwise.
  Future<void> _loadRealBitrate() async {
    final connection = widget.camera.connection;
    if (connection == null) return;
    final client = OnvifVideoEncoderClient(
      connection,
      httpClient: CameraNetwork.clientFor(connection.host),
      endpoint: CameraNetwork.media2EndpointFor(connection.host),
    );
    var result = await client.getVideoEncoderSettings();
    CameraNetwork.rememberMedia2Endpoint(
      connection.host,
      client.resolvedEndpoint,
    );
    client.close();

    final thingName = connection.thingName;
    if (result is! CameraSuccess && thingName != null) {
      result = await WanVideoEncoderClient(thingName).getVideoEncoderSettings();
    }
    if (!mounted) return;
    if (result case CameraSuccess(:final value)) {
      widget.homesController.updateCamera(
        widget.camera.id,
        (current) => current.copyWith(bitrateKbps: value.bitrate.toDouble()),
      );
    }
  }

  /// Real LAN reachability probe (`NetworkInfoClient.getWifiSignalStrength`
  /// — same call `wifi_config_screen.dart` already uses) — LIVE-030's
  /// signal bars used to always read `Camera.signalStrength`'s permanent
  /// default of 0 since nothing ever wrote a real value into it. Persisted
  /// via `HomesController.updateCamera` (unlike the fast-changing bitrate
  /// reading, RSSI genuinely is a "current camera state" fact worth keeping
  /// around, same as `pingCameraReachability`'s `isOnline`).
  static const _signalPollInterval = Duration(seconds: 20);
  Timer? _signalPollTimer;

  Future<void> _pollSignalStrength() async {
    final connection = widget.camera.connection;
    if (connection == null) return;
    final client = NetworkInfoClient(connection);
    final result = await client.getWifiSignalStrength();
    client.close();
    if (!mounted) return;
    if (result case CameraSuccess(:final value)) {
      final bars = barsForRssi(value.rssi);
      widget.homesController.updateCamera(
        widget.camera.id,
        (current) => current.copyWith(signalStrength: bars),
      );
    }
  }

  /// Backgrounding the app doesn't dispose this screen — the widget tree
  /// stays alive, so without this the LAN peer connection / WAN cloud
  /// stream just keeps running with nobody watching (a real complaint: the
  /// camera kept streaming after the phone app was closed/backgrounded).
  /// [paused] covers both "home button pressed" and, on Android, the
  /// process being backgrounded ahead of a possible kill — there's no
  /// reliable further callback once the OS actually terminates the process,
  /// so this is the last point a graceful stop can be sent. Reconnects on
  /// [resumed] only if the session was actually torn down here (not if it
  /// simply failed/was already stopped for an unrelated reason) and the
  /// screen is still on the Live tab.
  bool _stoppedForBackground = false;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final controller = _liveViewController;
    if (controller == null) return;
    switch (state) {
      case AppLifecycleState.paused:
        if (controller.status == LiveViewStatus.connected ||
            controller.status == LiveViewStatus.connecting ||
            controller.status == LiveViewStatus.reconnecting) {
          _stoppedForBackground = true;
          unawaited(controller.stop());
        }
      case AppLifecycleState.resumed:
        if (_stoppedForBackground) {
          _stoppedForBackground = false;
          if (_tabController.index == 0) controller.connect();
        }
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
        break;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    routeObserver.subscribe(this, ModalRoute.of(context)! as PageRoute);
  }

  /// `context.push`-ing to a sub-screen (e.g. Camera Settings) leaves this
  /// screen mounted underneath the new route, same underlying issue as the
  /// backgrounding fix above — the session doesn't know it's not visible
  /// anymore unless something tells it. A real complaint: the stream/audio
  /// kept running while browsing screens pushed on top of Live view.
  /// [didPushNext] fires when this route gets covered; [didPopNext] fires
  /// when it's back on top. Shares [_stoppedForBackground]'s reasoning for
  /// only reconnecting what this screen itself paused.
  bool _stoppedForNavigation = false;

  @override
  void didPushNext() {
    final controller = _liveViewController;
    if (controller == null) return;
    if (controller.status == LiveViewStatus.connected ||
        controller.status == LiveViewStatus.connecting ||
        controller.status == LiveViewStatus.reconnecting) {
      _stoppedForNavigation = true;
      unawaited(controller.stop());
    }
  }

  @override
  void didPopNext() {
    final controller = _liveViewController;
    if (controller == null) return;
    if (_stoppedForNavigation) {
      _stoppedForNavigation = false;
      if (_tabController.index == 0) controller.connect();
    }
  }

  /// Shares [_stoppedForNavigation]'s reasoning, triggered by *tab* switches
  /// within this same screen instead of route navigation. **Real bug, found
  /// 2026-09-07**: the Live tab's WebRTC session previously kept running —
  /// and, on any connectivity hiccup, kept reconnecting in a loop every
  /// ~15s — the whole time the Playback tab was active, even though nothing
  /// was watching it. That session competed with Playback's real clip
  /// downloads (`RecordingsClient.downloadClip`) for the same camera's
  /// limited embedded-server capacity, and was a likely contributor to
  /// download failures (`HTTP 404`, `Connection reset by peer`) observed on
  /// real hardware while both were active together.
  bool _stoppedForPlaybackTab = false;

  void _syncLiveConnectionForActiveTab() {
    final controller = _liveViewController;
    if (controller == null) return;
    if (_tabController.index == 1) {
      if (controller.status == LiveViewStatus.connected ||
          controller.status == LiveViewStatus.connecting ||
          controller.status == LiveViewStatus.reconnecting) {
        _stoppedForPlaybackTab = true;
        unawaited(controller.stop());
      }
    } else if (_stoppedForPlaybackTab) {
      _stoppedForPlaybackTab = false;
      controller.connect();
    }
  }

  /// Shifts LIVE-007/LIVE-008 up so they don't sit underneath the talk
  /// status bar (TALK-001) when it's showing at the very bottom edge.
  double get _cornerButtonBottomInset =>
      (_liveViewController?.talkStatus ?? TalkStatus.idle) == TalkStatus.idle
      ? 8
      : 56;

  /// Rebuilds on any [LiveViewController] change (connection status, talk
  /// status) — coarse-grained, matching this screen's existing setState
  /// style, but cheap since this screen's build is small relative to a
  /// video frame render. Deferred to a microtask: [LiveViewController] can
  /// call `notifyListeners()` from a native platform-channel callback that
  /// sometimes lands mid-build, and calling `setState` synchronously in
  /// that case throws ("setState() or markNeedsBuild() called during
  /// build" — hit on real hardware 2026-08-14). A microtask runs just after
  /// the current build finishes instead.
  void _onLiveViewChanged() {
    _syncCameraOnlineStatus();
    _syncLastKnownTransport();
    _maybeStartSecondaryLoads();
    // Auto-driven quality changes (LAN ladder or WAN stall-based stepping)
    // set this once right before reconnecting — surfaced here so the change
    // is never silent, the whole point of allowing it again on this screen.
    final autoMessage = _liveViewController?.autoQualityChangeMessage;
    if (autoMessage != null) {
      _liveViewController?.autoQualityChangeMessage = null;
      _messengerKey.currentState?.showSnackBar(
        SnackBar(content: Text(autoMessage)),
      );
    }
    Future.microtask(() {
      if (mounted) setState(() {});
    });
  }

  /// Fires once, the first time [_liveViewController] leaves
  /// [LiveViewStatus.connecting] (connected or failed) — deferred rather
  /// than fired at `initState` alongside `connect()` itself, so signal
  /// strength / real bitrate / shortcut-tile reads don't compete with the
  /// time-critical WebRTC signaling POST for the same camera's embedded
  /// HTTP server. Previously this screen fired ~6 concurrent LAN calls the
  /// instant it opened, all against the same camera the connect sequence
  /// was also mid-negotiation with.
  bool _secondaryLoadsStarted = false;

  void _maybeStartSecondaryLoads() {
    if (_secondaryLoadsStarted) return;
    final controller = _liveViewController;
    if (controller == null || controller.status == LiveViewStatus.connecting) {
      return;
    }
    _secondaryLoadsStarted = true;
    unawaited(_runSecondaryLoads());
  }

  /// Runs the non-critical LAN reads one at a time (not as a
  /// `Future.wait`-style burst) now that the connect attempt itself has
  /// resolved either way.
  Future<void> _runSecondaryLoads() async {
    await _pollSignalStrength();
    if (!mounted) return;
    _signalPollTimer = Timer.periodic(
      _signalPollInterval,
      (_) => unawaited(_pollSignalStrength()),
    );
    await _loadRealBitrate();
    if (!mounted) return;
    await _loadShortcutState();
  }

  /// The live-view connection attempt *is* a reachability check — a failed
  /// signaling call means the camera genuinely didn't respond, same as the
  /// LAN pings `camera_sync.dart` uses for the dashboard's offline badge.
  /// Without this, `Camera.isOnline` only gets updated by the dashboard's
  /// own 5-minute timer, so a camera that dies mid-stream would still show
  /// "online" everywhere else in the app for up to 5 minutes even though
  /// this screen already knows it's not reachable. Only writes when the
  /// derived online value actually changed, so this doesn't fire on every
  /// unrelated controller notification (talk status, reconnecting, etc).
  void _syncCameraOnlineStatus() {
    final controller = _liveViewController;
    if (controller == null) return;
    final bool? online = switch (controller.status) {
      LiveViewStatus.connected => true,
      LiveViewStatus.failed => false,
      LiveViewStatus.connecting ||
      LiveViewStatus.reconnecting ||
      LiveViewStatus.stopped => null,
    };
    if (online == null) return;
    final current = _currentCamera(widget.homesController.value);
    if (current.isOnline == online) return;
    widget.homesController.updateCamera(
      current.id,
      (camera) => camera.copyWith(
        isOnline: online,
        lastSeen: online ? DateTime.now() : null,
      ),
    );
  }

  /// Records which transport actually delivered the current connection —
  /// see `Camera.lastKnownWan`'s doc. Only writes on a genuine
  /// [LiveViewStatus.connected] (never on `connecting`/`reconnecting`, which
  /// don't yet know, or `failed`/`stopped`, which don't mean the *other*
  /// transport is the answer) and only when it actually changed, same
  /// guard style as [_syncCameraOnlineStatus].
  void _syncLastKnownTransport() {
    final controller = _liveViewController;
    if (controller == null || controller.status != LiveViewStatus.connected) {
      return;
    }
    final isWan = controller.transport == LiveViewTransport.wan;
    final current = _currentCamera(widget.homesController.value);
    if (current.lastKnownWan == isWan) return;
    widget.homesController.updateCamera(
      current.id,
      (camera) => camera.copyWith(lastKnownWan: isWan),
    );
  }

  Future<void> _initConnectivity() async {
    final initial = await Connectivity().checkConnectivity();
    if (!mounted) return;
    setState(() => _connectivity = initial);
    _updateCellularReminder();
    _connectivitySubscription = Connectivity().onConnectivityChanged.listen((
      result,
    ) {
      if (!mounted) return;
      setState(() => _connectivity = result);
      _updateCellularReminder();
    });
    if (_isOnCellular && widget.camera.isOnline) {
      final shouldContinue = await _confirmCellularUsage();
      if (!mounted) return;
      if (!shouldContinue) context.pop();
    }
  }

  Future<bool> _confirmCellularUsage() async {
    final shouldContinue = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const Key('LIVE-039'),
        title: const Text('You\'re on mobile data'),
        content: const Text(
          'Streaming video will use your mobile data. Continue?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Continue'),
          ),
        ],
      ),
    );
    return shouldContinue ?? false;
  }

  /// LIVE-040 — a persistent `MaterialBanner` (not a periodic snackbar that
  /// disappears after a few seconds) for as long as the phone stays on
  /// cellular, so "you're using mobile data" stays visible at a glance
  /// instead of needing to be re-shown on a timer to be noticed.
  void _updateCellularReminder() {
    if (_isOnCellular) {
      if (_cellularBannerVisible) return;
      _cellularBannerVisible = true;
      _messengerKey.currentState?.showMaterialBanner(
        MaterialBanner(
          key: const Key('LIVE-040'),
          content: const Text('Using mobile data to stream video'),
          leading: const Icon(Icons.signal_cellular_alt, color: Colors.amber),
          actions: [
            TextButton(
              onPressed: () {
                _messengerKey.currentState?.hideCurrentMaterialBanner();
                _cellularBannerVisible = false;
              },
              child: const Text('Dismiss'),
            ),
          ],
        ),
      );
    } else if (_cellularBannerVisible) {
      _messengerKey.currentState?.hideCurrentMaterialBanner();
      _cellularBannerVisible = false;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    routeObserver.unsubscribe(this);
    DebugTransportOverride.instance.removeListener(
      _onGlobalForceTransportChanged,
    );
    _recordingTicker?.cancel();
    _recordingCaptureTimer?.cancel();
    if (_liveRecordingPath != null) {
      // Best-effort — the widget is going away outside the normal
      // tap-to-stop/LeaveGuard paths (e.g. hot reload), so there's no
      // context left to save via Gal; just release the native encoder.
      unawaited(FlutterQuickVideoEncoder.finish());
    }
    _signalPollTimer?.cancel();
    _connectivitySubscription?.cancel();
    _hidePlaybackControlsTimer?.cancel();
    _tabController.dispose();
    _liveViewController?.removeListener(_onLiveViewChanged);
    _liveViewController?.stop();
    _liveViewController?.dispose();
    super.dispose();
  }

  void _toggleMute() {
    setState(() {
      _isMuted = !_isMuted;
      _liveViewController?.setAudioEnabled(!_isMuted);
      // WAN playback (and the RTSP-over-LAN fallback, STREAMING_GUIDE.md
      // §2.5) are both a plain VideoPlayerController, not a WebRTC track —
      // setAudioEnabled (above) only affects the WebRTC renderer's tracks.
      _liveViewController?.wanVideoController?.setVolume(_isMuted ? 0 : 1);
      _liveViewController?.lanRtspVideoController?.setVolume(_isMuted ? 0 : 1);
    });
  }

  /// LIVE-047/048/049's tap target — shows the overlay on a tap, hides it on
  /// a second tap, and (re)starts the 4-second auto-hide countdown whenever
  /// it becomes visible.
  void _togglePlaybackControlsVisibility() {
    setState(() => _showPlaybackControls = !_showPlaybackControls);
    if (_showPlaybackControls) {
      _startHidePlaybackControlsTimer();
    } else {
      _hidePlaybackControlsTimer?.cancel();
    }
  }

  void _startHidePlaybackControlsTimer() {
    _hidePlaybackControlsTimer?.cancel();
    _hidePlaybackControlsTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => _showPlaybackControls = false);
    });
  }

  void _resetPlaybackControlsOverlay() {
    _hidePlaybackControlsTimer?.cancel();
    _hidePlaybackControlsTimer = null;
    if (_showPlaybackControls) setState(() => _showPlaybackControls = false);
  }

  /// LIVE-048 — toggles the currently-open real clip's play/pause state
  /// (optimistic, same reasoning as the old dummy-asset version this
  /// replaced: `pause()`/`play()` update `.value.isPlaying` synchronously
  /// before their async platform call resolves). No-op while no real clip
  /// is open (nothing to toggle — see `_PlaybackAvailability`). Restarts
  /// the auto-hide countdown since this counts as fresh interaction with
  /// the overlay.
  void _togglePlaybackPlayPause() {
    final controller = _playbackClipController;
    if (controller == null) return;
    setState(() {
      if (controller.value.isPlaying) {
        controller.pause();
      } else {
        controller.play();
      }
    });
    if (_showPlaybackControls) _startHidePlaybackControlsTimer();
  }

  /// LIVE-047/LIVE-049 — jumps the Playback tab's real timeline needle by
  /// [seconds] (negative to skip back). Delegates to
  /// `_PlaybackTabState.skipSeconds` (via [_playbackTabKey]) — only that
  /// state knows the day's real clip list, how to turn a timeline skip into
  /// the right clip + seek, and how to snap into the nearest recorded clip
  /// if the skip lands in a gap.
  void _skipPlaybackVideo(double seconds) {
    _playbackTabKey.currentState?.skipSeconds(seconds);
    if (_showPlaybackControls) _startHidePlaybackControlsTimer();
  }

  /// Captures the current on-screen video frame as PNG bytes, without
  /// saving it anywhere — shared by [_takeSnapshot] (LIVE-009, saves to the
  /// gallery) and AI Mode's frozen-frame entry/retake (LIVE-043/AIMODE-006).
  /// Prefers a real capture straight from the remote WebRTC video track
  /// (`LiveViewController.captureSnapshot`) when the Live tab is showing a
  /// connected real feed — a `RenderRepaintBoundary` screenshot of the
  /// platform-view/texture-backed `RTCVideoView` isn't reliable. Falls back
  /// to the boundary screenshot for the Playback tab, or any camera with no
  /// real connection.
  Future<Uint8List?> _captureFrame() async {
    final liveViewController = _liveViewController;
    if (_tabController.index == 0 &&
        liveViewController != null &&
        liveViewController.status == LiveViewStatus.connected) {
      final liveFrame = await liveViewController.captureSnapshot();
      if (liveFrame != null) return liveFrame;
    }
    final boundary =
        _videoBoundaryKey.currentContext?.findRenderObject()
            as RenderRepaintBoundary?;
    if (boundary == null) return null;
    final image = await boundary.toImage(pixelRatio: 2);
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    return byteData?.buffer.asUint8List();
  }

  Future<void> _takeSnapshot() async {
    try {
      final bytes = await _captureFrame();
      if (bytes == null) return;
      await Gal.putImageBytes(
        bytes,
        name: 'cctv_snapshot_${DateTime.now().millisecondsSinceEpoch}',
      );
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Snapshot saved')));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Could not save snapshot')));
    }
  }

  /// rootNavigator: true — same reasoning as [_openFullscreen]: this screen
  /// lives inside a StatefulShellRoute branch with its own nested Navigator,
  /// so pushing on the branch Navigator alone would keep MainShell's bottom
  /// nav bar visible underneath AI Mode instead of it taking over the
  /// screen. Not a go_router route for the same reason fullscreen isn't —
  /// it's a modal takeover of this screen, not an independently
  /// deep-linkable destination.
  Future<void> _openAiMode(Camera camera) async {
    final frame = await _captureFrame();
    if (!mounted || frame == null) return;
    await Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute(
        builder: (_) => AiModeScreen(
          args: AiModeLaunchArgs(
            camera: camera,
            initialFrame: frame,
            captureFrame: _captureFrame,
          ),
        ),
      ),
    );
  }

  Future<void> _toggleRecording() async {
    if (_isRecording) {
      await _stopRecording(save: true);
      return;
    }

    final liveViewController = _liveViewController;

    // Block recording when there's no camera connection at all — nothing on
    // screen to record.
    if (_tabController.index == 0 && liveViewController == null) {
      _messengerKey.currentState?.showSnackBar(
        const SnackBar(
          content: Text(
            'Add this camera\'s IP address in Settings to enable recording',
          ),
        ),
      );
      return;
    }

    // Block recording when the camera connection exists but isn't live yet
    // (still connecting / reconnecting / failed) — the video area would just
    // be recording a spinner/placeholder.
    if (_tabController.index == 0 &&
        liveViewController != null &&
        liveViewController.status != LiveViewStatus.connected) {
      _messengerKey.currentState?.showSnackBar(
        const SnackBar(
          content: Text(
            'Camera isn\'t live yet — wait for the stream to connect first',
          ),
        ),
      );
      return;
    }

    // Records whatever is actually on screen in the video area (LIVE-010's
    // `RepaintBoundary`/`captureSnapshot` via [_captureFrame]) via
    // [FlutterQuickVideoEncoder], a hardware (MediaCodec/AVFoundation) h264
    // encoder fed frame-by-frame — not a track-level recording, so it works
    // the same regardless of transport (LAN WebRTC, RTSP-over-LAN fallback,
    // or WAN/HLS).
    final targetSize = _recordingTargetSize();
    if (targetSize == null) return;
    final (width, height) = targetSize;

    final tempDir = await getTemporaryDirectory();
    final path =
        '${tempDir.path}/cctv_live_${DateTime.now().millisecondsSinceEpoch}.mp4';
    try {
      await FlutterQuickVideoEncoder.setup(
        width: width,
        height: height,
        fps: _recordingFps,
        videoBitrate: 2 * 1000 * 1000,
        profileLevel: ProfileLevel.any,
        // Video-only — no audio track (audioChannels/sampleRate == 0 skips
        // muxing one at all rather than muxing a silent one).
        audioChannels: 0,
        audioBitrate: 0,
        sampleRate: 0,
        filepath: path,
      );
    } catch (_) {
      if (!mounted) return;
      _messengerKey.currentState?.showSnackBar(
        const SnackBar(content: Text('Could not start recording')),
      );
      return;
    }
    if (!mounted) return;

    setState(() {
      _isRecording = true;
      _liveRecordingPath = path;
      _recordingWidth = width;
      _recordingHeight = height;
      _recordingStartedAt = DateTime.now();
      _recordingElapsed = Duration.zero;
    });
    _startFrameCaptureTimer();
    _startRecordingTicker();
  }

  /// Fixed logical (width, height) the whole clip is captured/encoded at —
  /// resolved once from the video area's current render size so every frame
  /// fed to [FlutterQuickVideoEncoder] matches (its encoder is configured
  /// for one fixed size for the life of the recording), and capped at
  /// [_recordingMaxDimension] on its long edge. Returns null if the video
  /// area isn't laid out yet.
  (int, int)? _recordingTargetSize() {
    final boundary =
        _videoBoundaryKey.currentContext?.findRenderObject()
            as RenderRepaintBoundary?;
    final size = boundary?.size;
    if (size == null || size.width <= 0 || size.height <= 0) return null;
    final scale = _recordingMaxDimension / math.max(size.width, size.height);
    final width = (size.width * scale).round();
    final height = (size.height * scale).round();
    // MediaCodec's YUV420 conversion needs even dimensions.
    return (width - (width % 2), height - (height % 2));
  }

  void _startRecordingTicker() {
    _recordingTicker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted || _recordingStartedAt == null) return;
      setState(() {
        _recordingElapsed = DateTime.now().difference(_recordingStartedAt!);
      });
      if (_recordingElapsed >= _recordingLimit) {
        _recordingTicker?.cancel();
        _promptContinueRecording();
      }
    });
  }

  /// Captures a frame every `1000 ~/ _recordingFps` ms and feeds it to the
  /// encoder — runs continuously from start to stop, independent of the
  /// 30-second check-in ticker above (declining/timing out the continue
  /// dialog stops this too, via [_stopRecording]; accepting just lets it run
  /// on).
  void _startFrameCaptureTimer() {
    _recordingCaptureTimer = Timer.periodic(
      Duration(milliseconds: 1000 ~/ _recordingFps),
      (_) async {
        if (_recordingFrameCaptureBusy || !_isRecording) return;
        _recordingFrameCaptureBusy = true;
        try {
          final rgba = await _captureRecordingFrame(
            _recordingWidth,
            _recordingHeight,
          );
          if (rgba != null && _isRecording) {
            await FlutterQuickVideoEncoder.appendVideoFrame(rgba);
          }
        } catch (_) {
          // Best-effort — a single dropped/failed frame isn't worth
          // interrupting the recording for.
        } finally {
          _recordingFrameCaptureBusy = false;
        }
      },
    );
  }

  /// Captures the current on-screen video frame (via [_captureFrame], same
  /// source [_takeSnapshot] uses) and normalizes it to exactly
  /// [width]x[height] raw RGBA bytes for [FlutterQuickVideoEncoder]
  /// .appendVideoFrame — capture sources vary in native resolution
  /// (WebRTC's real frame vs. a widget-boundary screenshot), but the encoder
  /// is configured for one fixed size for the whole clip.
  Future<Uint8List?> _captureRecordingFrame(int width, int height) async {
    final pngBytes = await _captureFrame();
    if (pngBytes == null) return null;
    final codec = await ui.instantiateImageCodec(pngBytes);
    final frame = await codec.getNextFrame();
    final source = frame.image;
    try {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawImageRect(
        source,
        Rect.fromLTWH(0, 0, source.width.toDouble(), source.height.toDouble()),
        Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
        Paint(),
      );
      final normalized = await recorder.endRecording().toImage(width, height);
      try {
        final byteData = await normalized.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        );
        return byteData?.buffer.asUint8List();
      } finally {
        normalized.dispose();
      }
    } finally {
      source.dispose();
    }
  }

  Future<void> _promptContinueRecording() async {
    final shouldContinue = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) =>
          _ContinueRecordingDialog(countdown: _continuePromptCountdown),
    );
    if (!mounted) return;
    if (shouldContinue ?? false) {
      // Start a fresh 30-second window; the recording itself (and its frame
      // capture timer) keeps running throughout.
      setState(() {
        _recordingStartedAt = DateTime.now();
        _recordingElapsed = Duration.zero;
      });
      _startRecordingTicker();
    } else {
      _stopRecording(save: true);
    }
  }

  Future<void> _stopRecording({required bool save}) async {
    _recordingTicker?.cancel();
    _recordingCaptureTimer?.cancel();
    final liveRecordingPath = _liveRecordingPath;
    setState(() {
      _isRecording = false;
      _recordingStartedAt = null;
      _recordingElapsed = Duration.zero;
      _liveRecordingPath = null;
    });

    if (liveRecordingPath == null) return;
    try {
      await FlutterQuickVideoEncoder.finish();
    } catch (_) {
      // Best-effort — still try to save whatever the muxer produced.
    }
    if (!save || !mounted) return;

    try {
      // Widget-boundary/on-screen capture, encoded to mp4 by
      // FlutterQuickVideoEncoder — save it to the device gallery.
      await Gal.putVideo(liveRecordingPath);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Recording saved')));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Could not save recording')));
    }
  }

  Future<void> _openFullscreen() async {
    await SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    if (!mounted) return;
    // rootNavigator: true — this screen lives inside a StatefulShellRoute
    // branch with its own nested Navigator; pushing on the branch Navigator
    // alone would keep MainShell's bottom nav bar visible underneath.
    await Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute(
        builder: (_) => _FullscreenVideo(
          liveViewController: _liveViewController,
          showLiveView: _tabController.index == 0,
          isMuted: _isMuted,
          onMuteChanged: (muted) => setState(() => _isMuted = muted),
          playbackClipController: _playbackClipController,
          playbackAvailability: _playbackAvailability,
          onTogglePlaybackPlayPause: _togglePlaybackPlayPause,
          onSkipPlaybackVideo: _skipPlaybackVideo,
        ),
      ),
    );
    await SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
    ]);
  }

  /// Toggles two-way talk (LIVE-011) in place, on the same screen — the
  /// live video keeps playing throughout; a status bar overlaid at the
  /// bottom of the video (TALK-001) shows connecting/talking/busy/error and
  /// carries the speakerphone/End controls, per `TWO_WAY_TALK_GUIDE.md` §6's
  /// call-style contract (distinct states, not just a spinner-or-not
  /// toggle; every exit path funnels through one teardown).
  ///
  /// **Runs on its own dedicated RTSPS connection now** (2026-09-15,
  /// replacing the old same-`RTCPeerConnection`-renegotiation mechanism —
  /// see `LiveViewController._negotiate`'s doc comment for why) —
  /// completely independent of whichever live-view transport is active, so
  /// talk now works on the RTSP-over-LAN fallback too, not just when the
  /// camera happens to report WebRTC for this profile. Still gated on
  /// [LiveViewTransport.lan] (talk has no WAN leg, `TWO_WAY_TALK_GUIDE.md`
  /// §1) and on a connected session as a proxy for "the phone is actually
  /// on this camera's LAN right now." Ending talk no longer affects live
  /// view at all — the two connections are unrelated.
  Future<void> _toggleTalk() async {
    final liveViewController = _liveViewController;
    if (liveViewController == null) return;

    if (liveViewController.talkStatus == TalkStatus.idle) {
      // Definitive `false` only — `null` (not yet loaded) or WAN (this
      // check is LAN-only) both mean "not confirmed unsupported," same
      // `!= false` convention `spotlightCapable`/`sirenCapable`/
      // `warningCapable` already use elsewhere on this screen.
      if (_audioCapability?.hasSpeaker == false) {
        _messengerKey.currentState?.showSnackBar(
          const SnackBar(
            content: Text('This camera doesn\'t support two-way talk'),
          ),
        );
        return;
      }
      if (liveViewController.status != LiveViewStatus.connected) {
        _messengerKey.currentState?.showSnackBar(
          const SnackBar(content: Text('Connect to the camera to talk')),
        );
        return;
      }
      if (liveViewController.transport == LiveViewTransport.wan) {
        _messengerKey.currentState?.showSnackBar(
          const SnackBar(
            content: Text('Talk isn\'t available on this connection'),
          ),
        );
        return;
      }
      await liveViewController.startTalk();
      return;
    }

    await liveViewController.endTalk();
  }

  /// Quick Spotlight shortcut (LIVE-018) — triggers/stops the camera's
  /// physical spotlight via `DeterrenceClient`/`WanDeterrenceClient`
  /// (`ActivateDeterrence`/`DeactivateDeterrence`, action `"spotlight"`),
  /// applied immediately (same instant-apply reasoning as
  /// [_togglePrivacyShortcut]). No duration is sent — the camera applies
  /// its own configured auto-stop duration (`FEAT-236`). The tile itself is
  /// hidden when `Camera.spotlightCapable == false` (build widget, below) —
  /// this method only runs when the camera is already known to support it,
  /// or capability is still unknown (not yet synced). Purely momentary
  /// hardware state, not a persisted
  /// camera setting — nothing written to `HomesController` on success.
  Future<void> _toggleSpotlight(Camera camera) async {
    final turningOn = !_isSpotlightOn;
    setState(() => _isSpotlightShortcutBusy = true);
    final succeeded = await _sendDeterrenceAction(
      camera,
      'spotlight',
      turningOn: turningOn,
    );
    if (!mounted) return;
    setState(() => _isSpotlightShortcutBusy = false);
    if (succeeded) {
      setState(() => _isSpotlightOn = turningOn);
    } else {
      _messengerKey.currentState?.showSnackBar(
        SnackBar(
          content: Text(
            'Failed to ${turningOn ? 'turn on' : 'turn off'} spotlight. '
            'Try again.',
          ),
        ),
      );
    }
  }

  /// Quick Siren shortcut (LIVE-045) — same instant-apply, momentary,
  /// non-persisted pattern as [_toggleSpotlight], just a different
  /// `DeterrenceClient`/`WanDeterrenceClient` action string ("siren").
  /// Hidden when `Camera.sirenCapable == false` (build widget, below).
  /// Turning it **on** asks for confirmation first (LIVE-050) — unlike the
  /// spotlight, a siren is loud/disruptive to the camera's surroundings, so
  /// an accidental tap deserves a second step; turning it back off doesn't.
  Future<void> _toggleSiren(Camera camera) async {
    final turningOn = !_isSirenOn;
    if (turningOn) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          key: const Key('LIVE-050'),
          title: const Text('Sound siren?'),
          content: const Text(
            'This will trigger a loud audible alarm on the camera.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Sound siren'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
    }
    setState(() => _isSirenShortcutBusy = true);
    final succeeded = await _sendDeterrenceAction(
      camera,
      'siren',
      turningOn: turningOn,
    );
    if (!mounted) return;
    setState(() => _isSirenShortcutBusy = false);
    if (succeeded) {
      setState(() => _isSirenOn = turningOn);
    } else {
      _messengerKey.currentState?.showSnackBar(
        SnackBar(
          content: Text(
            'Failed to ${turningOn ? 'turn on' : 'turn off'} siren. '
            'Try again.',
          ),
        ),
      );
    }
  }

  /// Quick Warning shortcut (LIVE-046) — same pattern as [_toggleSpotlight]/
  /// [_toggleSiren], action string "warning". Hidden when
  /// `Camera.warningCapable == false` (build widget, below).
  Future<void> _toggleWarning(Camera camera) async {
    final turningOn = !_isWarningOn;
    setState(() => _isWarningShortcutBusy = true);
    final succeeded = await _sendDeterrenceAction(
      camera,
      'warning',
      turningOn: turningOn,
    );
    if (!mounted) return;
    setState(() => _isWarningShortcutBusy = false);
    if (succeeded) {
      setState(() => _isWarningOn = turningOn);
    } else {
      _messengerKey.currentState?.showSnackBar(
        SnackBar(
          content: Text(
            'Failed to ${turningOn ? 'turn on' : 'turn off'} warning. '
            'Try again.',
          ),
        ),
      );
    }
  }

  /// Shared `DeterrenceClient`/`WanDeterrenceClient`
  /// `ActivateDeterrence`/`DeactivateDeterrence` call behind
  /// [_toggleSpotlight]/[_toggleSiren]/[_toggleWarning] — applied
  /// immediately, no duration sent (the camera applies its own configured
  /// auto-stop duration, `FEAT-236`), retried over WAN on a LAN failure per
  /// `mobile-app-screen-conventions.md`'s LAN/WAN convention. Purely
  /// momentary hardware state, not a persisted camera setting — nothing
  /// written to `HomesController` on success.
  Future<bool> _sendDeterrenceAction(
    Camera camera,
    String action, {
    required bool turningOn,
  }) async {
    final connection = camera.connection;
    if (connection == null) return simulateCameraSave();

    final nuraeye = NuraeyeClient(connection);
    final client = DeterrenceClient(nuraeye);
    var result = turningOn
        ? await client.activateDeterrence(action)
        : await client.deactivateDeterrence(action);
    nuraeye.close();
    final thingName = connection.thingName;
    if (result is! CameraSuccess && thingName != null) {
      final wanClient = WanDeterrenceClient(thingName);
      result = turningOn
          ? await wanClient.activateDeterrence(action)
          : await wanClient.deactivateDeterrence(action);
    }
    return result is CameraSuccess;
  }

  /// Quick Privacy Mode shortcut (LIVE-041) — toggles Off<->Full only, same
  /// as tapping the Off/Full tiles on `privacy_mode_screen.dart` (PRIV-002)
  /// but applied immediately, no draft/Apply step, matching Mute/Fullscreen's
  /// existing instant-apply pattern on this screen. If the camera is
  /// currently in Zone mode, this turns it Off rather than jumping to Full —
  /// zone configuration itself is left untouched for later, only reachable
  /// from the full Privacy Mode settings screen. Trusts the cached `Camera`
  /// model for the current mode shown (same as every other shortcut here)
  /// rather than re-fetching live on every screen open.
  Future<void> _togglePrivacyShortcut(Camera camera) async {
    final newMode = camera.privacyMode == CameraPrivacyMode.off
        ? CameraPrivacyMode.full
        : CameraPrivacyMode.off;
    setState(() => _isPrivacyShortcutBusy = true);

    final connection = camera.connection;
    final bool succeeded;
    if (connection != null) {
      final wireMode = newMode == CameraPrivacyMode.full
          ? PrivacyMode.full
          : PrivacyMode.none;
      final nuraeye = NuraeyeClient(connection);
      var result = await PrivacyModeClient(nuraeye).setPrivacyMode(wireMode);
      nuraeye.close();
      // A failed LAN Apply/Set retries over WAN before surfacing an error,
      // per mobile-app-screen-conventions.md's LAN/WAN convention.
      final thingName = connection.thingName;
      if (result is! CameraSuccess && thingName != null) {
        result = await WanPrivacyModeClient(thingName).setPrivacyMode(wireMode);
      }
      succeeded = result is CameraSuccess;
    } else {
      succeeded = await simulateCameraSave();
    }

    if (!mounted) return;
    setState(() => _isPrivacyShortcutBusy = false);
    if (succeeded) {
      widget.homesController.updateCamera(
        camera.id,
        (current) => current.copyWith(privacyMode: newMode),
      );
    } else {
      _messengerKey.currentState?.showSnackBar(
        const SnackBar(
          content: Text('Failed to update privacy mode. Try again.'),
        ),
      );
    }
  }

  /// Quick Video Mode shortcut (LIVE-042) — cycles Day -> Auto -> Night ->
  /// Day on each tap, applied immediately (same instant-apply reasoning as
  /// [_togglePrivacyShortcut]). Doesn't gate on the camera's reported
  /// `IrCutFilter` capability list the way `video_mode_screen.dart` does
  /// (VIDMODE-004) — this shortcut always offers all three; a camera that
  /// doesn't support one will surface that as a failed Set instead.
  Future<void> _cycleVideoModeShortcut(Camera camera) async {
    const order = [
      CameraVideoMode.day,
      CameraVideoMode.auto,
      CameraVideoMode.night,
    ];
    final next = order[(order.indexOf(camera.videoMode) + 1) % order.length];
    setState(() => _isVideoModeShortcutBusy = true);

    final connection = camera.connection;
    final bool succeeded;
    if (connection != null) {
      final client = OnvifImagingClient(
        connection,
        httpClient: CameraNetwork.clientFor(connection.host),
      );
      var result = await client.setImagingSettings(
        ImagingSettings(irCutFilterMode: _videoModeToIrCutFilter(next)),
      );
      client.close();
      // A failed LAN Apply/Set retries over WAN before surfacing an error,
      // per mobile-app-screen-conventions.md's LAN/WAN convention.
      final thingName = connection.thingName;
      if (result is! CameraSuccess && thingName != null) {
        result = await WanImagingClient(
          thingName,
        ).setDayNightMode(_videoModeToIrCutFilter(next));
      }
      succeeded = result is CameraSuccess;
    } else {
      succeeded = await simulateCameraSave();
    }

    if (!mounted) return;
    setState(() => _isVideoModeShortcutBusy = false);
    if (succeeded) {
      widget.homesController.updateCamera(
        camera.id,
        (current) => current.copyWith(videoMode: next),
      );
    } else {
      _messengerKey.currentState?.showSnackBar(
        const SnackBar(
          content: Text('Failed to update video mode. Try again.'),
        ),
      );
    }
  }

  /// The effective quality level [CameraStreamQuality.auto] currently
  /// resolves to, computed from the same live-measured bitrate
  /// [LiveViewController.measuredBitrateKbps] already backs LIVE-030's
  /// signal-strength badge — no camera call involved, this is purely a
  /// client-side read of a number this screen already has. Null (shown as
  /// just "Auto") until the first couple of WebRTC stats samples land.
  CameraStreamQuality? get _autoEffectiveQuality {
    final measured = _liveViewController?.measuredBitrateKbps;
    if (measured == null) return null;
    if (measured >= 2000) return CameraStreamQuality.high;
    if (measured >= 800) return CameraStreamQuality.medium;
    return CameraStreamQuality.low;
  }

  /// LIVE-058's chip label, transport-aware: on WAN, [Camera.streamQuality]
  /// is a LAN-only preference and doesn't reflect what's actually playing
  /// (WAN's own auto/manual choice lives on [LiveViewController.wanQuality]
  /// /[LiveViewController.wanAutoQuality] instead — session-only, see
  /// [_showWanStreamQualitySheet]) — read from there so the chip always
  /// names the stream actually on screen, not a stale LAN setting.
  String _currentStreamQualityChipLabel(Camera camera) {
    final controller = _liveViewController;
    if (controller != null && controller.transport == LiveViewTransport.wan) {
      return controller.wanAutoQuality
          ? 'Auto-${_wanStreamQualityAbbreviation(controller.wanQuality)}'
          : _wanStreamQualityName(controller.wanQuality);
    }
    if (camera.streamQuality == CameraStreamQuality.auto) {
      return _streamQualityLabel(camera.streamQuality);
    }
    // Manual LAN pick: show the camera's own real profile name (2026-09-15),
    // not a generic High/Medium/Low bucket label — see
    // [_showStreamQualitySheet]'s doc for why the old bucket scheme was
    // real gap. Falls back to a plain "Manual" only if the profile list
    // isn't cached yet (e.g. chip rendered before the sheet has ever been
    // opened this session).
    final token =
        camera.preferredLanProfileToken ?? controller?.currentProfileToken;
    final profile = _profileForToken(controller?.lanProfiles, token);
    return profile != null ? _profileTierLabel(profile.name) : 'Manual';
  }

  /// "Auto" alone, or "Auto-H"/"Auto-M"/"Auto-L" once a bitrate reading
  /// exists to resolve it against — only ever called for
  /// [CameraStreamQuality.auto] now (see [_currentStreamQualityChipLabel]'s
  /// manual branch for the real-profile-name path a non-auto pick takes
  /// instead).
  String _streamQualityLabel(CameraStreamQuality quality) {
    final effective = _autoEffectiveQuality;
    return effective == null
        ? 'Auto'
        : 'Auto-${_streamQualityAbbreviation(effective)}';
  }

  String _streamQualityAbbreviation(CameraStreamQuality quality) =>
      switch (quality) {
        CameraStreamQuality.auto => 'A',
        CameraStreamQuality.high => 'H',
        CameraStreamQuality.medium => 'M',
        CameraStreamQuality.low => 'L',
      };

  /// Sentinel `showModalBottomSheet` value for the Auto tile — distinct from
  /// any real ONVIF profile token (`Profile_1` etc.) and from the sheet's
  /// own `null` "dismissed without a choice" result.
  static const _kAutoStreamQualityValue = '__auto__';

  /// Capitalizes an ONVIF profile's own reported name (`MediaProfile.name`,
  /// e.g. `"high"`) for display — the camera's own label, not an app-side
  /// guess at which tier it is.
  String _profileTierLabel(String name) =>
      name.isEmpty ? name : '${name[0].toUpperCase()}${name.substring(1)}';

  MediaProfile? _profileForToken(List<MediaProfile>? profiles, String? token) {
    if (profiles == null || token == null) return null;
    for (final p in profiles) {
      if (p.token == token) return p;
    }
    return null;
  }

  /// LIVE-059 — the Stream Quality bottom sheet.
  ///
  /// **Updated 2026-09-15**: manual options are no longer a hardcoded
  /// High/Medium/Low trio — `MediaProfile`'s own doc comment
  /// (`onvif_video_encoder_client.dart`) is explicit that call sites must
  /// "never hardcode 3 streams... always read this list and its length,"
  /// which the old 3-bucket-by-sorted-index mapping violated outright: on a
  /// camera with only 2 profiles, "Medium" and "Low" silently resolved to
  /// the exact same token. This now renders one tile per profile the camera
  /// actually reports (`OnvifVideoEncoderClient.getProfiles()` via
  /// [LiveViewController.loadLanProfiles]), sorted by resolution descending,
  /// labeled with the camera's own profile name plus its real resolution —
  /// however many profiles that turns out to be. Auto still requests
  /// `kMobileOnlyStreamProfileToken` and also re-enables
  /// [LiveViewController.setAutoQualityLadder] (previously permanently
  /// disabled on this screen per STREAMING_GUIDE.md §2.1 — see that section
  /// for the confusing-background-change history); a manual pick disables
  /// it again and pins to exactly the requested profile via
  /// [LiveViewController.setPreferredProfile].
  Future<void> _showStreamQualitySheet(Camera camera) async {
    final controller = _liveViewController;
    // Real gap fixed 2026-09-15: profile discovery (`getProfiles()`) is a
    // LAN-only ONVIF call — opening this sheet without a *confirmed,
    // currently-connected* LAN session always failed with a generic
    // "Could not load this camera's streams" snackbar that read like a
    // bug, since there was no LAN path to discover profiles over at all.
    // A single `transport == wan` check alone isn't enough — a session
    // that's still `connecting`/`reconnecting`/`failed` (neither transport
    // confirmed yet) fell through that check and still tried and timed
    // out. Matches the two-step "must be connected, then must be LAN"
    // guard `_toggleTalk` already uses for its own WAN-unavailable case,
    // and the reference app's own state-driven gate (`live_view_screen
    // .dart`'s `LiveViewActive(transport: Transport.lan)` pattern) —
    // never attempt LAN-only discovery without the transport confirmed.
    if (controller == null || controller.status != LiveViewStatus.connected) {
      _messengerKey.currentState?.showSnackBar(
        const SnackBar(content: Text('Connect to the camera first')),
      );
      return;
    }
    if (controller.transport == LiveViewTransport.wan) {
      await _showWanStreamQualitySheet(controller);
      return;
    }
    // Real profiles must be known before the sheet can render real tiles —
    // unlike the old fixed-label sheet, there's nothing generic to show
    // while this resolves, so it's awaited up front now instead of warmed
    // in the background. Typically near-instant (single cached-after-first
    // ONVIF call on LAN).
    final profiles = await controller.loadLanProfiles();
    if (!mounted) return;
    if (profiles == null || profiles.isEmpty) {
      _messengerKey.currentState?.showSnackBar(
        const SnackBar(
          content: Text('Could not load this camera\'s streams. Try again.'),
        ),
      );
      return;
    }
    final sorted = [...profiles]
      ..sort(
        (a, b) => (b.resolution.width * b.resolution.height).compareTo(
          a.resolution.width * a.resolution.height,
        ),
      );
    final isAuto = camera.streamQuality == CameraStreamQuality.auto;
    final currentValue = isAuto
        ? _kAutoStreamQualityValue
        : (camera.preferredLanProfileToken ?? controller.currentProfileToken);

    final selected = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        return SafeArea(
          child: Column(
            key: const Key('LIVE-059'),
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Stream Quality',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              ),
              RadioGroup<String>(
                groupValue: currentValue,
                onChanged: (value) => Navigator.of(sheetContext).pop(value),
                child: Column(
                  children: [
                    RadioListTile<String>(
                      key: const Key('LIVE-060'),
                      value: _kAutoStreamQualityValue,
                      title: const Text('Auto'),
                      subtitle: const Text(
                        'Adjusts automatically based on your connection',
                      ),
                    ),
                    for (var i = 0; i < sorted.length; i++)
                      RadioListTile<String>(
                        key: Key('LIVE-06${8 + i}'),
                        value: sorted[i].token,
                        title: Text(_profileTierLabel(sorted[i].name)),
                        subtitle: Text(
                          '${sorted[i].resolution.width}×'
                          '${sorted[i].resolution.height}',
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
    if (selected == null || selected == currentValue) return;
    if (selected == _kAutoStreamQualityValue) {
      // preferredLanProfileToken deliberately untouched here — copyWith's
      // `?? this.field` pattern can't clear a nullable field to null
      // anyway, and it's harmless left stale: every read of it below is
      // already gated on `streamQuality != auto`.
      widget.homesController.updateCamera(
        camera.id,
        (current) => current.copyWith(streamQuality: CameraStreamQuality.auto),
      );
      controller.setAutoQualityLadder(true);
      await controller.setPreferredProfile(kMobileOnlyStreamProfileToken);
      return;
    }
    widget.homesController.updateCamera(
      camera.id,
      (current) => current.copyWith(
        streamQuality: CameraStreamQuality.high,
        preferredLanProfileToken: selected,
      ),
    );
    controller.setAutoQualityLadder(false);
    await controller.setPreferredProfile(selected);
  }

  /// WAN counterpart to [_showStreamQualitySheet]'s LAN branch (`FR-CF-154`).
  /// Manual High/Medium/Low tiers are session-only, not persisted to
  /// [Camera.streamQuality] (that field is a LAN profile preference) —
  /// mirrors the reference app's own `wanQuality`, which resets to medium
  /// every fresh connection rather than remembering a per-camera WAN choice.
  ///
  /// **Updated 2026-09-15**: Auto is back (LIVE-067) — WAN has no
  /// bitrate-derived adaptive concept the way LAN does (no `GetProfiles`
  /// -style discovery, no `inbound-rtp` stats over HLS, STREAMING_GUIDE.md
  /// §8), so [LiveViewController.setWanAutoQuality] instead steps
  /// [LiveViewController.wanQuality] on sustained stall/rebuffer detection
  /// (see [LiveViewController._pollWanStall]) — each step still means a
  /// real `StopCloudStreaming`/`StartCloudStreaming` round trip on a
  /// separately-billed KVS stream, same as a manual switch.
  Future<void> _showWanStreamQualitySheet(LiveViewController controller) async {
    final currentSelection = controller.wanAutoQuality
        ? CameraStreamQuality.auto
        : _fromWanQuality(controller.wanQuality);
    final selected = await showModalBottomSheet<CameraStreamQuality>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        return SafeArea(
          child: Column(
            key: const Key('LIVE-059'),
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Stream Quality',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              ),
              RadioGroup<CameraStreamQuality>(
                groupValue: currentSelection,
                onChanged: (value) => Navigator.of(sheetContext).pop(value),
                child: Column(
                  children: [
                    for (final quality in CameraStreamQuality.values)
                      RadioListTile<CameraStreamQuality>(
                        key: Key(
                          quality == CameraStreamQuality.auto
                              ? 'LIVE-067'
                              : 'LIVE-06${3 + quality.index}',
                        ),
                        value: quality,
                        title: Text(
                          quality == CameraStreamQuality.auto
                              ? 'Auto'
                              : _wanStreamQualityName(_toWanQuality(quality)),
                        ),
                        subtitle: Text(switch (quality) {
                          CameraStreamQuality.auto =>
                            'Adjusts automatically based on your connection',
                          CameraStreamQuality.high =>
                            'Best quality, uses the most data',
                          CameraStreamQuality.medium =>
                            'Balanced quality and data usage',
                          CameraStreamQuality.low =>
                            'Lowest data usage, reduced quality',
                        }),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
    if (selected == null || selected == currentSelection) return;
    if (selected == CameraStreamQuality.auto) {
      controller.setWanAutoQuality(true);
      return;
    }
    controller.setWanAutoQuality(false);
    await controller.setWanQuality(_toWanQuality(selected));
  }

  String _wanStreamQualityName(StreamQuality quality) => switch (quality) {
    StreamQuality.high => 'High',
    StreamQuality.medium => 'Medium',
    StreamQuality.low => 'Low',
  };

  String _wanStreamQualityAbbreviation(StreamQuality quality) =>
      switch (quality) {
        StreamQuality.high => 'H',
        StreamQuality.medium => 'M',
        StreamQuality.low => 'L',
      };

  StreamQuality _toWanQuality(CameraStreamQuality quality) => switch (quality) {
    CameraStreamQuality.high => StreamQuality.high,
    CameraStreamQuality.medium => StreamQuality.medium,
    CameraStreamQuality.low => StreamQuality.low,
    CameraStreamQuality.auto => StreamQuality.medium,
  };

  CameraStreamQuality _fromWanQuality(StreamQuality quality) =>
      switch (quality) {
        StreamQuality.high => CameraStreamQuality.high,
        StreamQuality.medium => CameraStreamQuality.medium,
        StreamQuality.low => CameraStreamQuality.low,
      };

  /// The up-to-date [Camera], reflecting settings changes made elsewhere
  /// (e.g. On-Screen Display's OSD toggles). Falls back to the navigation
  /// snapshot if the camera can't be found (e.g. it was deleted).
  Camera _currentCamera(HomesState state) {
    for (final home in state.homes) {
      for (final camera in home.cameras) {
        if (camera.id == widget.camera.id) return camera;
      }
    }
    return widget.camera;
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<HomesState>(
      valueListenable: widget.homesController,
      builder: (context, homesState, _) {
        final camera = _currentCamera(homesState);
        return _buildScaffold(context, camera);
      },
    );
  }

  /// Live tag, audio-recording indicator, Bitrate, and Signal Strength
  /// badges, positioned via [osdPositioned] with stack indices computed
  /// across all four so any that share a corner (Live tag and the
  /// audio-recording indicator are fixed top-left; Bitrate/Signal Strength
  /// are user-positioned from the Tags screen) stack instead of overlapping.
  List<Widget> _buildOsdTags(Camera camera) {
    final entries = [
      if (camera.liveTagOsdEnabled) OsdCorner.topLeft,
      if (camera.audioRecordingEnabled) OsdCorner.topLeft,
      if (camera.bitrateOsdEnabled) camera.bitrateOsdPosition,
      if (camera.signalStrengthOsdEnabled) camera.signalStrengthOsdPosition,
    ];
    final stackIndices = osdStackIndices(entries);
    var i = 0;

    return [
      if (camera.liveTagOsdEnabled)
        osdPositioned(
          OsdCorner.topLeft,
          stackIndex: stackIndices[i++],
          child: LiveStatusBadge(
            key: const Key('LIVE-004'),
            status: camera.liveStatus,
          ),
        ),
      if (camera.audioRecordingEnabled)
        osdPositioned(
          OsdCorner.topLeft,
          stackIndex: stackIndices[i++],
          child: const AudioRecordingBadge(key: Key('LIVE-037')),
        ),
      if (camera.bitrateOsdEnabled)
        osdPositioned(
          camera.bitrateOsdPosition,
          stackIndex: stackIndices[i++],
          child: BitrateBadge(
            key: const Key('LIVE-029'),
            configuredKbps: camera.bitrateKbps,
          ),
        ),
      if (camera.signalStrengthOsdEnabled)
        osdPositioned(
          camera.signalStrengthOsdPosition,
          stackIndex: stackIndices[i++],
          child: SignalStrengthBadge(
            key: const Key('LIVE-030'),
            signalStrength: camera.signalStrength,
            // Prefers the live-measured stream bitrate (real
            // RTCPeerConnection.getStats() reading) over the persisted
            // Camera.networkSpeedKbps, which only reflects whatever was
            // last measured — avoids re-persisting a value that changes
            // every couple of seconds into shared HomesController state.
            networkSpeedKbps:
                _liveViewController?.measuredBitrateKbps ??
                camera.networkSpeedKbps,
          ),
        ),
    ];
  }

  Future<bool> _confirmLeaveWhileRecording() async {
    if (!_isRecording) return true;
    final shouldLeave = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const Key('LIVE-031'),
        title: const Text('Recording in progress'),
        content: const Text('Stop and save the recording before leaving?'),
        actions: [
          TextButton(
            key: const Key('LIVE-032'),
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('LIVE-033'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Stop & Leave'),
          ),
        ],
      ),
    );
    if (shouldLeave == true) {
      await _stopRecording(save: true);
      return true;
    }
    return false;
  }

  Widget _buildScaffold(BuildContext context, Camera camera) {
    return ScaffoldMessenger(
      key: _messengerKey,
      child: LeaveGuard(
        canLeave: _confirmLeaveWhileRecording,
        child: GradientBackground(
          child: Scaffold(
            backgroundColor: Colors.transparent,
            appBar: AppBar(
              title: Text(key: const Key('LIVE-001'), camera.name),
              leading: IconButton(
                key: const Key('LIVE-002'),
                icon: const Icon(Icons.arrow_back),
                onPressed: () => context.pop(),
              ),
              actions: [
                if (_connectivity.any(
                  (result) => result != ConnectivityResult.none,
                ))
                  Padding(
                    key: const Key('LIVE-038'),
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          _connectivity.contains(ConnectivityResult.wifi)
                              ? Icons.wifi
                              : Icons.signal_cellular_alt,
                          size: 18,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          // Real measured throughput (same
                          // RTCPeerConnection.getStats() reading LIVE-030
                          // uses) appended when available — the actual rate
                          // data is currently arriving at, on whichever
                          // network the phone is on, not just which network
                          // type it is. No measurement exists yet on WAN or
                          // before the first two stats samples land.
                          _liveViewController?.measuredBitrateKbps != null
                              ? '${_connectivity.contains(ConnectivityResult.wifi) ? 'Wi-Fi' : 'Mobile data'} · ${formatBitrate(_liveViewController!.measuredBitrateKbps!)}'
                              : _connectivity.contains(ConnectivityResult.wifi)
                              ? 'Wi-Fi'
                              : 'Mobile data',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: ActionChip(
                    key: const Key('LIVE-058'),
                    avatar: const Icon(Icons.hd_outlined, size: 18),
                    label: Text(_currentStreamQualityChipLabel(camera)),
                    onPressed: () => _showStreamQualitySheet(camera),
                  ),
                ),
                IconButton(
                  key: const Key('LIVE-017'),
                  tooltip: 'Camera settings',
                  icon: const Icon(Icons.settings_outlined),
                  onPressed: () => context.push(
                    '${GoRouterState.of(context).matchedLocation}/${CameraSettingsScreen.routeName}',
                    extra: camera,
                  ),
                ),
              ],
            ),
            body: Column(
              children: [
                AspectRatio(
                  aspectRatio: 16 / 9,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      // Playback tab is recorded footage, not a live feed —
                      // it stays usable regardless of the camera's *current*
                      // connectivity, the same reasoning the day
                      // picker/timeline/event-nav controls below already
                      // follow (none of them are gated on camera.isOnline
                      // either). Only the Live tab actually needs the camera
                      // reachable right now, so the offline
                      // thumbnail/overlay only applies there.
                      if (camera.isOnline || _tabController.index == 1)
                        Hero(
                          tag: 'camera_hero_${camera.id}',
                          child: RepaintBoundary(
                            key: _videoBoundaryKey,
                            child: _HeroVideo(
                              liveViewController: _liveViewController,
                              showLiveView: _tabController.index == 0,
                              playbackClipController: _playbackClipController,
                              playbackAvailability: _playbackAvailability,
                            ),
                          ),
                        )
                      else
                        Positioned.fill(
                          child: Hero(
                            tag: 'camera_hero_${camera.id}',
                            child: _OfflineThumbnail(camera: camera),
                          ),
                        ),
                      if (!camera.isOnline && _tabController.index == 0)
                        Positioned.fill(
                          child: _OfflineOverlay(
                            key: const Key('LIVE-028'),
                            camera: camera,
                          ),
                        ),
                      ..._buildOsdTags(camera),
                      // Playback tab only — tap the video to reveal
                      // play/pause + skip controls, auto-hiding after 4s of
                      // no interaction, standard video-player UX. Not gated
                      // on camera.isOnline: Playback is recorded footage, so
                      // it stays usable while the camera is offline, same as
                      // the video display itself just above. Inserted before
                      // the Mute/Fullscreen corner buttons so they stay on
                      // top and remain independently tappable whether or not
                      // this overlay is currently visible.
                      if (_tabController.index == 1)
                        Positioned.fill(
                          child: GestureDetector(
                            behavior: HitTestBehavior.translucent,
                            onTap: _togglePlaybackControlsVisibility,
                            child: AnimatedOpacity(
                              opacity: _showPlaybackControls ? 1 : 0,
                              duration: const Duration(milliseconds: 200),
                              child: IgnorePointer(
                                ignoring: !_showPlaybackControls,
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    color: Colors.black.withValues(alpha: 0.25),
                                  ),
                                  child: Center(
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        _VideoOverlayButton(
                                          key: const Key('LIVE-047'),
                                          tooltip: 'Back 10 seconds',
                                          // Real 10-*second* skip since
                                          // 2026-09-07 (direct user request —
                                          // the previous 10-*minute* jump was
                                          // too coarse for scrubbing near an
                                          // event). `Icons.replay_10` is
                                          // Material's standard "skip 10
                                          // seconds" glyph, matching the
                                          // actual behavior now.
                                          icon: Icons.replay_10,
                                          onPressed: () =>
                                              _skipPlaybackVideo(-10),
                                        ),
                                        const SizedBox(width: 28),
                                        _PlaybackPlayPauseButton(
                                          key: const Key('LIVE-048'),
                                          controller: _playbackClipController,
                                          onPressed: _togglePlaybackPlayPause,
                                        ),
                                        const SizedBox(width: 28),
                                        _VideoOverlayButton(
                                          key: const Key('LIVE-049'),
                                          tooltip: 'Forward 10 seconds',
                                          // See LIVE-047's own comment — same
                                          // change, same reasoning.
                                          icon: Icons.forward_10,
                                          onPressed: () =>
                                              _skipPlaybackVideo(10),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      Positioned(
                        left: 8,
                        bottom: _cornerButtonBottomInset,
                        child: _VideoOverlayButton(
                          key: const Key('LIVE-007'),
                          tooltip: _isMuted ? 'Unmute' : 'Mute',
                          icon: _isMuted ? Icons.volume_off : Icons.volume_up,
                          // Playback's own video keeps playing (with its own
                          // audio track) regardless of the camera's current
                          // connectivity — same reasoning as the video
                          // display itself, above.
                          onPressed:
                              (camera.isOnline || _tabController.index == 1)
                              ? _toggleMute
                              : null,
                        ),
                      ),
                      Positioned(
                        right: 8,
                        bottom: _cornerButtonBottomInset,
                        child: _VideoOverlayButton(
                          key: const Key('LIVE-008'),
                          tooltip: 'Fullscreen',
                          icon: Icons.fullscreen,
                          onPressed:
                              (camera.isOnline || _tabController.index == 1)
                              ? _openFullscreen
                              : null,
                        ),
                      ),
                      // Two-way talk (LIVE-011) stays on this same screen —
                      // the video keeps playing behind this status bar rather
                      // than being replaced by a separate full-screen call
                      // page, so you can still see who/what you're talking to.
                      if (_liveViewController != null &&
                          _liveViewController!.talkStatus != TalkStatus.idle)
                        Positioned(
                          left: 0,
                          right: 0,
                          bottom: 0,
                          child: _TalkStatusBar(
                            key: const Key('TALK-001'),
                            controller: _liveViewController!,
                            onEnd: _toggleTalk,
                          ),
                        ),
                    ],
                  ),
                ),
                TabBar(
                  key: const Key('LIVE-005'),
                  controller: _tabController,
                  tabs: const [
                    Tab(text: 'Live'),
                    Tab(text: 'Playback'),
                  ],
                ),
                Expanded(
                  child: TabBarView(
                    controller: _tabController,
                    physics: const NeverScrollableScrollPhysics(),
                    children: [
                      _LiveControls(
                        isEnabled: camera.isOnline,
                        isRecording: _isRecording,
                        recordingElapsed: _recordingElapsed,
                        isTalking:
                            (_liveViewController?.talkStatus ??
                                TalkStatus.idle) !=
                            TalkStatus.idle,
                        talkCapable: _audioCapability?.hasSpeaker,
                        isSpotlightOn: _isSpotlightOn,
                        isSpotlightShortcutBusy: _isSpotlightShortcutBusy,
                        spotlightCapable: camera.spotlightCapable,
                        isSirenOn: _isSirenOn,
                        isSirenShortcutBusy: _isSirenShortcutBusy,
                        sirenCapable: camera.sirenCapable,
                        isWarningOn: _isWarningOn,
                        isWarningShortcutBusy: _isWarningShortcutBusy,
                        warningCapable: camera.warningCapable,
                        privacyMode: camera.privacyMode,
                        isPrivacyShortcutBusy: _isPrivacyShortcutBusy,
                        videoMode: camera.videoMode,
                        isVideoModeShortcutBusy: _isVideoModeShortcutBusy,
                        onSnapshot: _takeSnapshot,
                        onRecord: _toggleRecording,
                        onTalk: _toggleTalk,
                        onSpotlight: () => _toggleSpotlight(camera),
                        onSiren: () => _toggleSiren(camera),
                        onWarning: () => _toggleWarning(camera),
                        onPrivacy: () => _togglePrivacyShortcut(camera),
                        onVideoMode: () => _cycleVideoModeShortcut(camera),
                        onAiMode: () => _openAiMode(camera),
                      ),
                      _PlaybackTab(
                        key: _playbackTabKey,
                        connection: camera.connection,
                        thingName: camera.connection?.thingName,
                        isWan: switch (_liveViewController?.transport) {
                          LiveViewTransport.wan => true,
                          null => null,
                          _ => false,
                        },
                        isActive: _tabController.index == 1,
                        onSnapshot: _takeSnapshot,
                        onClipStateChanged: _onPlaybackClipStateChanged,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Small circular icon button overlaid directly on the video surface
/// (bottom-left mute, bottom-right fullscreen).
class _VideoOverlayButton extends StatelessWidget {
  const _VideoOverlayButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final isEnabled = onPressed != null;
    return Opacity(
      opacity: isEnabled ? 1 : 0.4,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.55),
          shape: BoxShape.circle,
        ),
        child: IconButton(
          tooltip: tooltip,
          icon: Icon(icon, color: Colors.white, size: 20),
          onPressed: onPressed,
        ),
      ),
    );
  }
}

/// LIVE-048/LIVE-053's icon+tooltip, reactive via
/// `ValueListenableBuilder<VideoPlayerValue>` on the clip controller itself
/// rather than reading `.value.isPlaying` once at build time — the previous
/// version only looked correct because a once-a-second position timer
/// happened to force a rebuild on every tick; playback pausing/ending on its
/// own between ticks (e.g. reaching the end of a clip) could leave the icon
/// stale for up to a second. `null` controller (no clip open yet) shows a
/// disabled Play icon, matching the old behavior.
class _PlaybackPlayPauseButton extends StatelessWidget {
  const _PlaybackPlayPauseButton({
    super.key,
    required this.controller,
    required this.onPressed,
  });

  final VideoPlayerController? controller;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final controller = this.controller;
    if (controller == null) {
      return const _VideoOverlayButton(
        tooltip: 'Play',
        icon: Icons.play_arrow,
        onPressed: null,
      );
    }
    return ValueListenableBuilder<VideoPlayerValue>(
      valueListenable: controller,
      builder: (context, value, _) => _VideoOverlayButton(
        tooltip: value.isPlaying ? 'Pause' : 'Play',
        icon: value.isPlaying ? Icons.pause : Icons.play_arrow,
        onPressed: onPressed,
      ),
    );
  }
}

/// Last-known snapshot shown in place of the live video feed while the
/// camera is offline — same `camera.thumbnailUrl` used on the Dashboard
/// tiles, so the offline state still shows something recognizable instead
/// of a blank/frozen player.
class _OfflineThumbnail extends StatelessWidget {
  const _OfflineThumbnail({required this.camera});

  final Camera camera;

  @override
  Widget build(BuildContext context) {
    final thumbnailUrl = camera.thumbnailUrl;
    if (thumbnailUrl == null) {
      return const ColoredBox(color: Colors.black);
    }
    return CameraThumbnailImage(
      thumbnailUrl: thumbnailUrl,
      fit: BoxFit.cover,
      placeholderBuilder: () => const ColoredBox(color: Colors.black),
    );
  }
}

/// Dark overlay shown over the video when the camera is offline: icon,
/// "Camera Offline", and "Last seen …" if known — same visual language as
/// the offline overlay on the Dashboard's camera tiles.
class _OfflineOverlay extends StatelessWidget {
  const _OfflineOverlay({super.key, required this.camera});

  final Camera camera;

  String _relativeTime(DateTime time) {
    final diff = DateTime.now().difference(time);
    if (diff.inSeconds < 60) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.55)),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.videocam_off_rounded,
              color: Colors.white,
              size: 32,
            ),
            const SizedBox(height: 8),
            const Text(
              'Camera Offline',
              style: TextStyle(
                fontFamily: 'Manrope',
                fontWeight: FontWeight.w700,
                fontSize: 15,
                color: Colors.white,
              ),
            ),
            if (camera.lastSeen != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  'Last seen ${_relativeTime(camera.lastSeen!)}',
                  style: const TextStyle(
                    fontFamily: 'Manrope',
                    fontWeight: FontWeight.w500,
                    fontSize: 12,
                    color: Colors.white70,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Video surface with pinch-to-zoom (via [InteractiveViewer]) so the feed
/// can be zoomed digitally in both the Live and Playback tabs, and in
/// fullscreen.
class _VideoSurface extends StatelessWidget {
  const _VideoSurface({required this.controller, this.fit = BoxFit.cover});

  final VideoPlayerController controller;

  /// `BoxFit.cover` (default) fills the available box edge-to-edge, cropping
  /// any part of the frame that doesn't match the box's aspect ratio — fine
  /// inline where the box is already pinned to the camera's own 16:9 ratio
  /// (see the `AspectRatio` wrapper in `CameraLiveScreen.build`). Fullscreen
  /// has no such matching box (it fills the phone's own screen ratio), so
  /// `_FullscreenVideo` passes `BoxFit.contain` there instead to letterbox
  /// rather than crop.
  final BoxFit fit;

  @override
  Widget build(BuildContext context) {
    if (!controller.value.isInitialized) {
      return const ColoredBox(
        color: Colors.black,
        child: Center(child: CircularProgressIndicator(color: Colors.white)),
      );
    }
    return ColoredBox(
      color: Colors.black,
      child: _ZoomableVideo(
        child: FittedBox(
          fit: fit,
          child: SizedBox(
            width: controller.value.size.width,
            height: controller.value.size.height,
            child: VideoPlayer(controller),
          ),
        ),
      ),
    );
  }
}

/// Wraps [child] in pinch-to-zoom (via [InteractiveViewer], same `maxScale`
/// every pre-existing call site used) and overlays a transient "1.0x"/"2.3x"
/// zoom-level badge (LIVE-044) while the user is actively pinching, fading
/// out shortly after the gesture ends rather than staying pinned on screen
/// indefinitely — see docs/screens/camera_live/camera_live_screen.md.
class _ZoomableVideo extends StatefulWidget {
  const _ZoomableVideo({required this.child});

  final Widget child;

  @override
  State<_ZoomableVideo> createState() => _ZoomableVideoState();
}

class _ZoomableVideoState extends State<_ZoomableVideo> {
  final _transformationController = TransformationController();
  double _scale = 1;
  bool _showBadge = false;
  Timer? _hideTimer;

  @override
  void dispose() {
    _hideTimer?.cancel();
    _transformationController.dispose();
    super.dispose();
  }

  void _onInteractionUpdate(ScaleUpdateDetails details) {
    setState(() {
      _scale = _transformationController.value.getMaxScaleOnAxis();
      _showBadge = true;
    });
  }

  void _onInteractionEnd(ScaleEndDetails details) {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 1), () {
      if (mounted) setState(() => _showBadge = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        InteractiveViewer(
          transformationController: _transformationController,
          maxScale: 4,
          onInteractionUpdate: _onInteractionUpdate,
          onInteractionEnd: _onInteractionEnd,
          child: widget.child,
        ),
        Positioned(
          top: 8,
          right: 8,
          child: IgnorePointer(
            child: AnimatedOpacity(
              opacity: _showBadge ? 1 : 0,
              duration: const Duration(milliseconds: 200),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.55),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  child: Text(
                    'Digital Zoom: ${_scale.toStringAsFixed(1)}x',
                    key: const Key('LIVE-044'),
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                      fontSize: 12,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Small "Remote" chip shown over the video whenever the current session is
/// playing over WAN (KVS/HLS) rather than the LAN WebRTC path — the two have
/// materially different latency (STREAMING_GUIDE.md §1: sub-second on LAN
/// vs. several seconds on WAN), so it's worth surfacing which one is active
/// rather than leaving that invisible.
class _RemoteStreamBadge extends StatelessWidget {
  const _RemoteStreamBadge();

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(6),
      ),
      child: const Padding(
        padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_outlined, color: Colors.white, size: 14),
            SizedBox(width: 4),
            Text(
              'Remote',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w700,
                fontSize: 11,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// What the Playback tab's video area shows while no real clip is open —
/// see [_PlaybackUnavailable].
enum _PlaybackAvailability {
  /// Still checking this day for recordings (or a clip is still
  /// downloading) — a spinner, not an error.
  loading,

  /// Camera has no saved LAN connection — no network call was attempted.
  /// Shown with a specific "add camera IP in Settings" message.
  noConnection,

  /// Connection exists but this day has nothing recorded, or the
  /// GetRecordings call failed. Never silently substitutes fake footage.
  noRecording,

  /// A real clip is open — `_HeroVideo` actually keys off its
  /// `playbackClipController` being non-null for this case, not this enum
  /// value; kept only so `_PlaybackTabState`'s state-reporting callback has
  /// a value to pass instead of an unused placeholder.
  ready,
}

/// Playback tab's video-area placeholder while [_PlaybackAvailability] isn't
/// `ready`-equivalent (i.e. [_HeroVideo.playbackClipController] is null) —
/// a spinner while checking, a no-connection message when no camera IP is
/// saved, or an honest "No recording available" once confirmed.
class _PlaybackUnavailable extends StatelessWidget {
  const _PlaybackUnavailable({required this.availability});

  final _PlaybackAvailability availability;

  @override
  Widget build(BuildContext context) {
    if (availability == _PlaybackAvailability.loading) {
      return const ColoredBox(
        color: Colors.black,
        child: Center(child: CircularProgressIndicator(color: Colors.white)),
      );
    }

    final (
      IconData icon,
      String message,
      String? subtitle,
    ) = switch (availability) {
      _PlaybackAvailability.noConnection => (
        Icons.wifi_off_rounded,
        'Camera not connected',
        'Add this camera\'s IP address in Settings to view recordings.',
      ),
      _PlaybackAvailability.noRecording => (
        Icons.videocam_off_outlined,
        'No recording available',
        'Switch to a day that has footage, or check that the camera\'s\n'
            'local storage card is inserted and recording is enabled.',
      ),
      _ => (Icons.videocam_off_outlined, 'No recording available', null),
    };

    return ColoredBox(
      color: Colors.black,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: Colors.white54, size: 40),
              const SizedBox(height: 12),
              Text(
                key: const Key('LIVE-051'),
                message,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                ),
                textAlign: TextAlign.center,
              ),
              if (subtitle != null) ...[
                const SizedBox(height: 6),
                Text(
                  subtitle,
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: Colors.white54),
                  textAlign: TextAlign.center,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Live tab's video-area placeholder when the camera has no saved LAN
/// connection at all ([_HeroVideo.liveViewController] is null) — same visual
/// language and copy as [_PlaybackUnavailable]'s `noConnection` case, since
/// it's the same underlying condition. In practice this Camera would also
/// have `isOnline == false` (every onboarding path sets a connection and
/// `isOnline` together), so [_OfflineThumbnail]/[_OfflineOverlay] normally
/// cover this first — this is the fallback for the rare case where a camera
/// somehow has no connection but is still marked online.
class _LiveUnavailable extends StatelessWidget {
  const _LiveUnavailable();

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Colors.black,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.wifi_off_rounded,
                color: Colors.white54,
                size: 40,
              ),
              const SizedBox(height: 12),
              Text(
                key: const Key('LIVE-055'),
                'Camera not connected',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 6),
              Text(
                'Add this camera\'s IP address in Settings to view the live feed.',
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: Colors.white54),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Picks between the real LAN WebRTC live feed ([liveViewController], shown
/// when [showLiveView] is true and a controller exists) and, for the
/// Playback tab (`!showLiveView`), the real downloaded-clip controller
/// ([playbackClipController]) or a "no recording" state
/// ([playbackAvailability]) — never any fake footage. A Live tab with no
/// [liveViewController] at all (camera has no saved connection yet) shows
/// [_LiveUnavailable] instead, the same "never substitute fake footage"
/// policy Playback already followed — the Live tab used to fall back to a
/// bundled dummy sample video here; removed entirely 2026-09-07 per direct
/// user request ("remove the dummy video in the app completely"). Reused by
/// both the inline hero video area and [_FullscreenVideo] so fullscreen
/// shows whatever was already on screen.
class _HeroVideo extends StatelessWidget {
  const _HeroVideo({
    required this.liveViewController,
    required this.showLiveView,
    this.playbackClipController,
    this.playbackAvailability = _PlaybackAvailability.loading,
    this.fit = BoxFit.cover,
  });

  final LiveViewController? liveViewController;
  final bool showLiveView;

  /// Playback tab only — the real downloaded clip currently open, if any.
  final VideoPlayerController? playbackClipController;

  /// Playback tab only — what to show while [playbackClipController] is
  /// null (still checking, or confirmed nothing recorded).
  final _PlaybackAvailability playbackAvailability;

  /// See [_VideoSurface.fit]'s doc — threaded through to whichever surface
  /// (WAN `_VideoSurface` or LAN `RTCVideoView`) ends up rendering.
  final BoxFit fit;

  @override
  Widget build(BuildContext context) {
    if (!showLiveView) {
      final clipController = playbackClipController;
      if (clipController != null) {
        return _VideoSurface(controller: clipController, fit: fit);
      }
      return _PlaybackUnavailable(availability: playbackAvailability);
    }
    final controller = liveViewController;
    if (controller == null) {
      return const _LiveUnavailable();
    }
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        switch (controller.status) {
          case LiveViewStatus.connecting:
          case LiveViewStatus.reconnecting:
            return ColoredBox(
              color: Colors.black,
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const CircularProgressIndicator(color: Colors.white),
                    const SizedBox(height: 12),
                    Text(
                      controller.status == LiveViewStatus.reconnecting
                          ? 'Reconnecting…'
                          : 'Connecting…',
                      style: const TextStyle(color: Colors.white),
                    ),
                  ],
                ),
              ),
            );
          case LiveViewStatus.connected:
            final wanController = controller.wanVideoController;
            if (controller.transport == LiveViewTransport.wan &&
                wanController != null) {
              return Stack(
                fit: StackFit.expand,
                children: [
                  _VideoSurface(controller: wanController, fit: fit),
                  const Positioned(
                    top: 8,
                    left: 8,
                    child: _RemoteStreamBadge(),
                  ),
                ],
              );
            }
            // LAN, but the camera resolved the RTSP fallback for this
            // profile (STREAMING_GUIDE.md §2.5 — its firmware build has
            // WEBRTC_STREAMING disabled, the documented current default)
            // rather than WebRTC. Still a plain `video_player` surface,
            // same as WAN just above, fed by the local RTSP→fMP4 loopback
            // proxy instead of a remote HLS URL — no "Remote" badge, this
            // is still a same-network session.
            final rtspController = controller.lanRtspVideoController;
            if (rtspController != null) {
              return _ZoomableVideo(
                child: _VideoSurface(controller: rtspController, fit: fit),
              );
            }
            // Pinch-to-zoom via _ZoomableVideo, same as _VideoSurface below
            // — this is the LAN WebRTC path (the common case), which
            // previously returned the bare renderer with no zoom wrapper at
            // all, unlike the WAN/Playback paths.
            return _ZoomableVideo(
              child: RTCVideoView(
                controller.renderer,
                objectFit: fit == BoxFit.contain
                    ? RTCVideoViewObjectFit.RTCVideoViewObjectFitContain
                    : RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
              ),
            );
          case LiveViewStatus.failed:
            return ColoredBox(
              color: Colors.black,
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.wifi_off, color: Colors.white70, size: 32),
                    const SizedBox(height: 8),
                    const Text(
                      'Camera Offline',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      'Retrying automatically…',
                      style: TextStyle(color: Colors.white70, fontSize: 12),
                    ),
                    const SizedBox(height: 12),
                    TextButton(
                      onPressed: controller.connect,
                      child: const Text('Retry now'),
                    ),
                  ],
                ),
              ),
            );
          case LiveViewStatus.stopped:
            return ColoredBox(
              color: Colors.black,
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.wifi_off, color: Colors.white70, size: 32),
                    const SizedBox(height: 8),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: Text(
                        controller.errorMessage ?? "Couldn't connect to camera",
                        style: const TextStyle(color: Colors.white70),
                        textAlign: TextAlign.center,
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextButton(
                      onPressed: controller.connect,
                      child: const Text('Retry'),
                    ),
                  ],
                ),
              ),
            );
        }
      },
    );
  }
}

class _LiveControls extends StatelessWidget {
  const _LiveControls({
    required this.isEnabled,
    required this.isRecording,
    required this.recordingElapsed,
    required this.isTalking,
    required this.talkCapable,
    required this.isSpotlightOn,
    required this.isSpotlightShortcutBusy,
    required this.spotlightCapable,
    required this.isSirenOn,
    required this.isSirenShortcutBusy,
    required this.sirenCapable,
    required this.isWarningOn,
    required this.isWarningShortcutBusy,
    required this.warningCapable,
    required this.privacyMode,
    required this.isPrivacyShortcutBusy,
    required this.videoMode,
    required this.isVideoModeShortcutBusy,
    required this.onSnapshot,
    required this.onRecord,
    required this.onTalk,
    required this.onSpotlight,
    required this.onSiren,
    required this.onWarning,
    required this.onPrivacy,
    required this.onVideoMode,
    required this.onAiMode,
  });

  final bool isEnabled;
  final bool isRecording;
  final Duration recordingElapsed;
  final bool isTalking;

  /// Whether this camera reports speaker hardware (`AudioCapabilityClient
  /// .getAudioCapability().hasSpeaker`) — real gap fixed 2026-09-15: the
  /// tile itself used to show unconditionally regardless of hardware
  /// presence (only the tap handler, `_toggleTalk`, checked this), unlike
  /// every other hardware-gated tile on this row. Same `!= false` treatment
  /// as [spotlightCapable].
  final bool? talkCapable;
  final bool isSpotlightOn;
  final bool isSpotlightShortcutBusy;

  /// Whether this camera reports spotlight hardware, per `Camera`'s onboarding
  /// `CameraCapabilities` snapshot. Null means unknown (not yet synced) — only
  /// a definitive `false` hides the tile, same `!= false` treatment
  /// `wanLiveViewCapable` gets in `LiveViewController`.
  final bool? spotlightCapable;
  final bool isSirenOn;
  final bool isSirenShortcutBusy;

  /// Same "definitive `false` only" hide rule as [spotlightCapable], for
  /// the camera's siren hardware.
  final bool? sirenCapable;
  final bool isWarningOn;
  final bool isWarningShortcutBusy;

  /// Same "definitive `false` only" hide rule as [spotlightCapable], for
  /// the camera's warning light/sound hardware.
  final bool? warningCapable;
  final CameraPrivacyMode privacyMode;
  final bool isPrivacyShortcutBusy;
  final CameraVideoMode videoMode;
  final bool isVideoModeShortcutBusy;
  final VoidCallback onSnapshot;
  final VoidCallback onRecord;
  final VoidCallback onTalk;
  final VoidCallback onSpotlight;
  final VoidCallback onSiren;
  final VoidCallback onWarning;
  final VoidCallback onPrivacy;
  final VoidCallback onVideoMode;
  final VoidCallback onAiMode;

  String _formatElapsed(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    // Only a definitive `false` hides the tile — `null` (not yet synced)
    // still shows it so a camera mid-onboarding isn't wrongly stripped of a
    // control it may well support.
    final showTalk = talkCapable != false;
    final showSpotlight = spotlightCapable != false;
    final showSiren = sirenCapable != false;
    final showWarning = warningCapable != false;
    // Real bug fix, 2026-09-15: a fixed (non-scrolling) Column here could
    // overflow its `Expanded` slot on a shorter screen once enough rows are
    // showing at once (e.g. a "using mobile data" banner above eating extra
    // height, plus Spotlight/Siren/Warning all capability-confirmed present)
    // — a real device report ("BOTTOM OVERFLOWED BY 69 PIXELS"). Wrapping in
    // `SingleChildScrollView` costs nothing when content already fits (no
    // visible scrollbar/behavior change) and lets it scroll instead of
    // clipping/erroring when it doesn't.
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Align(
        alignment: Alignment.topCenter,
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: _ControlTile(
                    key: const Key('LIVE-009'),
                    label: 'Snapshot',
                    icon: Icons.camera_alt_outlined,
                    onPressed: isEnabled ? onSnapshot : null,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _ControlTile(
                    key: const Key('LIVE-010'),
                    label: isRecording
                        ? _formatElapsed(recordingElapsed)
                        : 'Record',
                    icon: isRecording
                        ? Icons.stop_circle
                        : Icons.fiber_manual_record,
                    color: isRecording
                        ? (_recordingLimit - recordingElapsed <=
                                  const Duration(seconds: 5)
                              ? Colors.amber.shade700
                              : AppColors.offline)
                        : null,
                    progress: isRecording
                        ? recordingElapsed.inMilliseconds /
                              _recordingLimit.inMilliseconds
                        : null,
                    onPressed: isEnabled ? onRecord : null,
                  ),
                ),
                if (showTalk) ...[
                  const SizedBox(width: 12),
                  Expanded(
                    child: _ControlTile(
                      key: const Key('LIVE-011'),
                      label: isTalking ? 'Stop talking' : 'Talk',
                      icon: isTalking ? Icons.mic : Icons.mic_none,
                      color: isTalking ? AppColors.cyan : null,
                      onPressed: isEnabled ? onTalk : null,
                    ),
                  ),
                ],
                if (showSpotlight) ...[
                  const SizedBox(width: 12),
                  Expanded(
                    child: _ControlTile(
                      key: const Key('LIVE-018'),
                      label: isSpotlightOn ? 'Spotlight off' : 'Spotlight',
                      icon: isSpotlightOn
                          ? Icons.flashlight_on
                          : Icons.flashlight_off_outlined,
                      color: isSpotlightOn ? Colors.amber : null,
                      onPressed: (isEnabled && !isSpotlightShortcutBusy)
                          ? onSpotlight
                          : null,
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _ControlTile(
                    key: const Key('LIVE-041'),
                    label: switch (privacyMode) {
                      CameraPrivacyMode.off => 'Privacy Off',
                      CameraPrivacyMode.full => 'Privacy Full',
                      CameraPrivacyMode.zone => 'Privacy Zone',
                    },
                    icon: switch (privacyMode) {
                      CameraPrivacyMode.off => Icons.visibility_outlined,
                      CameraPrivacyMode.full => Icons.visibility_off,
                      CameraPrivacyMode.zone => Icons.crop_square,
                    },
                    color: privacyMode == CameraPrivacyMode.off
                        ? null
                        : AppColors.offline,
                    onPressed: (isEnabled && !isPrivacyShortcutBusy)
                        ? onPrivacy
                        : null,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _ControlTile(
                    key: const Key('LIVE-042'),
                    label: switch (videoMode) {
                      CameraVideoMode.day => 'Day',
                      CameraVideoMode.auto => 'Auto',
                      CameraVideoMode.night => 'Night',
                    },
                    icon: switch (videoMode) {
                      CameraVideoMode.day => Icons.wb_sunny,
                      CameraVideoMode.auto => Icons.brightness_auto,
                      CameraVideoMode.night => Icons.nightlight_round,
                    },
                    onPressed: (isEnabled && !isVideoModeShortcutBusy)
                        ? onVideoMode
                        : null,
                  ),
                ),
              ],
            ),
            if (showSiren || showWarning) ...[
              const SizedBox(height: 12),
              Row(
                children: [
                  if (showSiren) ...[
                    Expanded(
                      child: _ControlTile(
                        key: const Key('LIVE-045'),
                        label: isSirenOn ? 'Siren off' : 'Siren',
                        icon: isSirenOn
                            ? Icons.campaign
                            : Icons.campaign_outlined,
                        color: isSirenOn ? AppColors.offline : null,
                        onPressed: (isEnabled && !isSirenShortcutBusy)
                            ? onSiren
                            : null,
                      ),
                    ),
                  ],
                  if (showSiren && showWarning) const SizedBox(width: 12),
                  if (showWarning) ...[
                    Expanded(
                      child: _ControlTile(
                        key: const Key('LIVE-046'),
                        label: isWarningOn ? 'Warning off' : 'Warning',
                        icon: isWarningOn
                            ? Icons.warning
                            : Icons.warning_amber_outlined,
                        color: isWarningOn ? Colors.amber : null,
                        onPressed: (isEnabled && !isWarningShortcutBusy)
                            ? onWarning
                            : null,
                      ),
                    ),
                  ],
                ],
              ),
            ],
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _ControlTile(
                    key: const Key('LIVE-043'),
                    label: 'AI Mode',
                    icon: Icons.auto_awesome_outlined,
                    color: AppColors.cyan,
                    onPressed: isEnabled ? onAiMode : null,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// One square card in the Live tab's single-row quick-actions bar: icon
/// above a text label, tappable as a whole.
class _ControlTile extends StatelessWidget {
  const _ControlTile({
    super.key,
    required this.label,
    required this.icon,
    required this.onPressed,
    this.color,
    this.progress,
  });

  final String label;
  final IconData icon;
  final Color? color;
  final VoidCallback? onPressed;

  /// LIVE-010 only — 0.0-1.0 progress toward the 30-second recording limit
  /// while recording, `null` otherwise. A thin bar under the label so the
  /// approaching limit is visible before `LIVE-025`'s dialog fires at 100%,
  /// not just discoverable by mentally tracking the elapsed-time text.
  final double? progress;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isEnabled = onPressed != null;
    final tint = isEnabled
        ? (color ?? colorScheme.onSurface)
        : colorScheme.onSurface.withValues(alpha: 0.35);

    return SizedBox(
      height: 76,
      child: Opacity(
        opacity: isEnabled ? 1 : 0.6,
        child: GlassCard(
          padding: EdgeInsets.zero,
          borderRadius: 16,
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(16),
              onTap: onPressed,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(icon, color: tint, size: 24),
                  const SizedBox(height: 6),
                  Text(
                    label,
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: 'Manrope',
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: tint,
                    ),
                  ),
                  if (progress != null) ...[
                    const SizedBox(height: 6),
                    SizedBox(
                      width: 40,
                      height: 3,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(2),
                        child: LinearProgressIndicator(
                          value: progress!.clamp(0.0, 1.0),
                          backgroundColor: tint.withValues(alpha: 0.15),
                          valueColor: AlwaysStoppedAnimation(tint),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// One entry in the Playback day picker (last 7 days).
class _RecordingDay {
  const _RecordingDay(this.date);

  final DateTime date;
}

/// Tagged the same way this app's other real network paths log (see
/// `packages/camera_api`'s own `[LiveView]`-tagged `debugPrint` calls) —
/// `RecordingsClient`/`NuraeyeClient` themselves log nothing on failure, so
/// without this every Playback data problem (empty day, download failure,
/// a malformed response) was previously silent, with nothing in `adb
/// logcat` to diagnose it by.
void _logPlayback(String message) => debugPrint('[Playback] $message');

/// One recorded clip's span, in UTC epoch seconds — the shape
/// `ScrollableRecordingTimeline` draws segments from. A thin public wrapper
/// around [RecordingClip] (start/end, plus whether it has a
/// [RecordingClip.trigger]) so that widget doesn't need to import
/// `camera_api` itself. [hasEvent] drives the timeline's own event-marker
/// dots (design pass, 2026-09-08) — the same underlying signal LIVE-013/020's
/// Prev/Next Event buttons already use, just made visible directly on the
/// bar so a user can see *where* an event is before jumping to it.
class RecordingClipSpan {
  const RecordingClipSpan({
    required this.start,
    required this.end,
    this.hasEvent = false,
  });

  factory RecordingClipSpan.of(RecordingClip clip) => RecordingClipSpan(
    start: clip.start,
    end: clip.end,
    hasEvent: clip.trigger != null,
  );

  final int start;
  final int end;
  final bool hasEvent;
}

/// Playback tab: a day selector, prev/next-event (clip-with-`trigger`)
/// navigation, and a `ScrollableRecordingTimeline` recording map. **Real
/// recordings only, streamed live via this camera's RTSPS playback listener
/// — never downloaded-then-played.** 2026-09-07: video acquisition rebuilt
/// entirely around the sibling `nuraeye-rt` app's hardware-verified RTSP
/// pipeline (`lib/rtsp/rtsp_replay_client.dart` + `rtsp_remux_proxy.dart` +
/// `fmp4_muxer.dart`, ported near-verbatim from that app's own
/// `recording_timeline_screen.dart` — see those files' own doc comments for
/// the many real-hardware bugs their exact protocol handling already fixes)
/// via `OnvifReplayControlClient.getReplayUri()`, replacing the earlier
/// `RecordingsClient.downloadClip()`-then-play-a-temp-file design.
/// **The scrubber itself has gone through several iterations, all the same
/// day**: rebuilt as a simple, non-scrolling `RecordingMapTimeline` →
/// swapped for the shared `CameraTimeline` scroll/zoom widget per a direct
/// "can i not zoom and scroll also" request → swapped *back* to
/// `RecordingMapTimeline` per a direct side-by-side comparison showing
/// `CameraTimeline`'s scroll-based design was the source of two separate
/// real bugs hit in between (both rounds of tick-label edge-clipping) →
/// finally replaced by `ScrollableRecordingTimeline`
/// (`lib/widgets/scrollable_recording_timeline.dart`) per a direct "if 24
/// hour video is there how will user interact with that" follow-up request —
/// a **new** widget (not `CameraTimeline` reused, not another revert) that
/// borrows `CameraTimeline`'s proven scroll/zoom shape and its three
/// already-fixed bug classes, but keeps `RecordingMapTimeline`'s own
/// preview/commit callback split so a real RTSP reopen only happens once per
/// settled gesture, not once per scroll frame — see that widget's own doc
/// comment for the full reasoning. `CameraTimeline` itself is untouched and
/// still used by [events_screen.md]'s EVT-007, where a full 24-hour
/// scrollable view with per-frame callbacks is the right fit (cosmetic
/// browsing, no real seek per frame). `RecordingsClient` is still used here, but only for `GetRecordings`
/// (which clips exist and when) — never for downloading clip bytes for
/// playback; `_downloadClip` still uses it for the one case that
/// legitimately needs the actual file (saving a clip to the gallery). A
/// camera with no saved connection, or nothing recorded for the selected
/// day, reports [_PlaybackAvailability.noRecording] up to
/// `_CameraLiveScreenState` (which shows "No recording available" via
/// `_HeroVideo`) rather than ever substituting the bundled dummy asset.
class _PlaybackTab extends StatefulWidget {
  const _PlaybackTab({
    super.key,
    required this.connection,
    required this.thingName,
    required this.isWan,
    required this.isActive,
    required this.onSnapshot,
    required this.onClipStateChanged,
  });

  /// Null means this camera has no saved LAN connection — Playback can't
  /// check for real recordings at all in that case, so every day reports
  /// [_PlaybackAvailability.noRecording] with no network call attempted.
  final CameraConnection? connection;

  /// The camera's AWS IoT thing name, or null if it was never onboarded to
  /// the cloud — without one there is no WAN path for this tab at all.
  final String? thingName;

  /// Whether live view actually connected over WAN, threaded down from
  /// `LiveViewController.transport` rather than guessed from IP addresses
  /// (see `.claude/rules/mobile-app-screen-conventions.md` § LAN/WAN
  /// transport selection). Null while the transport is still unknown.
  final bool? isWan;

  /// Whether the Playback tab is the currently selected tab.
  final bool isActive;

  /// LIVE-015 — real capture, shared with the Live tab's own snapshot
  /// button (`_CameraLiveScreenState._takeSnapshot`): that method already
  /// falls back to a `RenderRepaintBoundary` screenshot of the shared video
  /// area whenever the Live tab's real WebRTC capture path doesn't apply,
  /// which is always the case here — it naturally captures whatever real
  /// clip frame (or "No recording available" message) is on screen.
  final VoidCallback onSnapshot;

  /// Reports the real clip currently open (or none) up to
  /// `_CameraLiveScreenState`, which renders it via `_HeroVideo` in the
  /// shared video Stack — the actual video pixels live there, not in this
  /// tab (this tab is just the day picker/timeline/controls below it).
  final void Function(
    VideoPlayerController? controller,
    _PlaybackAvailability availability,
  )
  onClipStateChanged;

  @override
  State<_PlaybackTab> createState() => _PlaybackTabState();
}

/// One open recorded-clip playback session, abstracted over transport so
/// [_PlaybackTabState._openClip]'s hard-won sequencing (request-id guarding,
/// assign-before-await, teardown ordering) keeps exactly one implementation.
/// LAN streams the clip over RTSP through a local remux proxy; WAN has the
/// camera push it into its own KVS playback stream, read back over the same
/// kind of local loopback server.
abstract class _ClipSession {
  /// Local loopback URL to hand to a `VideoPlayerController`.
  Uri get url;

  /// True once this session's own content is exhausted — drives auto-advance
  /// to the next clip.
  bool get isSessionEnded;

  /// Server-authoritative cursor, for a transport that has one. Used only
  /// before the player reports a position of its own.
  int? get lastKnownPositionEpochSeconds;

  Future<void> stop();
}

class _LanClipSession implements _ClipSession {
  _LanClipSession(this._proxy);

  final RtspRemuxProxy _proxy;

  @override
  Uri get url => _proxy.url!;

  @override
  bool get isSessionEnded => _proxy.isSessionEnded;

  @override
  int? get lastKnownPositionEpochSeconds =>
      _proxy.lastKnownPositionEpochSeconds;

  @override
  Future<void> stop() => _proxy.stop();
}

/// WAN: `StartClipPlayback` tells the camera to push the clip into its
/// `<thing>-playback` KVS stream, which [KvsMediaLiveViewSession] reads back.
/// Both halves stop together — the camera allows one playback session
/// camera-wide, so a leaked Start would block the next clip.
class _WanClipSession implements _ClipSession {
  _WanClipSession(this._control, this._media);

  final WanClipPlaybackClient _control;
  final KvsMediaLiveViewSession _media;

  @override
  Uri get url => _media.url!;

  @override
  bool get isSessionEnded => _media.isSessionEnded;

  /// No WAN equivalent — the camera reports no playback cursor of its own
  /// over MQTT, so the cursor follows the player's position instead.
  @override
  int? get lastKnownPositionEpochSeconds => null;

  @override
  Future<void> stop() async {
    await _media.stop();
    await _control.stop();
  }
}

class _PlaybackTabState extends State<_PlaybackTab> {
  /// Only dates that actually have footage — populated by
  /// [_loadDatesWithRecordings], never a fixed "last 7 days" — a date with
  /// nothing recorded has no reason to appear in the picker at all. Empty
  /// while still checking, or once confirmed there's nothing in the
  /// scanned window (or no saved connection).
  List<_RecordingDay> _recordingDays = [];
  int _selectedDayIndex = 0;
  bool _isLoadingDates = true;

  NuraeyeClient? _nuraeye;
  RecordingsClient? _recordings;
  OnvifReplayControlClient? _replayControl;
  WanRecordingsClient? _wanRecordings;
  WanClipPlaybackClient? _wanClipPlayback;

  /// True only once live view has actually confirmed WAN — an unknown
  /// transport stays on the LAN path rather than guessing, per the
  /// screen-conventions rule.
  bool get _useWan => widget.isWan == true && _wanRecordings != null;

  bool _isLoadingClips = true;
  List<RecordingClip> _clipsForDay = [];

  /// The real clip currently open for playback, if any — streamed live via
  /// [_clipSession] (on LAN this camera's RTSPS playback listener, remuxed to
  /// fMP4 over a
  /// local HTTP loopback) rather than downloaded first. See this file's
  /// `_PlaybackTab` doc comment for why.
  RecordingClip? _currentClip;
  VideoPlayerController? _clipController;
  _ClipSession? _clipSession;

  /// This session's own start point, in UTC epoch seconds — either the
  /// current clip's own start, or the seek target if this session opened
  /// mid-clip. [_clipController]'s own `.value.position` is relative to
  /// this, not to the clip's start — needed to convert it back to an
  /// absolute epoch for [_cursorEpochSeconds].
  int? _sessionStartEpoch;

  /// Polls [_clipSession]'s server-side-authoritative position once a second
  /// while a session is active, so the cursor/needle track real playback
  /// progress instead of sitting still until the next manual scrub — same
  /// reasoning as the sibling `nuraeye-rt` app's own position timer
  /// (`recording_timeline_screen.dart`). Also watches
  /// [_ClipSession.isSessionEnded] to auto-advance to the next clip once
  /// this one's real content is exhausted (event-triggered recording
  /// routinely has real gaps between clips — the camera's own multi-clip
  /// continuation only bridges genuinely back-to-back files within one
  /// still-open RTSP session, never across a real gap).
  Timer? _positionTimer;

  /// Cursor position, as UTC epoch seconds within the selected day — the
  /// source of truth `ScrollableRecordingTimeline` is drawn from.
  int? _cursorEpochSeconds;

  /// LIVE-016 — true only while a clip is actively being downloaded for
  /// saving to the gallery, swapping the button for a spinner so a second
  /// tap can't start an overlapping save.
  bool _isDownloadingClip = false;

  @override
  void initState() {
    super.initState();
    final connection = widget.connection;
    if (connection != null) {
      final nuraeye = NuraeyeClient(connection);
      _nuraeye = nuraeye;
      _recordings = RecordingsClient(nuraeye);
      _replayControl = OnvifReplayControlClient(connection);
    }
    final thingName = widget.thingName;
    if (thingName != null) {
      _wanRecordings = WanRecordingsClient(thingName);
      _wanClipPlayback = WanClipPlaybackClient(thingName);
    }
    _loadDatesWithRecordings();
  }

  /// Lists clips in `[start, end]` over whichever transport live view
  /// confirmed. `WanRecordingsClient` returns the clip list directly; the LAN
  /// client wraps it alongside storage flags, which only that path logs.
  Future<CameraResult<List<RecordingClip>>> _getRecordings({
    required int start,
    required int end,
    required String context,
  }) async {
    if (_useWan) {
      return _wanRecordings!.getRecordings(start: start, end: end);
    }
    final result = await _recordings!.getRecordings(start: start, end: end);
    return switch (result) {
      CameraSuccess(:final value) => () {
        _logPlayback(
          '$context: storageAvailable=${value.storageAvailable} '
          'cardPresent=${value.cardPresent} truncated=${value.truncated}',
        );
        return CameraSuccess(value.clips);
      }(),
      CameraFailure(:final reason) => CameraFailure(reason),
      CameraTimeout() => const CameraTimeout(),
    };
  }

  /// Scans the last 90 days via `GetRecordings` and buckets clip start times
  /// into **local** calendar dates (a date bucketed in UTC would show
  /// "today"'s footage under yesterday's date for roughly half the world) —
  /// the day picker (LIVE-019) only ever lists dates that come out of this,
  /// never a blind "last 7 days" that might include empty ones. Same
  /// approach as the sibling `nuraeye-rt` app's
  /// `RecordingTimelineScreen._loadDatesWithRecordings`.
  Future<void> _loadDatesWithRecordings() async {
    setState(() => _isLoadingDates = true);
    final recordings = _recordings;
    if (recordings == null) {
      _logPlayback('_loadDatesWithRecordings: no saved connection');
      setState(() {
        _isLoadingDates = false;
        _isLoadingClips = false;
        _recordingDays = [];
      });
      if (widget.isActive) {
        // Distinct from noRecording: this camera has no IP address saved at
        // all, so we show an actionable "add it in Settings" message.
        widget.onClipStateChanged(null, _PlaybackAvailability.noConnection);
      }
      return;
    }

    final now = DateTime.now();
    final start = now.subtract(const Duration(days: 90));
    final startEpoch = start.millisecondsSinceEpoch ~/ 1000;
    final endEpoch = now.millisecondsSinceEpoch ~/ 1000;
    final result = await _getRecordings(
      start: startEpoch,
      end: endEpoch,
      context: '_loadDatesWithRecordings',
    );
    if (!mounted) return;
    switch (result) {
      case CameraSuccess(:final value):
        final dates = <DateTime>{};
        for (final clip in value) {
          final local = DateTime.fromMillisecondsSinceEpoch(
            clip.start * 1000,
          ).toLocal();
          dates.add(DateTime(local.year, local.month, local.day));
        }
        final sorted = dates.toList()..sort((a, b) => b.compareTo(a));
        _logPlayback(
          '_loadDatesWithRecordings($startEpoch..$endEpoch): '
          '${value.length} clip(s) across ${sorted.length} day(s) '
          'over ${_useWan ? 'WAN' : 'LAN'}',
        );
        setState(() {
          _isLoadingDates = false;
          _recordingDays = [for (final date in sorted) _RecordingDay(date)];
          _selectedDayIndex = 0;
        });
        if (sorted.isNotEmpty) {
          await _loadClipsForDay(sorted.first);
        } else {
          // Real bug, found 2026-09-07 from a direct user report ("timeline
          // bar not showing at all... continuously loading"): with zero
          // recording-days, `_loadClipsForDay` (the method that normally
          // clears this) never runs at all, so `_isLoadingClips` stayed
          // stuck at its initial `true` forever — rendering a permanent
          // loading bar instead of the "no recordings" empty state.
          setState(() => _isLoadingClips = false);
          if (widget.isActive) {
            widget.onClipStateChanged(null, _PlaybackAvailability.noRecording);
          }
        }
      case CameraFailure(:final reason):
        _logPlayback('_loadDatesWithRecordings: GetRecordings failed: $reason');
        setState(() {
          _isLoadingDates = false;
          _isLoadingClips = false;
          _recordingDays = [];
        });
        if (widget.isActive) {
          widget.onClipStateChanged(null, _PlaybackAvailability.noRecording);
        }
      case CameraTimeout():
        _logPlayback('_loadDatesWithRecordings: GetRecordings timed out');
        setState(() {
          _isLoadingDates = false;
          _isLoadingClips = false;
          _recordingDays = [];
        });
        if (widget.isActive) {
          widget.onClipStateChanged(null, _PlaybackAvailability.noRecording);
        }
    }
  }

  /// Playback tab becoming active/inactive fully starts/stops the RTSP
  /// session — not just a local pause — mirroring
  /// `_CameraLiveScreenState._syncLiveConnectionForActiveTab`'s identical
  /// reasoning for the Live tab's WebRTC session: this camera's RTSPS
  /// playback listener has no `PAUSE` method (see `rtsp_replay_client.dart`'s
  /// doc comment), so leaving a session open while backgrounded would just
  /// keep streaming/buffering data nobody is watching, and contend with the
  /// Live tab's own connection for the camera's limited concurrent-session
  /// capacity. On return, reopens at the remembered cursor position.
  /// Real bug, found 2026-09-07 from a direct user report/screenshot
  /// ("A VideoPlayerController was used after being disposed" immediately
  /// followed by "setState() or markNeedsBuild() called during build...
  /// The widget on which setState() was called was: CameraLiveScreen"):
  /// [didUpdateWidget] runs synchronously as part of the *same* build pass
  /// that rebuilt this widget in the first place — calling
  /// [widget.onClipStateChanged] directly from here calls `setState()` on
  /// `_CameraLiveScreenState` (the ancestor currently mid-build), which
  /// Flutter rejects outright. The follow-on "used after disposed" error
  /// was this same illegal call corrupting the rebuild — a controller
  /// scheduled for disposal on one path was still referenced by a widget
  /// built from the resulting inconsistent state. Deferring the whole
  /// activation/deactivation handling to a post-frame callback (i.e. after
  /// the current build finishes entirely) fixes both.
  @override
  void didUpdateWidget(covariant _PlaybackTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Live view only learns the real transport once it connects, so the
    // first load runs with `isWan` still null and takes the LAN path — which
    // finds nothing on a WAN-only camera. Reload when the answer arrives,
    // and again if the transport later flips.
    if (widget.isWan != oldWidget.isWan) {
      unawaited(_closeCurrentClip());
      _loadDatesWithRecordings();
      return;
    }
    final becameActive = widget.isActive && !oldWidget.isActive;
    final becameInactive = !widget.isActive && oldWidget.isActive;
    if (!becameActive && !becameInactive) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (becameActive) {
        final resumeAt = _cursorEpochSeconds;
        if (resumeAt != null && _clipController == null) {
          final clip = _clipContaining(resumeAt) ?? _nearestClip(resumeAt);
          if (clip != null) {
            widget.onClipStateChanged(null, _PlaybackAvailability.loading);
            _openClip(clip, seekToEpochSeconds: resumeAt);
            return;
          }
        }
        final controller = _clipController;
        if (controller != null) {
          widget.onClipStateChanged(controller, _PlaybackAvailability.ready);
          controller.play();
        } else if (_pendingClipId != null) {
          widget.onClipStateChanged(null, _PlaybackAvailability.loading);
        } else if (_clipsForDay.isNotEmpty) {
          _openClip(_clipsForDay.first, seekToEpochSeconds: null);
        } else {
          widget.onClipStateChanged(
            null,
            _isLoadingClips
                ? _PlaybackAvailability.loading
                : _PlaybackAvailability.noRecording,
          );
        }
      } else {
        unawaited(_closeCurrentClip());
      }
    });
  }

  @override
  void dispose() {
    unawaited(_closeCurrentClip());
    _replayControl?.close();
    _recordings?.closeDownloadClient();
    _nuraeye?.close();
    super.dispose();
  }

  DateTime get _selectedLocalDay {
    final date = _recordingDays[_selectedDayIndex].date;
    return DateTime(date.year, date.month, date.day);
  }

  /// [_selectedLocalDay]'s bounds as UTC epoch seconds —
  /// `RecordingClip.start`/`.end`'s own unit. `.millisecondsSinceEpoch` on
  /// a local `DateTime` already accounts for the device's UTC offset, same
  /// local-day bucketing as the sibling `nuraeye-rt` app's
  /// `RecordingTimelineScreen._selectDate`.
  int get _dayStartEpoch => _selectedLocalDay.millisecondsSinceEpoch ~/ 1000;
  int get _dayEndEpoch =>
      _selectedLocalDay.add(const Duration(days: 1)).millisecondsSinceEpoch ~/
          1000 -
      1;

  /// The clip covering [epochSeconds], if any.
  RecordingClip? _clipContaining(int epochSeconds) {
    for (final clip in _clipsForDay) {
      if (epochSeconds >= clip.start && epochSeconds < clip.end) return clip;
    }
    return null;
  }

  /// The clip closest to [epochSeconds] — used to snap a timeline position
  /// that falls in a gap onto the nearest available recording.
  RecordingClip? _nearestClip(int epochSeconds) {
    RecordingClip? best;
    int? bestDistance;
    for (final clip in _clipsForDay) {
      final distance = epochSeconds < clip.start
          ? clip.start - epochSeconds
          : (epochSeconds >= clip.end ? epochSeconds - clip.end : 0);
      if (bestDistance == null || distance < bestDistance) {
        bestDistance = distance;
        best = clip;
      }
    }
    return best;
  }

  Future<void> _loadClipsForDay(DateTime date) async {
    await _closeCurrentClip();
    setState(() {
      _isLoadingClips = true;
      _clipsForDay = [];
      _cursorEpochSeconds = null;
    });
    if (widget.isActive) {
      widget.onClipStateChanged(null, _PlaybackAvailability.loading);
    }

    final recordings = _recordings;
    if (recordings == null) {
      if (!mounted) return;
      setState(() => _isLoadingClips = false);
      if (widget.isActive) {
        widget.onClipStateChanged(null, _PlaybackAvailability.noRecording);
      }
      return;
    }

    final result = await _getRecordings(
      start: _dayStartEpoch,
      end: _dayEndEpoch,
      context: '_loadClipsForDay',
    );
    if (!mounted) return;
    switch (result) {
      case CameraSuccess(:final value):
        final clips = List.of(value)
          ..sort((a, b) => a.start.compareTo(b.start));
        _logPlayback(
          '_loadClipsForDay($_dayStartEpoch..$_dayEndEpoch): '
          '${clips.length} clip(s)'
          '${clips.isEmpty ? '' : ' — durations(s): ${[for (final c in clips) c.end - c.start]}'}',
        );
        setState(() => _clipsForDay = clips);
        if (clips.isEmpty) {
          setState(() => _isLoadingClips = false);
          if (widget.isActive) {
            widget.onClipStateChanged(null, _PlaybackAvailability.noRecording);
          }
          return;
        }
        setState(() {
          _isLoadingClips = false;
          _cursorEpochSeconds = clips.first.start;
        });
        if (widget.isActive) {
          await _openClip(clips.first, seekToEpochSeconds: null);
        }
      case CameraFailure(:final reason):
        _logPlayback('_loadClipsForDay: GetRecordings failed: $reason');
        setState(() => _isLoadingClips = false);
        if (widget.isActive) {
          widget.onClipStateChanged(null, _PlaybackAvailability.noRecording);
        }
      case CameraTimeout():
        _logPlayback('_loadClipsForDay: GetRecordings timed out');
        setState(() => _isLoadingClips = false);
        if (widget.isActive) {
          widget.onClipStateChanged(null, _PlaybackAvailability.noRecording);
        }
    }
  }

  Future<void> _closeCurrentClip() async {
    final controller = _clipController;
    final session = _clipSession;
    _positionTimer?.cancel();
    _positionTimer = null;
    _clipController = null;
    _currentClip = null;
    _clipSession = null;
    _sessionStartEpoch = null;
    await controller?.dispose();
    await session?.stop();
  }

  /// Bumped by every [_openClip] call; a call whose id no longer matches
  /// the latest by the time an `await` resumes has been superseded by a
  /// newer one and abandons itself instead of applying stale results.
  int _openClipRequestId = 0;

  /// The clip a request is currently opening/streaming for, if any —
  /// distinct from [_currentClip] (already open and playing). Lets
  /// [_onTimelineSeekCommit]/[skipSeconds] avoid firing a second,
  /// concurrent [_openClip] for the same clip a fast interaction has
  /// already requested. Real bug this guards against, found 2026-09-07
  /// against the earlier download-based design: a live drag firing on
  /// every frame, with nothing to stop each frame from starting its own
  /// concurrent request, flooded this camera's embedded server.
  int? _pendingClipId;

  /// Resolves [clip] to a playable `rtsp(s)://` URI (`GetReplayUri`), opens
  /// a fresh [RtspRemuxProxy] against it (seeking to [seekToEpochSeconds] if
  /// given and it falls after the clip's own start, otherwise from the
  /// clip's start), and points a new `VideoPlayerController` at the proxy's
  /// local loopback URL. Mirrors the sibling `nuraeye-rt` app's
  /// `RecordingTimelineScreen._startPlaybackAt` closely — see that method's
  /// own doc/history for the real-hardware bugs this exact sequencing
  /// already fixes (assigning `_clipSession`/`_controller` before their own
  /// `await`s resolve, so a `dispose()`/tab-switch racing mid-open can still
  /// find and tear them down; not looping the fMP4 stream; declaring a real
  /// duration so the player's position is trustworthy).
  /// LAN: resolve the clip to an `rtsp(s)://` URI and stream it through a
  /// local remux proxy.
  Future<_ClipSession?> _openLanClipSession(
    RecordingClip clip, {
    required int? seekTo,
  }) async {
    final replayControl = _replayControl;
    final connection = widget.connection;
    if (replayControl == null || connection == null) return null;

    final uriResult = await replayControl.getReplayUri(clip.id.toString());
    final String replayUri;
    switch (uriResult) {
      case CameraSuccess(:final value):
        replayUri = value;
      case CameraFailure(:final reason):
        _logPlayback('_openClip(${clip.id}): GetReplayUri failed: $reason');
        return null;
      case CameraTimeout():
        _logPlayback('_openClip(${clip.id}): GetReplayUri timed out');
        return null;
    }

    final parsed = Uri.parse(replayUri);
    final proxy = RtspRemuxProxy(
      host: parsed.host,
      port: parsed.port,
      path: parsed.path,
      username: connection.username,
      password: connection.password,
      clipEpochStart: clip.start,
      seekToEpochSeconds: seekTo,
      clipEpochEnd: clip.end,
    );
    try {
      await proxy.start();
    } catch (e) {
      _logPlayback('_openClip(${clip.id}): RtspRemuxProxy.start() failed: $e');
      await proxy.stop();
      return null;
    }
    return _LanClipSession(proxy);
  }

  /// WAN: ask the camera to push the clip into its own `<thing>-playback` KVS
  /// stream, then read that back. A seek is a fresh Start at an offset —
  /// this screen never uses the camera's in-place seek, matching the LAN
  /// path, where seeking also reopens the session.
  Future<_ClipSession?> _openWanClipSession(
    RecordingClip clip, {
    required int? seekTo,
  }) async {
    final control = _wanClipPlayback;
    if (control == null) return null;

    // One playback session camera-wide — release whatever the camera still
    // holds before asking for another, or the new Start replaces a session
    // this app has already forgotten about.
    await control.stop();
    final startMs = seekTo == null ? 0 : (seekTo - clip.start) * 1000;
    final startResult = await control.startClip(clip.id, startMs: startMs);
    if (startResult is! CameraSuccess<void>) {
      _logPlayback('_openClip(${clip.id}): StartClipPlayback failed');
      return null;
    }

    final media = KvsMediaLiveViewSession(streamName: control.streamName)
      ..onLog = _logPlayback;
    try {
      await media.start();
    } catch (e) {
      _logPlayback('_openClip(${clip.id}): KVS playback session failed: $e');
      await media.stop();
      await control.stop();
      return null;
    }
    if (media.url == null) {
      await media.stop();
      await control.stop();
      return null;
    }
    return _WanClipSession(control, media);
  }

  Future<void> _openClip(
    RecordingClip clip, {
    required int? seekToEpochSeconds,
  }) async {
    final requestId = ++_openClipRequestId;
    _pendingClipId = clip.id;
    if (widget.isActive) {
      widget.onClipStateChanged(null, _PlaybackAvailability.loading);
    }

    final seekTo = seekToEpochSeconds != null && seekToEpochSeconds > clip.start
        ? seekToEpochSeconds
        : null;
    final sessionStart = seekTo ?? clip.start;
    final session = _useWan
        ? await _openWanClipSession(clip, seekTo: seekTo)
        : await _openLanClipSession(clip, seekTo: seekTo);

    if (!mounted || requestId != _openClipRequestId) {
      await session?.stop();
      return;
    }
    if (session == null) {
      _pendingClipId = null;
      if (widget.isActive) {
        widget.onClipStateChanged(null, _PlaybackAvailability.noRecording);
      }
      return;
    }

    // Whatever clip is currently open (if any) — captured now, *before*
    // `_clipSession`/`_clipController` get pointed at the new session below,
    // so it can be torn down by these exact references once the new session
    // is confirmed ready. Real bug, found 2026-09-07 from a direct user
    // report ("for 1 second it is showing the flutter error"): this used
    // to instead call `_closeCurrentClip()` (which reads the `_clipSession`/
    // `_clipController` *fields*) after already assigning the new session
    // for dispose-race safety (below) — so it tore down the brand-new
    // session it had just spent a full DESCRIBE/SETUP/PLAY round trip
    // opening, not the old one. Confirmed via logcat: a real RTSP session
    // opened, streamed several genuine access units to the player, then
    // `RtspRemuxProxy.stop()` fired again within about a second, closing
    // it — visible on screen as a brief flash of video/loading before
    // `_PlaybackAvailability` fell back to an error/unavailable state.
    final oldController = _clipController;
    final oldSession = _clipSession;
    _positionTimer?.cancel();
    _positionTimer = null;

    // Assigned immediately, before `initialize()`/`play()` resolve —
    // dispose-race safety, mirroring the sibling `nuraeye-rt` app's own
    // `_startPlaybackAt`: a `dispose()`/tab-switch racing mid-open can
    // still find and tear this down via these fields, wherever this
    // method itself is currently stuck.
    _clipSession = session;
    final newController = VideoPlayerController.networkUrl(session.url);
    setState(() => _clipController = newController);

    try {
      await newController.initialize();
      await newController.play();
    } catch (e) {
      _logPlayback(
        '_openClip(${clip.id}): VideoPlayerController init/play failed: $e',
      );
      if (identical(_clipSession, session)) _clipSession = null;
      if (identical(_clipController, newController)) _clipController = null;
      await newController.dispose();
      await session.stop();
      if (!mounted || requestId != _openClipRequestId) return;
      _pendingClipId = null;
      if (widget.isActive) {
        widget.onClipStateChanged(null, _PlaybackAvailability.noRecording);
      }
      return;
    }
    if (!mounted || requestId != _openClipRequestId) {
      if (identical(_clipSession, session)) _clipSession = null;
      if (identical(_clipController, newController)) _clipController = null;
      await newController.dispose();
      await session.stop();
      return;
    }

    // Only now safe to tear down whatever was open before — using the
    // captured old references, never the fields (which already point at
    // the new session by this point).
    await oldController?.dispose();
    await oldSession?.stop();

    _pendingClipId = null;
    setState(() {
      _currentClip = clip;
      _sessionStartEpoch = sessionStart;
      _cursorEpochSeconds = sessionStart;
    });
    if (widget.isActive) {
      widget.onClipStateChanged(newController, _PlaybackAvailability.ready);
    }
    _startPositionTimer(session, clip);
  }

  /// Polls [session]/[clip] once a second — see [_positionTimer]'s own doc.
  void _startPositionTimer(_ClipSession session, RecordingClip clip) {
    _positionTimer?.cancel();
    _positionTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted || !identical(_clipSession, session)) {
        timer.cancel();
        return;
      }
      if (session.isSessionEnded) {
        timer.cancel();
        _advanceToNextClipAfter(clip);
        return;
      }
      final sessionStart = _sessionStartEpoch;
      final controller = _clipController;
      if (sessionStart == null || controller == null) return;
      final playerPositionMs = controller.value.position.inMilliseconds;
      final playerPos = sessionStart + (playerPositionMs ~/ 1000);
      final pos = playerPositionMs > 0
          ? playerPos
          : session.lastKnownPositionEpochSeconds;
      if (pos == null) return;
      if (_clipContaining(pos) != null) {
        setState(() => _cursorEpochSeconds = pos);
      } else if (_clipsForDay.isNotEmpty && pos >= _clipsForDay.last.end) {
        setState(() => _cursorEpochSeconds = _clipsForDay.last.end - 1);
      }
      // else: pos landed in an ordinary gap between two known clips — leave
      // the cursor where it was rather than showing a time with nothing
      // recorded at it.
    });
  }

  /// Called once a playback session's own clip has genuinely finished
  /// ([_ClipSession.isSessionEnded]) — looks for the earliest known clip
  /// that starts at or after [clip]'s end (not assuming it's adjacent —
  /// Event-Triggered recording routinely has real gaps) and opens a fresh
  /// session there automatically, the same way an ordinary video gallery
  /// advances to the next item. Leaves the last frame on screen if there's
  /// nothing left today.
  void _advanceToNextClipAfter(RecordingClip clip) {
    RecordingClip? next;
    for (final candidate in _clipsForDay) {
      if (candidate.start >= clip.end &&
          (next == null || candidate.start < next.start)) {
        next = candidate;
      }
    }
    if (next == null) return;
    _openClip(next, seekToEpochSeconds: null);
  }

  /// LIVE-047/LIVE-049 — skips the cursor by [seconds] (negative to go
  /// back), snapping into the nearest recorded clip if the result lands in
  /// a gap.
  void skipSeconds(double seconds) {
    final base = _cursorEpochSeconds ?? _dayStartEpoch;
    _jumpTo(base + seconds.round());
  }

  void _selectDay(int index) {
    setState(() => _selectedDayIndex = index);
    _loadClipsForDay(_recordingDays[index].date);
  }

  /// LIVE-016 — real save-to-gallery: downloads the *current* clip in full
  /// via `RecordingsClient.downloadClip` (the one legitimate remaining use
  /// of the HTTP download path — RTSP streaming has no file to hand `Gal`)
  /// and saves it. No clip-range trim handles any more — those existed to
  /// trim a temp file that RTSP streaming no longer produces; saving the
  /// whole clip is the direct equivalent of what the sibling `nuraeye-rt`
  /// app's own clip screens offer.
  Future<void> _downloadClip() async {
    final clip = _currentClip;
    final recordings = _recordings;
    if (clip == null || recordings == null) return;
    setState(() => _isDownloadingClip = true);
    try {
      final result = await recordings.downloadClip(clip.id);
      switch (result) {
        case CameraSuccess(:final value):
          final tempDir = await getTemporaryDirectory();
          final tempFile = File(
            '${tempDir.path}/cctv_clip_${clip.id}_${DateTime.now().millisecondsSinceEpoch}.mp4',
          );
          await tempFile.writeAsBytes(value, flush: true);
          await Gal.putVideo(tempFile.path);
          unawaited(tempFile.delete().catchError((_) => tempFile));
          if (!mounted) return;
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('Clip saved')));
        case CameraFailure(:final reason):
          _logPlayback(
            '_downloadClip(${clip.id}): downloadClip failed: $reason',
          );
          if (!mounted) return;
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('Could not save clip')));
        case CameraTimeout():
          _logPlayback('_downloadClip(${clip.id}): downloadClip timed out');
          if (!mounted) return;
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('Could not save clip')));
      }
    } finally {
      if (mounted) setState(() => _isDownloadingClip = false);
    }
  }

  /// `ScrollableRecordingTimeline`'s live-preview callback — fires continuously
  /// while dragging, moves the cursor for display only, never reopens the
  /// RTSP session (that would spam the camera's single-client playback
  /// listener with a full DESCRIBE/SETUP/PLAY per gesture frame).
  void _onTimelineSeek(int epochSeconds) {
    setState(() => _cursorEpochSeconds = epochSeconds);
  }

  /// `ScrollableRecordingTimeline`'s commit callback — fired on tap (a discrete
  /// single target) or drag release, not on every drag-update tick. This is
  /// what actually re-binds the camera's RTSP session to the new position.
  Future<void> _onTimelineSeekCommit(int epochSeconds) => _jumpTo(epochSeconds);

  /// Moves playback to [epochSeconds] as one discrete jump — if that lands
  /// inside a recorded clip, opens/seeks it there; if it lands in a gap,
  /// jumps to the nearest recorded clip instead. Seeking within the
  /// already-open clip re-opens at the new offset (this camera's RTSPS
  /// playback listener has no seek-in-place method — a real seek always
  /// means a fresh DESCRIBE/SETUP/PLAY, same as `_pause`/`_resume` would).
  ///
  /// **Always calls `_openClip`, even when [clip] is already `_pendingClipId`
  /// — real bug, found 2026-09-07 from a direct user report ("kept it to
  /// 2:30, it is coming back to 1:45").** A guard here used to skip
  /// `_openClip` whenever the target clip matched the clip already being
  /// opened, on the theory that "already opening this clip" meant "nothing
  /// to do". But that's wrong whenever the *offset* is what changed, not the
  /// clip: seeking to 1:45 then quickly re-seeking to 2:30 within the same
  /// long clip, while the 1:45 open was still in flight, silently dropped
  /// the 2:30 request — the stale 1:45 open then completed and set the
  /// cursor/session back to 1:45, overwriting the user's newer seek.
  /// `_openClip`'s own `_openClipRequestId` counter already exists
  /// specifically to supersede a stale in-flight open with a newer one
  /// (see its own doc), so this guard was both redundant and actively
  /// harmful — removing it lets every seek always win over whatever was
  /// still loading before it.
  Future<void> _jumpTo(int epochSeconds) async {
    final directClip = _clipContaining(epochSeconds);
    final clip = directClip ?? _nearestClip(epochSeconds);
    if (clip == null) return;
    final target = directClip != null
        ? epochSeconds
        : (epochSeconds < clip.start ? clip.start : clip.end - 1);
    setState(() => _cursorEpochSeconds = target);
    await _openClip(clip, seekToEpochSeconds: target);
  }

  bool get _hasPrevEvent {
    final cursor = _cursorEpochSeconds;
    if (cursor == null) return false;
    return _clipsForDay.any((c) => c.trigger != null && c.start < cursor - 1);
  }

  bool get _hasNextEvent {
    final cursor = _cursorEpochSeconds;
    if (cursor == null) return false;
    return _clipsForDay.any((c) => c.trigger != null && c.start > cursor + 1);
  }

  void _jumpToEvent(int direction) {
    final cursor = _cursorEpochSeconds;
    if (cursor == null) return;
    final candidates =
        _clipsForDay
            .where((c) => c.trigger != null)
            .map((c) => c.start)
            .toList()
          ..sort();
    if (candidates.isEmpty) return;

    if (direction > 0) {
      if (!_hasNextEvent) return;
      final next = candidates.firstWhere((s) => s > cursor + 1);
      _jumpTo(next);
    } else {
      if (!_hasPrevEvent) return;
      final prev = candidates.lastWhere((s) => s < cursor - 1);
      _jumpTo(prev);
    }
  }

  String _formatDayLabel(DateTime date) {
    final now = DateTime.now();
    final isToday =
        date.year == now.year && date.month == now.month && date.day == now.day;
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    final dayName = isToday ? 'Today' : '${months[date.month - 1]} ${date.day}';
    return '$dayName · 12:00 AM – 11:59 PM';
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: _isLoadingDates
                ? const Padding(
                    padding: EdgeInsets.symmetric(vertical: 8),
                    child: LinearProgressIndicator(),
                  )
                : _recordingDays.isEmpty
                ? InputDecorator(
                    decoration: InputDecoration(
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 12,
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    child: const Row(
                      children: [
                        Icon(Icons.videocam_off_outlined, size: 18),
                        SizedBox(width: 10),
                        Text(
                          'No recordings in the last 90 days',
                          style: TextStyle(
                            fontFamily: 'Manrope',
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  )
                : PopupMenuButton<int>(
                    key: const Key('LIVE-019'),
                    tooltip: 'Choose a recorded day',
                    offset: const Offset(0, 44),
                    onSelected: _selectDay,
                    itemBuilder: (context) => [
                      for (var i = 0; i < _recordingDays.length; i++)
                        PopupMenuItem<int>(
                          key: Key('LIVE-019-$i'),
                          value: i,
                          child: Row(
                            children: [
                              if (i == _selectedDayIndex)
                                Icon(
                                  Icons.check,
                                  size: 18,
                                  color: Theme.of(context).colorScheme.primary,
                                )
                              else
                                const SizedBox(width: 18),
                              const SizedBox(width: 8),
                              Text(_formatDayLabel(_recordingDays[i].date)),
                            ],
                          ),
                        ),
                    ],
                    child: InputDecorator(
                      decoration: InputDecoration(
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 12,
                        ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.videocam_outlined, size: 18),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              _formatDayLabel(
                                _recordingDays[_selectedDayIndex].date,
                              ),
                              style: const TextStyle(
                                fontFamily: 'Manrope',
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          const Icon(Icons.arrow_drop_down),
                        ],
                      ),
                    ),
                  ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                TextButton.icon(
                  key: const Key('LIVE-013'),
                  onPressed: _hasPrevEvent ? () => _jumpToEvent(-1) : null,
                  icon: const Icon(Icons.chevron_left, size: 18),
                  label: const Text('Prev Event'),
                ),
                TextButton.icon(
                  key: const Key('LIVE-020'),
                  onPressed: _hasNextEvent ? () => _jumpToEvent(1) : null,
                  icon: const Icon(Icons.chevron_right, size: 18),
                  label: const Text('Next Event'),
                  iconAlignment: IconAlignment.end,
                ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          if (!_isLoadingClips && _clipsForDay.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              // `ScrollableRecordingTimeline` now owns its own GlassCard and
              // its own big time-of-day readout internally (recreated to
              // match `CameraTimeline`'s exact layout, 2026-09-08) — no
              // outer GlassCard/time-label wrapper here any more, retiring
              // the separate LIVE-014 text that used to duplicate it.
              child: ScrollableRecordingTimeline(
                key: const Key('LIVE-012'),
                // Always the full calendar day — not narrowed to where
                // footage actually exists — so the timeline is a stable,
                // predictable 24h reference the same way mainstream CCTV
                // apps anchor theirs, per direct user request 2026-09-08.
                spanStartEpochSeconds: _dayStartEpoch,
                spanEndEpochSeconds: _dayEndEpoch,
                clips: [
                  for (final clip in _clipsForDay) RecordingClipSpan.of(clip),
                ],
                cursorEpochSeconds: _cursorEpochSeconds,
                onSeek: _onTimelineSeek,
                onSeekCommit: _onTimelineSeekCommit,
              ),
            )
          else if (_isLoadingClips)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: LinearProgressIndicator(),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                IconButton(
                  key: const Key('LIVE-015'),
                  tooltip: 'Snapshot',
                  icon: const Icon(Icons.camera_alt_outlined, size: 18),
                  onPressed: widget.onSnapshot,
                ),
                const SizedBox(width: 8),
                _isDownloadingClip
                    ? const Padding(
                        padding: EdgeInsets.all(8),
                        child: SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    : IconButton.filled(
                        key: const Key('LIVE-016'),
                        tooltip: 'Save clip',
                        icon: const Icon(Icons.download_outlined),
                        onPressed: _currentClip != null ? _downloadClip : null,
                      ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Shown when a recording hits the 30-second limit: asks whether to keep
/// recording, counting down from [countdown]. If the countdown reaches
/// zero without a tap, the dialog closes as if "Stop" was pressed (the
/// caller then saves what's been recorded so far).
class _ContinueRecordingDialog extends StatefulWidget {
  const _ContinueRecordingDialog({required this.countdown});

  final Duration countdown;

  @override
  State<_ContinueRecordingDialog> createState() =>
      _ContinueRecordingDialogState();
}

class _ContinueRecordingDialogState extends State<_ContinueRecordingDialog> {
  late int _secondsLeft = widget.countdown.inSeconds;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_secondsLeft <= 1) {
        _timer?.cancel();
        Navigator.of(context).pop(false);
        return;
      }
      setState(() => _secondsLeft -= 1);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      key: const Key('LIVE-025'),
      title: const Text('Continue recording?'),
      content: Text(
        'You\'ve reached the 30-second recording limit. '
        'Stopping in $_secondsLeft s and saving the clip unless you continue.',
      ),
      actions: [
        TextButton(
          key: const Key('LIVE-026'),
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Stop'),
        ),
        FilledButton(
          key: const Key('LIVE-027'),
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Continue'),
        ),
      ],
    );
  }
}

/// Inline two-way-talk status bar (TALK-001) — overlaid at the bottom edge
/// of the video (not a separate full-screen page) so the feed stays
/// visible throughout a call, per user feedback that a full-screen panel
/// hides exactly what you'd want to see while talking to someone on
/// camera. Still implements `TWO_WAY_TALK_GUIDE.md` §6's call-style
/// contract — a distinct connecting/talking/busy/error state (not just a
/// spinner-or-not toggle) and a speakerphone control — just docked inline
/// instead of taking over the screen. [_CameraLiveScreenState._toggleTalk]
/// is what actually starts/ends the session and funnels every exit path
/// (this bar's End button, or just leaving the screen) through
/// [LiveViewController.endTalk]/`stop()` — both call the same
/// `RtspTalkSession.close()` underneath since 2026-09-15.
class _TalkStatusBar extends StatelessWidget {
  const _TalkStatusBar({
    super.key,
    required this.controller,
    required this.onEnd,
  });

  final LiveViewController controller;
  final VoidCallback onEnd;

  @override
  Widget build(BuildContext context) {
    final status = controller.talkStatus;
    final speakerphoneOn = controller.speakerphoneOn;

    return ColoredBox(
      color: Colors.black.withValues(alpha: 0.72),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              Icon(
                key: const Key('TALK-002'),
                switch (status) {
                  TalkStatus.connecting => Icons.phone_in_talk_outlined,
                  TalkStatus.talking => Icons.mic,
                  TalkStatus.busy => Icons.person_off_outlined,
                  TalkStatus.error => Icons.error_outline,
                  TalkStatus.idle => Icons.mic_none,
                },
                size: 20,
                color: switch (status) {
                  TalkStatus.talking => AppColors.cyan,
                  TalkStatus.busy || TalkStatus.error => AppColors.offline,
                  TalkStatus.connecting || TalkStatus.idle => Colors.white70,
                },
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  key: const Key('TALK-003'),
                  switch (status) {
                    TalkStatus.connecting => 'Calling…',
                    TalkStatus.talking => 'Talking',
                    TalkStatus.busy =>
                      "Camera's busy — someone else is talking",
                    TalkStatus.error =>
                      controller.talkErrorMessage ?? 'Something went wrong',
                    TalkStatus.idle => 'Ending…',
                  },
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (status == TalkStatus.talking)
                IconButton(
                  key: const Key('TALK-004'),
                  tooltip: speakerphoneOn ? 'Speaker on' : 'Speaker off',
                  color: speakerphoneOn ? AppColors.cyan : Colors.white70,
                  icon: const Icon(Icons.volume_up),
                  onPressed: () =>
                      controller.setSpeakerphoneOn(!speakerphoneOn),
                ),
              IconButton(
                key: const Key('TALK-005'),
                tooltip: 'End',
                color: AppColors.offline,
                icon: const Icon(Icons.call_end),
                onPressed: onEnd,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FullscreenVideo extends StatefulWidget {
  const _FullscreenVideo({
    required this.liveViewController,
    required this.showLiveView,
    required this.isMuted,
    required this.onMuteChanged,
    this.playbackClipController,
    this.playbackAvailability = _PlaybackAvailability.loading,
    this.onTogglePlaybackPlayPause,
    this.onSkipPlaybackVideo,
  });

  final LiveViewController? liveViewController;
  final bool showLiveView;
  final bool isMuted;
  final ValueChanged<bool> onMuteChanged;
  final VideoPlayerController? playbackClipController;
  final _PlaybackAvailability playbackAvailability;
  final VoidCallback? onTogglePlaybackPlayPause;
  final void Function(double minutes)? onSkipPlaybackVideo;

  @override
  State<_FullscreenVideo> createState() => _FullscreenVideoState();
}

class _FullscreenVideoState extends State<_FullscreenVideo> {
  late bool _isMuted = widget.isMuted;

  /// Mirrors `_CameraLiveScreenState._showPlaybackControls`'s tap-to-reveal +
  /// 4s auto-hide overlay (LIVE-047/048/049) — LIVE-052/053/054 give
  /// fullscreen the same play/pause/skip controls instead of only mute/exit,
  /// a real gap found comparing against the reference app (fullscreen there
  /// mirrors its inline controls exactly; this screen's fullscreen used to
  /// have no way to pause or skip a recorded clip at all).
  bool _showPlaybackControls = false;
  Timer? _hidePlaybackControlsTimer;

  @override
  void dispose() {
    _hidePlaybackControlsTimer?.cancel();
    super.dispose();
  }

  void _togglePlaybackControlsVisibility() {
    setState(() => _showPlaybackControls = !_showPlaybackControls);
    if (_showPlaybackControls) {
      _startHidePlaybackControlsTimer();
    } else {
      _hidePlaybackControlsTimer?.cancel();
    }
  }

  void _startHidePlaybackControlsTimer() {
    _hidePlaybackControlsTimer?.cancel();
    _hidePlaybackControlsTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => _showPlaybackControls = false);
    });
  }

  void _toggleMute() {
    setState(() {
      _isMuted = !_isMuted;
      widget.playbackClipController?.setVolume(_isMuted ? 0 : 1);
      widget.liveViewController?.setAudioEnabled(!_isMuted);
      widget.liveViewController?.wanVideoController?.setVolume(
        _isMuted ? 0 : 1,
      );
      widget.liveViewController?.lanRtspVideoController?.setVolume(
        _isMuted ? 0 : 1,
      );
    });
    widget.onMuteChanged(_isMuted);
  }

  @override
  Widget build(BuildContext context) {
    // Playback tab only — same condition LIVE-047/048/049 use inline.
    final showPlaybackOverlay =
        !widget.showLiveView && widget.onTogglePlaybackPlayPause != null;
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            Center(
              child: _HeroVideo(
                liveViewController: widget.liveViewController,
                showLiveView: widget.showLiveView,
                playbackClipController: widget.playbackClipController,
                playbackAvailability: widget.playbackAvailability,
                // Letterbox instead of crop: fullscreen has no box pinned to
                // the camera's own aspect ratio (unlike the inline 16:9
                // AspectRatio wrapper), so `cover` here would crop the frame
                // to match the phone's screen ratio instead of showing all
                // of it.
                fit: BoxFit.contain,
              ),
            ),
            if (showPlaybackOverlay)
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onTap: _togglePlaybackControlsVisibility,
                  child: AnimatedOpacity(
                    opacity: _showPlaybackControls ? 1 : 0,
                    duration: const Duration(milliseconds: 200),
                    child: IgnorePointer(
                      ignoring: !_showPlaybackControls,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.25),
                        ),
                        child: Center(
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              _VideoOverlayButton(
                                key: const Key('LIVE-052'),
                                tooltip: 'Back 10 seconds',
                                icon: Icons.replay_10,
                                onPressed: () {
                                  widget.onSkipPlaybackVideo?.call(-10);
                                  if (_showPlaybackControls) {
                                    _startHidePlaybackControlsTimer();
                                  }
                                },
                              ),
                              const SizedBox(width: 28),
                              _PlaybackPlayPauseButton(
                                key: const Key('LIVE-053'),
                                controller: widget.playbackClipController,
                                onPressed: () {
                                  widget.onTogglePlaybackPlayPause?.call();
                                  if (_showPlaybackControls) {
                                    _startHidePlaybackControlsTimer();
                                  }
                                },
                              ),
                              const SizedBox(width: 28),
                              _VideoOverlayButton(
                                key: const Key('LIVE-054'),
                                tooltip: 'Forward 10 seconds',
                                icon: Icons.forward_10,
                                onPressed: () {
                                  widget.onSkipPlaybackVideo?.call(10);
                                  if (_showPlaybackControls) {
                                    _startHidePlaybackControlsTimer();
                                  }
                                },
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            Positioned(
              bottom: 8,
              left: 8,
              child: IconButton(
                tooltip: _isMuted ? 'Unmute' : 'Mute',
                icon: Icon(
                  _isMuted ? Icons.volume_off : Icons.volume_up,
                  color: Colors.white,
                ),
                onPressed: _toggleMute,
              ),
            ),
            Positioned(
              bottom: 8,
              right: 8,
              child: IconButton(
                tooltip: 'Exit fullscreen',
                icon: const Icon(Icons.fullscreen_exit, color: Colors.white),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
