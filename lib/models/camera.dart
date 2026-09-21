import 'dart:ui';

import 'package:camera_api/camera_api.dart';

import 'zone.dart';

/// How a camera is currently configured to record locally.
enum RecordingStatus { continuous, scheduled, eventTriggered, off }

/// Day of week for a [RecordingScheduleWindow], Monday-first.
enum RecordingScheduleDay {
  monday,
  tuesday,
  wednesday,
  thursday,
  friday,
  saturday,
  sunday,
}

/// A single day/time window during which Scheduled recording is active.
/// [startMinutes]/[endMinutes] are minutes since midnight (0-1439);
/// [endMinutes] must be greater than [startMinutes] (no overnight-spanning
/// windows — model two windows instead).
class RecordingScheduleWindow {
  const RecordingScheduleWindow({
    required this.day,
    required this.startMinutes,
    required this.endMinutes,
  });

  final RecordingScheduleDay day;
  final int startMinutes;
  final int endMinutes;
}

/// A critical local-storage condition reported by the camera. `none` means
/// storage is healthy.
enum StorageFailure { none, full, cardRemoved, readOnly, unavailable }

extension StorageFailureMessage on StorageFailure {
  /// Plain-language description of this failure, or null for [StorageFailure.none].
  String? get message => switch (this) {
    StorageFailure.none => null,
    StorageFailure.full => 'SD card full — recording has stopped',
    StorageFailure.cardRemoved => 'SD card removed — no local recording',
    StorageFailure.readOnly => 'SD card is read-only — recording has stopped',
    StorageFailure.unavailable => 'SD card unavailable — recording has stopped',
  };
}

/// Overall connectivity + health status shown on live-view/dashboard status
/// badges — see [Camera.liveStatus].
enum CameraLiveStatus { online, needsAttention, offline }

/// Fixed preview-corner position for a non-draggable OSD tag (Bitrate,
/// Signal Strength).
enum OsdCorner { topLeft, topRight, bottomLeft, bottomRight }

/// Video Mode screen — day/night switching behavior.
enum CameraVideoMode { day, auto, night }

/// Night Mode screen — how the camera renders low-light footage.
enum CameraNightMode { infrared, smart, fullColor }

/// Privacy Mode screen — whether/how the feed is masked.
enum CameraPrivacyMode { off, full, zone }

/// Imaging screen — mirror/flip orientation.
enum CameraMirrorFlip { off, mirror, flip, both }

/// Imaging screen — anti-flicker (mains-frequency) compensation mode.
/// Mirrors `camera_api`'s `AntiFlickerMode` wire enum.
enum CameraAntiFlickerMode { hz50, hz60, auto }

/// Imaging screen — auto vs. manual control, shared by white balance and
/// exposure.
enum CameraAutoManual { auto, manual }

/// Video Encoder screen — codec.
enum CameraEncoderType { h264, h265 }

/// Video Encoder screen — encoder profile.
enum CameraEncoderProfile { baseline, main, high }

/// Video Encoder screen — constant vs. variable bitrate.
enum CameraBitrateMode { cbr, vbr }

/// Video Encoder screen — which of the camera's independently-configurable
/// encoder streams a `VideoStreamEncoderScreen` instance is editing.
/// [highRes] (Stream 0, ONVIF `VideoEncoderCfg_1`) is the only one with a
/// firmware API today; [medium] and [low] are staged locally until the
/// senior engineer sends a client for the extra stream(s) — see
/// `docs/screens/camera_settings/video_display/video_encoder_screen.md`.
enum VideoStream { highRes, medium, low }

/// Camera Live screen — the viewer's requested live-stream quality
/// (LIVE-058's chip/LIVE-059's sheet), auto vs manual. [auto] both picks a
/// displayed effective level from the live-measured bitrate
/// (`LiveViewController.measuredBitrateKbps`) and (2026-09-15) enables real
/// automatic step-down/step-up via `LiveViewController.setAutoQualityLadder`.
/// On LAN, [high]/[medium]/[low] no longer carry their literal meaning for a
/// manual pick — the real chosen profile lives on
/// [Camera.preferredLanProfileToken] instead, since a camera's real profile
/// count/resolutions can't be assumed to be exactly this 3-way split (see
/// that field's doc). These three values are still used as-is for WAN's
/// separate, session-only quality selection (`LiveViewController.wanQuality`
/// / `StreamQuality`), where the tiers really are fixed, named KVS streams.
enum CameraStreamQuality { auto, high, medium, low }

/// Line Crossing screen — which direction(s) count as a crossing.
enum CameraCrossingDirection { both, aToB, bToA }

/// One encoder stream's full settings — the field set
/// `VideoStreamEncoderScreen` edits. A value type with real `==`/`hashCode`
/// (per `.claude/rules/mobile-app-screen-conventions.md`'s pending/applied
/// equality rule). [Camera]'s own top-level `videoResolution`/`encoderType`/
/// … fields hold the [VideoStream.highRes] stream's values (unchanged, so
/// the retention estimate and bitrate badges keep reading them directly);
/// [Camera.mediumStreamEncoder]/[Camera.lowStreamEncoder] hold the other
/// two. Use [Camera.encoderConfigFor]/[Camera.copyWithEncoderConfig] rather
/// than touching either representation directly.
class StreamEncoderConfig {
  const StreamEncoderConfig({
    required this.resolution,
    required this.encoderType,
    required this.encoderProfile,
    required this.frameRate,
    required this.govLength,
    required this.quality,
    required this.bitrateMode,
    required this.bitrateKbps,
  });

