import '../../camera_result.dart';
import '../../recording_mode_types.dart';
import 'nuraeye_client.dart';

/// Camera capability discovery (`FR-NE-092`) — a single, growing NuraEye action rather than one
/// new action per capability (deliberate 2026-07-31 design choice; the existing per-feature
/// capability actions, `GetDeterrenceCapabilities`/`GetLocalStorageStatus`, keep their own
/// already-shipped contracts unchanged — this is the pattern for *new* capability flags only).
///
/// Mirrors the firmware's two-tier build structure (`FR-CF-137`): [wanCommandCapable] reflects
/// AWS IoT/MQTT itself (`CONFIG_AWS_ENABLED`); [wanLiveViewCapable] additionally requires
/// `REMOTE_LIVE_STREAMING` — a build can have AWS commands without KVS, so the former can be
/// `true` while the latter is `false`. Both also require this specific device to actually have
/// real AWS IoT credentials provisioned, not just build-time support.
class CameraCapabilities {
  const CameraCapabilities({
    required this.wanCommandCapable,
    required this.wanLiveViewCapable,
    required this.supportedEventTypes,
    required this.supportedEventDeterrenceOptions,
    required this.sirenCapable,
    required this.spotlightCapable,
    required this.warningCapable,
    required this.localStorageCapable,
    required this.recordingClipDurationMinSeconds,
    required this.recordingClipDurationMaxSeconds,
    required this.loiteringDurationMinSeconds,
    required this.loiteringDurationMaxSeconds,
    required this.bboxOverlayCapable,
    required this.supportedRecordingModes,
    required this.maxRecordingScheduleWindows,
  });

  /// Whether this device can receive AWS IoT/MQTT commands at all (deterrence, settings sync,
  /// WAN control) — independent of KVS. Not yet consumed anywhere in the app (no WAN command
  /// feature currently gates on it), but exposed for future use as WAN command features adopt
  /// capability checks the way `LiveViewController` already does for [wanLiveViewCapable].
  final bool wanCommandCapable;

  final bool wanLiveViewCapable;

  /// `FR-CF-143`/`FR-NE-111`: the alert event strings this specific camera build actually
  /// generates (e.g. `"VideoModeChanged"`, `"PrivacyModeChanged"`, `"PersonDetected"`) — the
  /// same identifiers used as the alert JSON's own `"event"` field and as
  /// `EventPreferencesClient`'s enable/disable keys. `EventSettingsScreen` builds its toggle
  /// list from this list only, never a hardcoded one, so a future firmware build that adds a
  /// real alert type needs no app update to show it. Empty on firmware too old to report it
  /// (missing/wrong-typed field is not an error — treated as "no alert types known").
  final List<String> supportedEventTypes;

  /// `FR-CF-144`/`FR-NE-112`: for each detection-type event this build supports auto-response
  /// actions on (only `"PersonDetected"` today), the response actions eligible for it — a
  /// subset of `siren`/`spotlight`/`warning`/`mobile_alert`, already intersected with this SKU's
  /// hardware capability. State-change event types (`VideoModeChanged`/`PrivacyModeChanged`)
  /// never appear as keys here, even though they appear in [supportedEventTypes] — deterrence
  /// response actions are deliberately scoped to detection events only. `EventSettingsScreen`
  /// builds its response-action multi-select from this map only, never a hardcoded action list.
  /// Empty on firmware too old to report it.
  final Map<String, List<String>> supportedEventDeterrenceOptions;

  /// `FR-CF-124`/`FR-CF-127`/`FR-CF-132` hardware presence — same fields
  /// `GetDeterrenceCapabilities` (`FR-NE-082`) already reports on its own dedicated endpoint,
  /// mirrored onto this one too (`FEAT-236`) so `EventSettingsScreen`'s Deterrence duration
  /// section and Live View's manual trigger controls can gate on the same already-fetched
  /// response other capability-driven UI already uses, instead of a second round trip. Default
  /// `false` on firmware too old to report them.
  final bool sirenCapable;
  final bool spotlightCapable;
  final bool warningCapable;

  /// `FR-CF-044`: whether this SKU has an SD card slot at all (a fixed, build-time hardware
  /// fact) — distinct from live card-insertion status, which `LocalStorageClient.getStatus()`
  /// reports separately. Default `false` on firmware too old to report it.
  final bool localStorageCapable;

  /// `FR-NE-119`: valid range for `RecordingsClient`'s clip-duration setting, in seconds — build
  /// UI (a slider/stepper bounds) from these, never a hardcoded range, per this repo's standing
  /// "every Set has a matching discoverable range" convention. Default `0`/`0` on firmware too
  /// old to report them (also `0`/`0` on a build with no local-storage capability at all — check
  /// [localStorageCapable] first).
  final int recordingClipDurationMinSeconds;
  final int recordingClipDurationMaxSeconds;

  /// `FR-CF-150`: valid range for `LoiteringDurationClient`'s dwell-threshold setting, in
  /// seconds — fixed compile-time bounds (`BSP_CAMERA_LOITERING_DURATION_MIN/MAX_SECONDS`), not
  /// per-value camera-reported, so no separate Options command exists (same as recording clip
  /// duration above). Default `0`/`0` on firmware too old to report them.
  final int loiteringDurationMinSeconds;
  final int loiteringDurationMaxSeconds;

  /// `FR-CF-151`: whether this build supports the bounding-box overlay toggle at all —
  /// `false` on a build with `AI_DETECTIONS` not compiled in (no detection pipeline to draw an
  /// overlay for). Gate `BboxOverlayClient`-driven UI on this, same as every other capability
  /// flag here — default `false` on firmware too old to report it.
  final bool bboxOverlayCapable;

