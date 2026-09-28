/// `FR-CF-046`/`FR-NE-088`/`FR-MOB-084`: local SD recording mode — shared by
/// `RecordingModeClient` (LAN) and `WanRecordingModeClient` (WAN), since both transports report
/// the identical field set. Mirrors `design/Camera-REST-API.md`'s
/// `/nuraeye/recordings/mode` wire vocabulary exactly.
enum RecordingMode {
  continuous('continuous'),
  scheduled('scheduled'),
  eventTriggered('event_triggered');

  const RecordingMode(this.wireValue);

  final String wireValue;

  static RecordingMode? fromWireValue(String? value) => switch (value) {
    'continuous' => RecordingMode.continuous,
    'scheduled' => RecordingMode.scheduled,
    'event_triggered' => RecordingMode.eventTriggered,
    _ => null,
  };
}

/// One weekly recording window (`FR-CF-045`) — `dayOfWeek` is `0`=Sunday..`6`=Saturday;
/// `startMinute`/`endMinute` are minutes since local midnight (`0`-`1439`), no overnight wrap —
/// express an overnight window as two entries instead, per the firmware's own documented
/// convention (`design/Camera-REST-API.md`'s `/nuraeye/recordings/mode` entry).
///
/// Real equality (not identity) so `RecordingModeSettingsScreen`'s pending-vs-applied schedule
/// comparison works — see `.claude/rules/mobile-app-screen-conventions.md`'s "Settings/control
/// screen UX conventions" item 5.
class RecordingScheduleWindow {
  const RecordingScheduleWindow({
    required this.dayOfWeek,
    required this.startMinute,
    required this.endMinute,
  });

  final int dayOfWeek;
  final int startMinute;
  final int endMinute;

  RecordingScheduleWindow copyWith({
    int? dayOfWeek,
    int? startMinute,
    int? endMinute,
  }) => RecordingScheduleWindow(
    dayOfWeek: dayOfWeek ?? this.dayOfWeek,
    startMinute: startMinute ?? this.startMinute,
    endMinute: endMinute ?? this.endMinute,
  );

  @override
  bool operator ==(Object other) =>
      other is RecordingScheduleWindow &&
      other.dayOfWeek == dayOfWeek &&
      other.startMinute == startMinute &&
      other.endMinute == endMinute;

  @override
  int get hashCode => Object.hash(dayOfWeek, startMinute, endMinute);

  @override
  String toString() =>
      'RecordingScheduleWindow(dayOfWeek: $dayOfWeek, startMinute: $startMinute, endMinute: $endMinute)';
}

/// `GetRecordingMode`'s full response — current mode, its schedule (only meaningful for
/// [RecordingMode.scheduled], reported empty otherwise), and whether at least one detection
/// trigger source is configured (`FR-CF-047`, only meaningful for
/// [RecordingMode.eventTriggered] — see `FR-MOB-086`'s no-trigger-source warning).
class RecordingModeStatus {
  const RecordingModeStatus({
    required this.mode,
    required this.schedule,
    required this.eventTriggerSourceConfigured,
  });

  final RecordingMode mode;
  final List<RecordingScheduleWindow> schedule;
  final bool eventTriggerSourceConfigured;

  @override
  bool operator ==(Object other) =>
      other is RecordingModeStatus &&
      other.mode == mode &&
      other.eventTriggerSourceConfigured == eventTriggerSourceConfigured &&
      _listEquals(other.schedule, schedule);

  @override
  int get hashCode =>
      Object.hash(mode, eventTriggerSourceConfigured, Object.hashAll(schedule));
}

bool _listEquals(List<RecordingScheduleWindow> a, List<RecordingScheduleWindow> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