  /// The camera's own reported pixel dimensions (`camera_api`'s `Resolution`
  /// record — structural equality, so pending-vs-applied comparison works).
  /// Never a bucketed enum: a real 2560x1440 stream must not be labelled
  /// "1080p", and two distinct reported sizes must stay distinguishable.
  final Resolution resolution;
  final CameraEncoderType encoderType;
  final CameraEncoderProfile encoderProfile;
  final double frameRate;
  final double govLength;
  final double quality;
  final CameraBitrateMode bitrateMode;
  final double bitrateKbps;

  static const highResDefaults = StreamEncoderConfig(
    resolution: (width: 1920, height: 1080),
    encoderType: CameraEncoderType.h265,
    encoderProfile: CameraEncoderProfile.main,
    frameRate: 15,
    govLength: 30,
    quality: 3,
    bitrateMode: CameraBitrateMode.cbr,
    bitrateKbps: 4096,
  );

  static const mediumDefaults = StreamEncoderConfig(
    resolution: (width: 1280, height: 720),
    encoderType: CameraEncoderType.h264,
    encoderProfile: CameraEncoderProfile.main,
    frameRate: 15,
    govLength: 30,
    quality: 3,
    bitrateMode: CameraBitrateMode.cbr,
    bitrateKbps: 1536,
  );

  static const lowDefaults = StreamEncoderConfig(
    resolution: (width: 640, height: 480),
    encoderType: CameraEncoderType.h264,
    encoderProfile: CameraEncoderProfile.baseline,
    frameRate: 15,
    govLength: 30,
    quality: 3,
    bitrateMode: CameraBitrateMode.cbr,
    bitrateKbps: 512,
  );

  /// This stream's hardcoded default preset — Reset (SENC-004) restores to
  /// this, and it's the constructor default for [Camera.mediumStreamEncoder]/
  /// [Camera.lowStreamEncoder].
  static StreamEncoderConfig defaultsFor(VideoStream stream) =>
      switch (stream) {
        VideoStream.highRes => highResDefaults,
        VideoStream.medium => mediumDefaults,
        VideoStream.low => lowDefaults,
      };

  StreamEncoderConfig copyWith({
    Resolution? resolution,
    CameraEncoderType? encoderType,
    CameraEncoderProfile? encoderProfile,
    double? frameRate,
    double? govLength,
    double? quality,
    CameraBitrateMode? bitrateMode,
    double? bitrateKbps,
  }) => StreamEncoderConfig(
    resolution: resolution ?? this.resolution,
    encoderType: encoderType ?? this.encoderType,
    encoderProfile: encoderProfile ?? this.encoderProfile,
    frameRate: frameRate ?? this.frameRate,
    govLength: govLength ?? this.govLength,
    quality: quality ?? this.quality,
    bitrateMode: bitrateMode ?? this.bitrateMode,
    bitrateKbps: bitrateKbps ?? this.bitrateKbps,
  );

  @override
  bool operator ==(Object other) =>
      other is StreamEncoderConfig &&
      other.resolution == resolution &&
      other.encoderType == encoderType &&
      other.encoderProfile == encoderProfile &&
      other.frameRate == frameRate &&
      other.govLength == govLength &&
      other.quality == quality &&
      other.bitrateMode == bitrateMode &&
      other.bitrateKbps == bitrateKbps;

  @override
  int get hashCode => Object.hash(
    resolution,
    encoderType,
    encoderProfile,
    frameRate,
    govLength,
    quality,
    bitrateMode,
    bitrateKbps,
  );
}

