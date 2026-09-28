/// `FR-NE-117`: one recorded clip, as reported by `GET /nuraeye/recordings`.
class RecordingClip {
  const RecordingClip({
    required this.id,
    required this.start,
    required this.end,
    required this.sizeBytes,
    required this.active,
    this.trigger,
  });

  /// UTC epoch seconds, clip start time. Pass to `GET /nuraeye/recordings/{id}/clip`
  /// ([RecordingsClient.clipUri]) to play or download this clip.
  final int id;

  /// UTC epoch seconds.
  final int start;

  /// UTC epoch seconds.
  final int end;

  /// Not final while [active] is true — the camera is still writing this segment.
  final int sizeBytes;

  /// True if this is the segment the camera is currently recording to.
  final bool active;

  /// Present only when a matching event was found in the camera's recent (last ~100 events,
  /// RAM-only, does not survive a reboot) alert history — see `FR-NE-117`'s own doc for why.
  /// Absence does not mean nothing happened during this clip, just that it's outside that
  /// window. One of the wire event-name strings this app already uses elsewhere (e.g.
  /// `"PersonDetected"`), not a free-form description.
  final String? trigger;
}

/// `FR-NE-117`: `GET /nuraeye/recordings`'s full response.
class RecordingsList {
  const RecordingsList({
    required this.storageAvailable,
    required this.cardPresent,
    required this.truncated,
    required this.clips,
  });

  /// Capability + presence, mirroring `LocalStorageStatus`'s own two-independent-facts split
  /// (`FR-CF-044`) — a genuinely unreachable camera never produces any response at all, so
  /// these are the only two states this call itself can report.
  final bool storageAvailable;
  final bool cardPresent;

  /// True if more clips exist in the requested range than this one response's fixed-size JSON
  /// buffer could fit (not a clip-count cap) — real bug found 2026-09-24: a naive single-call
  /// `getRecordings()` with no `start`/`end` bound fills this buffer with the *oldest* matching
  /// clips first, so once a camera has accumulated enough history, genuinely new clips can be
  /// silently cut off entirely, never appearing in the response at all. Page forward with
  /// `start = <last-returned clip's start> + 1` and keep requesting until `truncated` comes back
  /// `false` — see [RecordingsClient.getAllRecordings] for a client that does this
  /// automatically, and prefer it over a bare [RecordingsClient.getRecordings] call for any
  /// screen that needs a complete, current list.
  final bool truncated;

  final List<RecordingClip> clips;
}
