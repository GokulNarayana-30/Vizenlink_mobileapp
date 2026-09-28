/// `FR-HLT-009` (Stage 3, first slice, extended 2026-08-26): camera health/vitals — shared by
/// `HealthClient` (LAN) and `WanHealthClient` (WAN), since both transports report the identical
/// field set.
///
/// [lastRebootUtc] reads `0` until the camera's first NTP sync of the current boot corrects it
/// (no battery-backed RTC — every boot's clock starts uncertain by definition, see `FR-CF-114`)
/// — `0` therefore means "not yet corrected this boot," not "camera has never booted."
///
/// [clockSyncState]/[uncertainSince] mirror `FR-HLT-022`'s status half — only two states exist
/// (`synced`/`uncertain`), not a third "free-running since boot" sub-state, since the camera's
/// BSP layer doesn't distinguish that from a full sync.
///
/// [firmwareVersion] duplicates what `OnvifDeviceClient.getDeviceInformation()` already reports
/// — included here too so one health call covers full vitals without a second round trip.
///
/// This is `FR-HLT-009`'s first slice only — a reboot-loop flag and AI-model version are not
/// implemented yet, and last-recording-segment timestamp isn't either.
///
/// [rebootReason] (`BUG-048` follow-up, added 2026-09-25) is why the CURRENT boot happened —
/// e.g. `"Firmware Upgrade"`, `"Factory Reset"`, `"HTTP Server Failure"`, `"Manual Reboot"`,
/// `"WiFi Provisioning"`, `"Sensor Capture Mode Change"`, or `"Unknown / Crash"` for a genuine,
/// uncontrolled crash/hard-WDT-timeout — the camera has no code path left to run at the moment
/// of a real crash, so that value isn't detected specially; it's simply what's left over when no
/// deliberate reboot call site got a chance to set something more specific first. Free-text on
/// the wire (not a closed enum) — new reasons can be added camera-side without an app update;
/// treat any unrecognized string as informational, never branch app logic on its exact value.
enum ClockSyncState { synced, uncertain }

class HealthStatus {
  const HealthStatus({
    required this.rebootCount,
    required this.lastRebootUtc,
    required this.rebootReason,
    required this.uptimeSeconds,
    required this.clockSyncState,
    required this.uncertainSince,
    required this.firmwareVersion,
  });

  final int rebootCount;
  final int lastRebootUtc;

  /// See this class's own doc comment. Empty string on firmware too old to report it.
  final String rebootReason;
  final int uptimeSeconds;
  final ClockSyncState clockSyncState;

  /// UTC epoch seconds the clock became uncertain; `0` if [clockSyncState] is
  /// [ClockSyncState.synced].
  final int uncertainSince;
  final String firmwareVersion;
}