class Camera {
  const Camera({
    required this.id,
    required this.name,
    required this.isOnline,
    this.room,
    this.isFavorite = false,
    this.isPinned = false,
    this.thumbnailUrl,
    this.lastSeen,
    this.timezone = 'UTC',
    this.location,
    this.recordingStatus = RecordingStatus.off,
    this.recordingScheduleWindows = const [],
    this.wifiNetwork = '—',
    this.ipAddress = '—',
    this.signalStrength = 0,
    this.networkSpeedKbps = 0,
    this.macAddress = '—',
    this.manufacturer = '—',
    this.model = '—',
    this.firmwareVersion = '—',
    this.serialNumber = '—',
    this.hardwareId = '—',
    this.bitrateOsdEnabled = false,
    this.bitrateOsdPosition = OsdCorner.bottomRight,
    this.signalStrengthOsdEnabled = false,
    this.signalStrengthOsdPosition = OsdCorner.topRight,
    this.liveTagOsdEnabled = true,
    this.streamQuality = CameraStreamQuality.auto,
    this.preferredLanProfileToken,
    this.videoMode = CameraVideoMode.auto,
    this.nightMode = CameraNightMode.smart,
    this.nightVisionColorCapable,
    this.nightVisionSmartCapable,
    this.privacyMode = CameraPrivacyMode.off,
    this.privacyZones = const [],
    this.mirrorFlip = CameraMirrorFlip.off,
    this.antiFlickerMode = CameraAntiFlickerMode.auto,
    this.brightness = 50,
    this.contrast = 50,
    this.saturation = 50,
    this.sharpness = 50,
    this.wdrEnabled = false,
    this.wdrLevel = 50,
    this.whiteBalance = CameraAutoManual.auto,
    this.exposure = CameraAutoManual.auto,
    this.exposureTime = 10000,
    this.exposureGain = 0,
    this.videoResolution = const (width: 1920, height: 1080),
    this.encoderType = CameraEncoderType.h264,
    this.encoderProfile = CameraEncoderProfile.main,
    this.frameRate = 15,
    this.govLength = 30,
    this.encoderQuality = 3,
    this.bitrateMode = CameraBitrateMode.cbr,
    this.bitrateKbps = 2048,
    this.mediumStreamEncoder = StreamEncoderConfig.mediumDefaults,
    this.lowStreamEncoder = StreamEncoderConfig.lowDefaults,
    this.motionDetectionEnabled = false,
    this.motionSensitivity = 50,
    this.intrusionDetectionEnabled = false,
    this.intrusionSensitivity = 50,
    this.intrusionZones = const [],
    this.lineCrossingEnabled = false,
    this.lineCrossingSensitivity = 50,
    this.lineCrossingStart = const Offset(0.2, 0.5),
    this.lineCrossingEnd = const Offset(0.8, 0.5),
    this.lineCrossingDirection = CameraCrossingDirection.both,
    this.personDetectionEnabled = false,
    this.personDetectionConfidence = 50,
    this.personDetectionZones = const [],
    this.loiteringDurationSeconds,
    this.bboxOverlayEnabled,
    this.vehicleDetectionEnabled = false,
    this.vehicleDetectionConfidence = 50,
    this.parkingMonitoringEnabled = false,
    this.parkingZones = const [],
    this.parkingRestrictedDwellSeconds = 30,
    this.parkingWrongBayDwellSeconds = 60,
    this.speakerVolume = 50,
    this.micGain = 50,
    this.audioRecordingEnabled = false,
    this.sdStorageEnabled = true,
    this.sdCardPresent = true,
    this.sdCardCapacityGb = 64,
    this.sdCardUsedGb = 20,
    this.sdCardHealthPercent = 95,
    this.sdCardEnduranceRated = true,
    this.retentionDays = 14,
    this.storageFailure = StorageFailure.none,
    this.host,
    this.username,
    this.password,
    this.thingName,
    this.wanLiveViewCapable,
    this.wanCommandCapable,
    this.lastKnownWan,
    this.sirenCapable,
    this.spotlightCapable,
    this.warningCapable,
    this.rebootCount,
    this.lastRebootUtc,
    this.uptimeSeconds,
    this.clockSyncUncertain,
  });

  final String id;
  final String name;
  final bool isOnline;
  final String? room;
  final bool isFavorite;

  /// Pinned cameras are sorted first on the Dashboard's "All" tab. Pinning
  /// is only offered on that tab — it does not affect Favourites or room
  /// tabs.
  final bool isPinned;

  /// Snapshot/thumbnail image for this camera. Currently points at
  /// placeholder images (picsum.photos) — swap for a real camera snapshot
  /// endpoint once a backend/protocol is wired up.
  final String? thumbnailUrl;

  /// When this camera was last seen online. Only meaningful while
  /// [isOnline] is false — shown in the offline overlay on the dashboard.
  final DateTime? lastSeen;

  /// The following device-info fields are stub-seeded per camera (see
  /// HomesController) until a real CCTV protocol/backend is wired up (see
  /// CLAUDE.md) — they are not hardcoded on the display screen itself, so
  /// swapping in a real device query later only touches the data source.
  final String timezone;

  /// The camera's own ONVIF `Scopes`-reported location string
  /// (`OnvifDeviceClient`/`WanDeviceIdentityClient.setDeviceLocation`) —
  /// `null` until synced or set. Distinct from [room]/the Home/Room
  /// organizational hierarchy shown in this app's own "Location" section on
  /// `CameraInfoScreen` (labeled "Camera-reported location" there to avoid
  /// the name collision).
  final String? location;
  final RecordingStatus recordingStatus;

  /// Only meaningful while [recordingStatus] is [RecordingStatus.scheduled].
  final List<RecordingScheduleWindow> recordingScheduleWindows;
  final String wifiNetwork;
  final String ipAddress;

  /// Wi-Fi signal strength as a 0–4 bar rating.
  final int signalStrength;

  /// Current network throughput in kbps — shown auto-scaled to KB/s or
  /// MB/s (see `formatBitrate` in `lib/widgets/live_status_badges.dart`).
  final double networkSpeedKbps;
  final String macAddress;
  final String manufacturer;
  final String model;
  final String firmwareVersion;
  final String serialNumber;
  final String hardwareId;

  /// The following are composited by the mobile app on top of the stream
  /// (not sent to or rendered by the camera) — edited from the Tags
  /// settings screen. Bitrate and Signal Strength each have their own
  /// enable toggle and fixed preview-corner position; Live Tag is always
  /// pinned to the top-left corner.
  final bool bitrateOsdEnabled;
  final OsdCorner bitrateOsdPosition;
  final bool signalStrengthOsdEnabled;
  final OsdCorner signalStrengthOsdPosition;
  final bool liveTagOsdEnabled;

  /// User's preferred live-stream quality (LIVE-058/059) — [auto] vs
  /// manual. When manual, the actual requested profile is
  /// [preferredLanProfileToken], not derived from this enum's value (see
  /// that field's own doc for why).
  final CameraStreamQuality streamQuality;