  /// `FR-CF-048`/`FR-NE-089`/`FR-MOB-088`: which local recording modes this SKU supports at
  /// all (Continuous requires only `localStorageCapable`; Event-Triggered additionally requires
  /// `AI_DETECTIONS` compiled in). `RecordingModeSettingsScreen` builds its mode selector from
  /// this list only, never a hardcoded set of choices — never shows an unsupported mode as a
  /// disabled option, per `FR-MOB-088`. Empty on firmware too old to report it.
  final List<RecordingMode> supportedRecordingModes;

  /// `FR-CF-045`/`FR-NE-089`: max total windows `RecordingModeClient.setMode`'s Scheduled-mode
  /// `schedule` list may hold (`NURAEYE_MAX_RECORDING_SCHEDULE_WINDOWS`, fixed compile-time
  /// bound — the camera's persisted schedule array is a fixed-size buffer, not dynamically
  /// sized). `RecordingModeSettingsScreen`'s schedule editor must build its "add window"/total
  /// cap from this field, never a hardcoded constant — added 2026-09-25 after the app was found
  /// hardcoding a matching Dart constant instead of deriving it from this response, a real gap
  /// against this repo's own "no hardcoded values permitted, build UI from the capabilities/
  /// Options response only" convention. Default `14` (this constant's value on every firmware
  /// build shipped before this field existed) on a build too old to report it — not `0`, which
  /// would wrongly block the editor entirely on old-but-otherwise-working firmware.
  final int maxRecordingScheduleWindows;
}

/// Dispatches over both LAN and WAN on the firmware side (`FR-NE-092`, matching the
/// `GetDeterrenceCapabilities`/`GetLocalStorageStatus` convention), but this client only wraps
/// the LAN path — queried at onboarding (`add_camera_credentials_screen.dart`, camera is
/// physically at hand); the app layer caches the result, per the current app's only real use
/// case (see `camera_settings_cache.dart`'s `NetworkAnswerCache`). No WAN client exists yet; add
/// one (mirroring `IotCommandClient`'s Lambda-relay shape) if/when a feature actually needs to
/// re-check capabilities without being on LAN.
class CapabilitiesClient {
  CapabilitiesClient(this._nuraeye);

  final NuraeyeClient _nuraeye;

  /// Always a live network call — `camera_api` carries no caching of its own (see
  /// `.claude/rules/mobile-app-screen-conventions.md`'s "Caching capability/service-discovery
  /// responses" convention). Callers that want to avoid re-fetching this on every screen open
  /// should cache the result themselves (see `mobile_app/lib/features/settings/
  /// camera_settings_cache.dart`'s `NetworkAnswerCache`).
  Future<CameraResult<CameraCapabilities>> getCapabilities({
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final result = await _nuraeye.call('GetCapabilities', timeout: timeout);

    return switch (result) {
      CameraSuccess(:final value) => () {
          final wanCommandCapable = value['wan_command_capable'];
          final wanLiveViewCapable = value['wan_live_view_capable'];
          if (wanCommandCapable is! bool || wanLiveViewCapable is! bool) {
            return CameraFailure<CameraCapabilities>(
              'GetCapabilities response missing wan_command_capable/wan_live_view_capable: $value',
            );
          }
          final rawEventTypes = value['supported_event_types'];
          final supportedEventTypes = rawEventTypes is List
              ? rawEventTypes.whereType<String>().toList()
              : const <String>[];
          final rawDeterrenceOptions = value['supported_event_deterrence_options'];
          final supportedEventDeterrenceOptions = rawDeterrenceOptions is Map
              ? rawDeterrenceOptions.map(
                  (key, actions) => MapEntry(
                    key.toString(),
                    actions is List ? actions.whereType<String>().toList() : const <String>[],
                  ),
                )
              : const <String, List<String>>{};
          return CameraSuccess<CameraCapabilities>(
            CameraCapabilities(
              wanCommandCapable: wanCommandCapable,
              wanLiveViewCapable: wanLiveViewCapable,
              supportedEventTypes: supportedEventTypes,
              supportedEventDeterrenceOptions: supportedEventDeterrenceOptions,
              sirenCapable: value['siren_capable'] == true,
              spotlightCapable: value['spotlight_capable'] == true,
              warningCapable: value['warning_capable'] == true,
              localStorageCapable: value['local_storage_capable'] == true,
              recordingClipDurationMinSeconds:
                  value['recording_clip_duration_min_seconds'] is int
                      ? value['recording_clip_duration_min_seconds'] as int
                      : 0,
              recordingClipDurationMaxSeconds:
                  value['recording_clip_duration_max_seconds'] is int
                      ? value['recording_clip_duration_max_seconds'] as int
                      : 0,
              loiteringDurationMinSeconds:
                  value['loitering_duration_min_seconds'] is int
                      ? value['loitering_duration_min_seconds'] as int
                      : 0,
              loiteringDurationMaxSeconds:
                  value['loitering_duration_max_seconds'] is int
                      ? value['loitering_duration_max_seconds'] as int
                      : 0,
              bboxOverlayCapable: value['bbox_overlay_capable'] == true,
              supportedRecordingModes: (value['supported_recording_modes'] is List
                      ? (value['supported_recording_modes'] as List).whereType<String>()
                      : const <String>[])
                  .map(RecordingMode.fromWireValue)
                  .whereType<RecordingMode>()
                  .toList(),
              maxRecordingScheduleWindows:
                  value['max_recording_schedule_windows'] is int
                      ? value['max_recording_schedule_windows'] as int
                      : 14,
            ),
          );
        }(),
      CameraFailure(:final reason) => CameraFailure<CameraCapabilities>(reason),
      CameraTimeout() => const CameraTimeout<CameraCapabilities>(),
    };
  }
}