  /// The real ONVIF profile token (e.g. `"Profile_1"`) requested when
  /// [streamQuality] is a manual (non-[CameraStreamQuality.auto]) pick.
  /// Added 2026-09-15: replaces the old approach of bucketing the camera's
  /// real profiles into exactly High/Medium/Low by sorted index, which
  /// `MediaProfile`'s own doc comment (`onvif_video_encoder_client.dart`)
  /// explicitly warns never to do ("never hardcode 3 streams... always read
  /// this list and its length") — a camera with only 2 profiles silently
  /// collapsed Medium and Low onto the same token under the old scheme.
  /// `null` means "no manual pick recorded yet" (falls back to whatever
  /// [LiveViewController] is currently using) — this stays `null` while
  /// [streamQuality] is [CameraStreamQuality.auto].
  final String? preferredLanProfileToken;

  /// The following settings are persisted here so that once a real
  /// CCTV protocol/stream is wired up (see CLAUDE.md), applying them is
  /// just a matter of reading these fields — no further plumbing needed.
  final CameraVideoMode videoMode;
  final CameraNightMode nightMode;

  /// Hardware/firmware capability flags from the camera's own
  /// `GetNightVisionType` response — null means "camera not verified yet"
  /// (no connection, or the check hasn't returned), same fallback reasoning
  /// as the screen-local flags this mirrors in `night_mode_screen.dart`.
  final bool? nightVisionColorCapable;
  final bool? nightVisionSmartCapable;
  final CameraPrivacyMode privacyMode;
  final List<DrawableZone> privacyZones;
  final CameraMirrorFlip mirrorFlip;
  final CameraAntiFlickerMode antiFlickerMode;
  final double brightness;
  final double contrast;
  final double saturation;
  final double sharpness;
  final bool wdrEnabled;
  final double wdrLevel;
  final CameraAutoManual whiteBalance;
  final CameraAutoManual exposure;

  /// ONVIF `ExposureTime`/`Gain` — only meaningful when [exposure] is
  /// [CameraAutoManual.manual]; ignored by the camera in Auto mode. Units
  /// match `ImagingSettings.exposureTime`/`exposureGain`'s wire values
  /// (microseconds / dB), not independently re-derived here.
  final double exposureTime;
  final double exposureGain;

  /// These eight fields are the [VideoStream.highRes] stream's encoder
  /// settings (ONVIF `VideoEncoderCfg_1`) — kept as top-level fields, not
  /// folded into a [StreamEncoderConfig], so the retention estimate and the
  /// bitrate badges keep reading `bitrateKbps`/etc. directly. The other two
  /// streams live in [mediumStreamEncoder]/[lowStreamEncoder]. Read/write
  /// any stream uniformly via [encoderConfigFor]/[copyWithEncoderConfig].
  final Resolution videoResolution;
  final CameraEncoderType encoderType;
  final CameraEncoderProfile encoderProfile;
  final double frameRate;
  final double govLength;
  final double encoderQuality;
  final CameraBitrateMode bitrateMode;
  final double bitrateKbps;

  /// Medium/Low encoder streams — no firmware API yet (see
  /// `docs/screens/camera_settings/video_display/video_encoder_screen.md`),
  /// so these are local-only staged state that `VideoStreamEncoderScreen`
  /// edits and `simulateCameraSave` persists.
  final StreamEncoderConfig mediumStreamEncoder;
  final StreamEncoderConfig lowStreamEncoder;

  final bool motionDetectionEnabled;
  final double motionSensitivity;
  final bool intrusionDetectionEnabled;
  final double intrusionSensitivity;
  final List<DrawableZone> intrusionZones;
  final bool lineCrossingEnabled;
  final double lineCrossingSensitivity;
  final Offset lineCrossingStart;
  final Offset lineCrossingEnd;
  final CameraCrossingDirection lineCrossingDirection;
  final bool personDetectionEnabled;
  final double personDetectionConfidence;
  final List<PolygonZone> personDetectionZones;

  /// Dwell threshold (whole seconds) before a `Loitering` event fires —
  /// `LoiteringDurationClient`/`WanLoiteringDurationClient`, independent of
  /// whether [personDetectionEnabled] itself is on. Null means "not yet
  /// synced from the camera", same convention as [nightVisionColorCapable].
  final int? loiteringDurationSeconds;

  /// Whether the camera draws its AI detection bounding-box overlay
  /// (OSD burn-in) on the video — `BboxOverlayClient`/`WanBboxOverlayClient`.
  /// Null means "not yet synced".
  final bool? bboxOverlayEnabled;
  final bool vehicleDetectionEnabled;
  final double vehicleDetectionConfidence;

  /// Zone-based parking occupancy monitoring — distinct from
  /// [vehicleDetectionEnabled]'s plain "did a vehicle appear" toggle. Master
  /// enable; zones can still be configured while this is off. Entirely
  /// local-only for now — no `camera_api` capability exists yet for
  /// per-zone vehicle occupancy classification.
  final bool parkingMonitoringEnabled;
  final List<ParkingZone> parkingZones;

  /// Seconds a vehicle must remain inside a [ParkingZoneType.restricted]
  /// zone before a violation fires — avoids flagging a car briefly cutting
  /// across the area. Local-only value; no camera-sourced bounds exist yet.
  final int parkingRestrictedDwellSeconds;

  /// Seconds a vehicle must remain overlapping a neighboring
  /// [ParkingZoneType.slot]'s line before it's flagged as "wrong bay" —
  /// deliberately a separate, usually-shorter-tolerance threshold from
  /// [parkingRestrictedDwellSeconds] since straddling a line briefly while
  /// parking isn't itself a violation.
  final int parkingWrongBayDwellSeconds;
  final double speakerVolume;
  final double micGain;

  /// Whether this camera's recordings include an audio track — independent
  /// of [speakerVolume]/[micGain], which affect two-way talk and warning
  /// playback, not what gets recorded.
  final bool audioRecordingEnabled;

  /// Independent of whether a card is physically present ([sdCardPresent]).
  final bool sdStorageEnabled;
  final bool sdCardPresent;
  final double sdCardCapacityGb;
  final double sdCardUsedGb;

  /// Wear-level health, 0-100 (100 = new/perfect condition).
  final double sdCardHealthPercent;

  /// Whether the inserted card is rated for continuous surveillance writes,
  /// as opposed to a general-purpose consumer card.
  final bool sdCardEnduranceRated;

  /// How long locally recorded footage is kept before being overwritten.
  final int retentionDays;

  /// A critical storage condition currently reported by the camera, or
  /// [StorageFailure.none] if storage is healthy.
  final StorageFailure storageFailure;

  /// The following are the camera's LAN/WAN connection credentials —
  /// captured once at onboarding (`ScannedDevicesScreen`'s setup form) and
  /// persisted so screens can open a `camera_api` `CameraConnection` without
  /// re-prompting for credentials. Null means this camera predates
  /// onboarding-time credential capture, or a scan-only stub camera whose
  /// setup flow hasn't actually run yet.
  final String? host;
  final String? username;
  final String? password;

  /// AWS IoT thing name — populated once `OnvifDeviceClient.getSerialNumber`
  /// resolves it at onboarding (see `CameraConnection.thingName`'s doc).
  final String? thingName;

  /// Whether this camera supports WAN live view, per `CapabilitiesClient`
  /// (queried once at onboarding). Null means unknown, not unsupported — see
  /// `CameraConnection.wanLiveViewCapable`'s doc for why that distinction
  /// matters to live-view fallback logic.
  final bool? wanLiveViewCapable;

  /// Whether this camera can receive AWS IoT/MQTT commands at all, per
  /// `CapabilitiesClient` (queried once at onboarding, same as
  /// [wanLiveViewCapable]). Null means unknown, not unsupported.
  final bool? wanCommandCapable;

  /// Hardware deterrence capability flags from `CapabilitiesClient`, queried
  /// once at onboarding. Null means unknown (not yet synced), not
  /// unsupported — UI that gates on these should only hide/disable a control
  /// when the flag is definitively `false`, the same `!= false` treatment
  /// [wanLiveViewCapable] already gets in `LiveViewController`.
  final bool? sirenCapable;
  final bool? spotlightCapable;
  final bool? warningCapable;

  /// Which transport the live-view session for this camera most recently
  /// confirmed a real connection over — `true` = WAN, `false` = LAN, `null`
  /// = not yet known (never successfully connected this app session).
  /// Written only by `CameraLiveScreen` on an actual successful connect
  /// (see `_syncLastKnownTransport`), per
  /// `.claude/rules/mobile-app-screen-conventions.md`'s "Whatever component
  /// negotiates live view should track the most recently confirmed
  /// transport and thread it down to any settings screen opened from
  /// there." Every settings screen reads this (already has `camera` in
  /// hand) to call the correct transport directly instead of always trying
  /// LAN first and paying its full timeout before falling back to WAN.
  final bool? lastKnownWan;

  /// The following four fields are `GetDeviceHealth`'s real telemetry
  /// (`HealthClient`/`WanHealthClient`, `packages/camera_api`), synced by
  /// `syncCameraFromDevice` — added 2026-09-08, closing the `ui-api-gap-audit`
  /// "Health section is real client code, not wired" finding: this section
  /// previously only ever showed storage-derived conditions
  /// ([healthConditionMessages]), never anything from the camera's actual
  /// `GetDeviceHealth` response. Null means "not yet synced" for all four,
  /// same null-means-unknown convention this model already uses elsewhere.
  final int? rebootCount;

  /// UTC epoch seconds of the camera's last reboot.
  final int? lastRebootUtc;
  final int? uptimeSeconds;

  /// True only when the camera itself reports its clock as unsynced
  /// (`HealthStatus.clockSyncState == ClockSyncState.uncertain`) — a real
  /// health condition (timestamps on recordings/events become unreliable),
  /// surfaced via [healthConditionMessages] same as a storage failure.
  final bool? clockSyncUncertain;

  /// Builds a [CameraConnection] from this camera's saved credentials, or
  /// null if it doesn't have any yet (see [host]'s doc).
  ///
  /// **Real bug fix, 2026-09-15**: never threaded [wanCommandCapable] through
  /// (only [wanLiveViewCapable] was) — every `connection.wanCommandCapable`
  /// read (`camera_sync.dart`'s `syncCameraFromDevice`, `camera_info_screen
  /// .dart`'s WAN-eligibility checks) always saw `null` regardless of what
  /// `CapabilitiesClient.getCapabilities()` actually confirmed, silently
  /// disabling their "skip WAN once we know this camera doesn't support it"
  /// optimization — those calls just kept attempting (and failing/timing
  /// out) a WAN command round trip forever on a camera that had already
  /// reported it can't take one.
  CameraConnection? get connection {
    if (host == null || username == null || password == null) return null;
    return CameraConnection(
      host: host!,
      username: username!,
      password: password!,
      thingName: thingName,
      wanLiveViewCapable: wanLiveViewCapable,
      wanCommandCapable: wanCommandCapable,
      macAddress: macAddress == '—' ? null : macAddress,
    );
  }

  /// This camera's encoder settings for [stream] as a uniform
  /// [StreamEncoderConfig], hiding that [VideoStream.highRes] is stored in
  /// the top-level fields while the other two are stored as objects.
  StreamEncoderConfig encoderConfigFor(VideoStream stream) => switch (stream) {
    VideoStream.highRes => StreamEncoderConfig(
      resolution: videoResolution,
      encoderType: encoderType,
      encoderProfile: encoderProfile,
      frameRate: frameRate,
      govLength: govLength,
      quality: encoderQuality,
      bitrateMode: bitrateMode,
      bitrateKbps: bitrateKbps,
    ),
    VideoStream.medium => mediumStreamEncoder,
    VideoStream.low => lowStreamEncoder,
  };

  /// A copy of this camera with [stream]'s encoder settings replaced by
  /// [config] — the write-side counterpart to [encoderConfigFor].
  Camera copyWithEncoderConfig(
    VideoStream stream,
    StreamEncoderConfig config,
  ) => switch (stream) {
    VideoStream.highRes => copyWith(
      videoResolution: config.resolution,
      encoderType: config.encoderType,
      encoderProfile: config.encoderProfile,
      frameRate: config.frameRate,
      govLength: config.govLength,
      encoderQuality: config.quality,
      bitrateMode: config.bitrateMode,
      bitrateKbps: config.bitrateKbps,
    ),
    VideoStream.medium => copyWith(mediumStreamEncoder: config),
    VideoStream.low => copyWith(lowStreamEncoder: config),
  };

  /// Free local storage in GB, derived from [sdCardCapacityGb] minus
  /// [sdCardUsedGb]. Zero (not negative) if the card is disabled/absent.
  double get sdCardFreeGb {
    if (!sdStorageEnabled || !sdCardPresent) return 0;
    final free = sdCardCapacityGb - sdCardUsedGb;
    return free < 0 ? 0 : free;
  }

  /// Approximate remaining local recording time at the camera's current
  /// encoder bitrate ([bitrateKbps]), based on [sdCardFreeGb]. Used by both
  /// the Storage and Recording screens so the estimate stays consistent
  /// between them.
  Duration get estimatedRecordingTimeRemaining {
    if (sdCardFreeGb <= 0 || bitrateKbps <= 0) return Duration.zero;
    final freeBits = sdCardFreeGb * 1e9 * 8;
    final seconds = freeBits / (bitrateKbps * 1000);
    return Duration(seconds: seconds.round());
  }

  /// Plain-language messages for every currently-open health condition on
  /// this camera. Empty means healthy. Drives [needsAttention]/[liveStatus]
  /// and the Health section on Camera Info.
  List<String> get healthConditionMessages {
    final messages = <String>[];
    final storageMessage = storageFailure.message;
    if (storageMessage != null) messages.add(storageMessage);
    if (sdCardPresent && sdCardHealthPercent < 50) {
      messages.add('SD card wearing out — consider replacing soon');
    }
    // Real `GetDeviceHealth` condition (`HealthClient`/`WanHealthClient`) —
    // an unsynced camera clock makes recording/event timestamps unreliable.
    if (clockSyncUncertain == true) {
      messages.add(
        'Camera clock not synced — recording timestamps may be wrong',
      );
    }
    return messages;
  }

  bool get needsAttention => healthConditionMessages.isNotEmpty;

  /// Overall status for live-view/dashboard badges: offline takes priority
  /// over health conditions, which take priority over plain "online".
  CameraLiveStatus get liveStatus {
    if (!isOnline) return CameraLiveStatus.offline;
    return needsAttention
        ? CameraLiveStatus.needsAttention
        : CameraLiveStatus.online;
  }

  /// [room] uses an explicit presence flag ([setRoom]) rather than the usual
  /// `x ?? this.x` pattern so callers can clear the room (set it to null),
  /// e.g. when the room a camera belonged to is deleted.
  Camera copyWith({
    String? name,
    bool? isOnline,
    bool? isFavorite,
    bool? isPinned,
    String? room,
    bool setRoom = false,
    String? thumbnailUrl,
    DateTime? lastSeen,
    String? timezone,
    String? location,
    RecordingStatus? recordingStatus,
    List<RecordingScheduleWindow>? recordingScheduleWindows,
    String? wifiNetwork,
    String? ipAddress,
    int? signalStrength,
    double? networkSpeedKbps,
    String? macAddress,
    String? manufacturer,
    String? model,
    String? firmwareVersion,
    String? serialNumber,
    String? hardwareId,
    String? host,
    String? username,
    String? password,
    String? thingName,
    bool? wanLiveViewCapable,
    bool? wanCommandCapable,
    bool? lastKnownWan,
    bool? sirenCapable,
    bool? spotlightCapable,
    bool? warningCapable,
    int? rebootCount,
    int? lastRebootUtc,
    int? uptimeSeconds,
    bool? clockSyncUncertain,
    bool? bitrateOsdEnabled,
    OsdCorner? bitrateOsdPosition,
    bool? signalStrengthOsdEnabled,
    OsdCorner? signalStrengthOsdPosition,
    bool? liveTagOsdEnabled,
    CameraStreamQuality? streamQuality,
    String? preferredLanProfileToken,
    CameraVideoMode? videoMode,
    CameraNightMode? nightMode,
    bool? nightVisionColorCapable,
    bool? nightVisionSmartCapable,
    CameraPrivacyMode? privacyMode,
    List<DrawableZone>? privacyZones,
    CameraMirrorFlip? mirrorFlip,
    CameraAntiFlickerMode? antiFlickerMode,
    double? brightness,
    double? contrast,
    double? saturation,
    double? sharpness,
    bool? wdrEnabled,
    double? wdrLevel,
    CameraAutoManual? whiteBalance,
    CameraAutoManual? exposure,
    double? exposureTime,
    double? exposureGain,
    Resolution? videoResolution,
    CameraEncoderType? encoderType,
    CameraEncoderProfile? encoderProfile,
    double? frameRate,
    double? govLength,
    double? encoderQuality,
    CameraBitrateMode? bitrateMode,
    double? bitrateKbps,
    StreamEncoderConfig? mediumStreamEncoder,
    StreamEncoderConfig? lowStreamEncoder,
    bool? motionDetectionEnabled,
    double? motionSensitivity,
    bool? intrusionDetectionEnabled,
    double? intrusionSensitivity,
    List<DrawableZone>? intrusionZones,
    bool? lineCrossingEnabled,
    double? lineCrossingSensitivity,
    Offset? lineCrossingStart,
    Offset? lineCrossingEnd,
    CameraCrossingDirection? lineCrossingDirection,
    bool? personDetectionEnabled,
    double? personDetectionConfidence,
    List<PolygonZone>? personDetectionZones,
    int? loiteringDurationSeconds,
    bool? bboxOverlayEnabled,
    bool? vehicleDetectionEnabled,
    double? vehicleDetectionConfidence,
    bool? parkingMonitoringEnabled,
    List<ParkingZone>? parkingZones,
    int? parkingRestrictedDwellSeconds,
    int? parkingWrongBayDwellSeconds,
    double? speakerVolume,
    double? micGain,
    bool? audioRecordingEnabled,
    bool? sdStorageEnabled,
    bool? sdCardPresent,
    double? sdCardCapacityGb,
    double? sdCardUsedGb,
    double? sdCardHealthPercent,
    bool? sdCardEnduranceRated,
    int? retentionDays,
    StorageFailure? storageFailure,
  }) {
    return Camera(
      id: id,
      name: name ?? this.name,
      isOnline: isOnline ?? this.isOnline,
      room: setRoom ? room : this.room,
      isFavorite: isFavorite ?? this.isFavorite,
      isPinned: isPinned ?? this.isPinned,
      thumbnailUrl: thumbnailUrl ?? this.thumbnailUrl,
      lastSeen: lastSeen ?? this.lastSeen,
      timezone: timezone ?? this.timezone,
      location: location ?? this.location,
      recordingStatus: recordingStatus ?? this.recordingStatus,
      recordingScheduleWindows:
          recordingScheduleWindows ?? this.recordingScheduleWindows,
      wifiNetwork: wifiNetwork ?? this.wifiNetwork,
      ipAddress: ipAddress ?? this.ipAddress,
      signalStrength: signalStrength ?? this.signalStrength,
      networkSpeedKbps: networkSpeedKbps ?? this.networkSpeedKbps,
      macAddress: macAddress ?? this.macAddress,
      manufacturer: manufacturer ?? this.manufacturer,
      model: model ?? this.model,
      firmwareVersion: firmwareVersion ?? this.firmwareVersion,
      serialNumber: serialNumber ?? this.serialNumber,
      hardwareId: hardwareId ?? this.hardwareId,
      host: host ?? this.host,
      username: username ?? this.username,
      password: password ?? this.password,
      thingName: thingName ?? this.thingName,
      wanLiveViewCapable: wanLiveViewCapable ?? this.wanLiveViewCapable,
      wanCommandCapable: wanCommandCapable ?? this.wanCommandCapable,
      lastKnownWan: lastKnownWan ?? this.lastKnownWan,
      sirenCapable: sirenCapable ?? this.sirenCapable,
      spotlightCapable: spotlightCapable ?? this.spotlightCapable,
      warningCapable: warningCapable ?? this.warningCapable,
      rebootCount: rebootCount ?? this.rebootCount,
      lastRebootUtc: lastRebootUtc ?? this.lastRebootUtc,
      uptimeSeconds: uptimeSeconds ?? this.uptimeSeconds,
      clockSyncUncertain: clockSyncUncertain ?? this.clockSyncUncertain,
      bitrateOsdEnabled: bitrateOsdEnabled ?? this.bitrateOsdEnabled,
      bitrateOsdPosition: bitrateOsdPosition ?? this.bitrateOsdPosition,
      signalStrengthOsdEnabled:
          signalStrengthOsdEnabled ?? this.signalStrengthOsdEnabled,
      signalStrengthOsdPosition:
          signalStrengthOsdPosition ?? this.signalStrengthOsdPosition,
      liveTagOsdEnabled: liveTagOsdEnabled ?? this.liveTagOsdEnabled,
      streamQuality: streamQuality ?? this.streamQuality,
      preferredLanProfileToken:
          preferredLanProfileToken ?? this.preferredLanProfileToken,
      videoMode: videoMode ?? this.videoMode,
      nightMode: nightMode ?? this.nightMode,
      nightVisionColorCapable:
          nightVisionColorCapable ?? this.nightVisionColorCapable,
      nightVisionSmartCapable:
          nightVisionSmartCapable ?? this.nightVisionSmartCapable,
      privacyMode: privacyMode ?? this.privacyMode,
      privacyZones: privacyZones ?? this.privacyZones,
      mirrorFlip: mirrorFlip ?? this.mirrorFlip,
      antiFlickerMode: antiFlickerMode ?? this.antiFlickerMode,
      brightness: brightness ?? this.brightness,
      contrast: contrast ?? this.contrast,
      saturation: saturation ?? this.saturation,
      sharpness: sharpness ?? this.sharpness,
      wdrEnabled: wdrEnabled ?? this.wdrEnabled,
      wdrLevel: wdrLevel ?? this.wdrLevel,
      whiteBalance: whiteBalance ?? this.whiteBalance,
      exposure: exposure ?? this.exposure,
      exposureTime: exposureTime ?? this.exposureTime,
      exposureGain: exposureGain ?? this.exposureGain,
      videoResolution: videoResolution ?? this.videoResolution,
      encoderType: encoderType ?? this.encoderType,
      encoderProfile: encoderProfile ?? this.encoderProfile,
      frameRate: frameRate ?? this.frameRate,
      govLength: govLength ?? this.govLength,
      encoderQuality: encoderQuality ?? this.encoderQuality,
      bitrateMode: bitrateMode ?? this.bitrateMode,
      bitrateKbps: bitrateKbps ?? this.bitrateKbps,
      mediumStreamEncoder: mediumStreamEncoder ?? this.mediumStreamEncoder,
      lowStreamEncoder: lowStreamEncoder ?? this.lowStreamEncoder,
      motionDetectionEnabled:
          motionDetectionEnabled ?? this.motionDetectionEnabled,
      motionSensitivity: motionSensitivity ?? this.motionSensitivity,
      intrusionDetectionEnabled:
          intrusionDetectionEnabled ?? this.intrusionDetectionEnabled,
      intrusionSensitivity: intrusionSensitivity ?? this.intrusionSensitivity,
      intrusionZones: intrusionZones ?? this.intrusionZones,
      lineCrossingEnabled: lineCrossingEnabled ?? this.lineCrossingEnabled,
      lineCrossingSensitivity:
          lineCrossingSensitivity ?? this.lineCrossingSensitivity,
      lineCrossingStart: lineCrossingStart ?? this.lineCrossingStart,
      lineCrossingEnd: lineCrossingEnd ?? this.lineCrossingEnd,
      lineCrossingDirection:
          lineCrossingDirection ?? this.lineCrossingDirection,
      personDetectionEnabled:
          personDetectionEnabled ?? this.personDetectionEnabled,
      personDetectionConfidence:
          personDetectionConfidence ?? this.personDetectionConfidence,
      personDetectionZones: personDetectionZones ?? this.personDetectionZones,
      loiteringDurationSeconds:
          loiteringDurationSeconds ?? this.loiteringDurationSeconds,
      bboxOverlayEnabled: bboxOverlayEnabled ?? this.bboxOverlayEnabled,
      vehicleDetectionEnabled:
          vehicleDetectionEnabled ?? this.vehicleDetectionEnabled,
      vehicleDetectionConfidence:
          vehicleDetectionConfidence ?? this.vehicleDetectionConfidence,
      parkingMonitoringEnabled:
          parkingMonitoringEnabled ?? this.parkingMonitoringEnabled,
      parkingZones: parkingZones ?? this.parkingZones,
      parkingRestrictedDwellSeconds:
          parkingRestrictedDwellSeconds ?? this.parkingRestrictedDwellSeconds,
      parkingWrongBayDwellSeconds:
          parkingWrongBayDwellSeconds ?? this.parkingWrongBayDwellSeconds,
      speakerVolume: speakerVolume ?? this.speakerVolume,
      micGain: micGain ?? this.micGain,
      audioRecordingEnabled:
          audioRecordingEnabled ?? this.audioRecordingEnabled,
      sdStorageEnabled: sdStorageEnabled ?? this.sdStorageEnabled,
      sdCardPresent: sdCardPresent ?? this.sdCardPresent,
      sdCardCapacityGb: sdCardCapacityGb ?? this.sdCardCapacityGb,
      sdCardUsedGb: sdCardUsedGb ?? this.sdCardUsedGb,
      sdCardHealthPercent: sdCardHealthPercent ?? this.sdCardHealthPercent,
      sdCardEnduranceRated: sdCardEnduranceRated ?? this.sdCardEnduranceRated,
      retentionDays: retentionDays ?? this.retentionDays,
      storageFailure: storageFailure ?? this.storageFailure,
    );
  }
}
