import 'package:camera_api/camera_api.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../app_state/homes_controller.dart';
import '../../models/camera.dart';
import '../../widgets/glass_card.dart';
import '../../widgets/gradient_background.dart';
import '../../widgets/saving_overlay.dart';
import 'recording_screen.dart';

/// Storage config + recorded-clip browsing, merged into one tabbed screen —
/// matching the sibling `nuraeye-rt` app's own `StorageRecordingsScreen`
/// structure (direct user request, 2026-09-07: "keep storage recording
/// option same as that app") — a single `Scaffold`/`AppBar` with a `TabBar`
/// (`Storage` / `Recordings`), rather than two separate screens.
///
/// **The Storage tab is real, 2026-09-07** (direct follow-up request: "it
/// need to contain local sd storage and sd card present and its capacity,
/// record to sd card toggle each clip duration slider 1 min to 5min") —
/// replacing the earlier version's mocked `Camera`-model fields
/// (capacity/health/retention/deletion-history, none backed by a real API)
/// entirely: SD-card presence + capacity/free-space and the "Record to SD
/// Card" toggle now come from `LocalStorageClient.getStatus()`/`setEnabled()`
/// (`FR-CF-044`), and clip duration is `RecordingsClient.getClipDuration()`/
/// `setClipDuration()` bounded by `CapabilitiesClient`'s real
/// `recordingClipDurationMinSeconds`/`MaxSeconds` (moved here from
/// [recording_screen.md](../../../docs/screens/camera_settings/recording_and_storage/recording_screen.md)'s
/// former REC-014/015/016, which duplicated this once both existed —
/// `RecordingScreen` now only owns Mode/Schedule). Each control follows this
/// app's local-pending/explicit-Apply convention independently, since
/// they're real network round trips, not locally-staged values behind one
/// screen-wide Save button — there is no STOR-002 Save button any more.
///
/// The `Recordings` tab ([_RecordingsTab]) is real: `RecordingsClient`-backed
/// clip list + delete, grouped by day.
class StorageScreen extends StatefulWidget {
  const StorageScreen({
    super.key,
    required this.camera,
    required this.homesController,
  });

  static const routeName = 'storage';

  final Camera camera;
  final HomesController homesController;

  @override
  State<StorageScreen> createState() => _StorageScreenState();
}

class _StorageScreenState extends State<StorageScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this)
      ..addListener(() {
        if (!_tabController.indexIsChanging) setState(() {});
      });
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final camera = widget.camera;

    return GradientBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          key: const Key('STOR-001'),
          title: const Text('Storage & Recordings'),
          bottom: TabBar(
            key: const Key('STOR-018'),
            controller: _tabController,
            tabs: const [
              Tab(text: 'Storage'),
              Tab(text: 'Recordings'),
            ],
          ),
        ),
        body: TabBarView(
          controller: _tabController,
          children: [
            _StorageTab(connection: camera.connection, camera: camera),
            _RecordingsTab(connection: camera.connection),
          ],
        ),
      ),
    );
  }
}

/// STOR-018's "Storage" tab — see [StorageScreen]'s own doc for what changed
/// 2026-09-07. Loads `LocalStorageClient.getStatus()` and (in parallel)
/// `CapabilitiesClient.getCapabilities()` + `RecordingsClient.getClipDuration()`
/// on open; each section applies independently.
class _StorageTab extends StatefulWidget {
  const _StorageTab({required this.connection, required this.camera});

  final CameraConnection? connection;
  final Camera camera;

  @override
  State<_StorageTab> createState() => _StorageTabState();
}

class _StorageTabState extends State<_StorageTab> {
  NuraeyeClient? _nuraeye;
  LocalStorageClient? _localStorage;
  RecordingsClient? _recordings;

  bool _isLoading = true;
  String? _loadError;
  LocalStorageStatus? _status;

  bool _isApplyingEnabled = false;

  int _clipDurationMinSeconds = 0;
  int _clipDurationMaxSeconds = 0;
  int? _appliedClipDurationSeconds;
  int? _pendingClipDurationSeconds;
  bool _isApplyingClipDuration = false;

  @override
  void initState() {
    super.initState();
    final connection = widget.connection;
    if (connection != null) {
      final nuraeye = NuraeyeClient(connection);
      _nuraeye = nuraeye;
      _localStorage = LocalStorageClient(nuraeye);
      _recordings = RecordingsClient(nuraeye);
      _load();
    } else {
      _isLoading = false;
    }
  }

  @override
  void dispose() {
    _recordings?.closeDownloadClient();
    _nuraeye?.close();
    super.dispose();
  }

  Future<void> _load() async {
    final nuraeye = _nuraeye;
    final localStorage = _localStorage;
    final recordings = _recordings;
    if (nuraeye == null || localStorage == null || recordings == null) return;
    setState(() {
      _isLoading = true;
      _loadError = null;
    });
    final results = await Future.wait([
      localStorage.getStatus(),
      CapabilitiesClient(nuraeye).getCapabilities(),
      recordings.getClipDuration(),
    ]);
    if (!mounted) return;
    var statusResult = results[0] as CameraResult<LocalStorageStatus>;
    final capabilitiesResult = results[1] as CameraResult<CameraCapabilities>;
    final durationResult = results[2] as CameraResult<int>;

    // Real gap fixed 2026-09-15: `WanLocalStorageClient` existed
    // (`FR-MOB-083`) but was never actually called anywhere — this screen
    // was LAN-only, so a camera off the phone's current LAN showed "could
    // not load storage status" instead of falling back to WAN like every
    // other settings screen in this app.
    final thingName = widget.connection?.thingName;
    if (statusResult is! CameraSuccess && thingName != null) {
      statusResult = await WanLocalStorageClient(thingName).getStatus();
    }

    String? error;
    setState(() {
      switch (statusResult) {
        case CameraSuccess(:final value):
          _status = value;
        case CameraFailure(:final reason):
          error = reason;
        case CameraTimeout():
          error = 'Timed out';
      }
      if (capabilitiesResult case CameraSuccess(:final value)) {
        _clipDurationMinSeconds = value.recordingClipDurationMinSeconds;
        _clipDurationMaxSeconds = value.recordingClipDurationMaxSeconds;
      }
      if (durationResult case CameraSuccess(:final value)) {
        _appliedClipDurationSeconds = value;
        _pendingClipDurationSeconds = value;
      }
      _isLoading = false;
      _loadError = error;
    });
  }

  /// Turning **off** asks for confirmation first (stops future recording,
  /// doesn't erase what's already on the card) — matching the sibling
  /// `nuraeye-rt` app's own `StorageSettingsScreen._onToggle` exactly.
  /// Turning on does not. Applied directly (no separate local-pending
  /// value) — `LocalStorageStatus.enabled` itself is the toggle's value,
  /// re-fetched after a successful `setEnabled` rather than optimistically
  /// assumed, same as that screen's `_setEnabled`/`_loadStatus` pair.
  Future<void> _onToggle(bool next) async {
    if (!next) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Turn off local recording?'),
          content: const Text(
            'This stops recording new footage to the SD card going '
            'forward. Footage already on the card is not erased.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Turn Off'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
    }
    await _applyEnabled(next);
  }

  Future<void> _applyEnabled(bool value) async {
    final localStorage = _localStorage;
    if (localStorage == null) return;
    setState(() => _isApplyingEnabled = true);
    var result = await localStorage.setEnabled(value);
    // Same WAN-fallback fix as `_load` — a LAN Set failure retries over WAN
    // before surfacing an error, per this app's own LAN/WAN convention.
    final thingName = widget.connection?.thingName;
    if (result is! CameraSuccess && thingName != null) {
      result = await WanLocalStorageClient(thingName).setEnabled(value);
    }
    if (!mounted) return;
    setState(() => _isApplyingEnabled = false);
    switch (result) {
      case CameraSuccess():
        await _load();
      case CameraFailure(:final reason):
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Could not update: $reason')));
      case CameraTimeout():
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Timed out — try again')));
    }
  }

  Future<void> _applyClipDuration() async {
    final recordings = _recordings;
    final pending = _pendingClipDurationSeconds;
    if (recordings == null || pending == null) return;
    setState(() => _isApplyingClipDuration = true);
    final result = await recordings.setClipDuration(pending);
    if (!mounted) return;
    setState(() => _isApplyingClipDuration = false);
    switch (result) {
      case CameraSuccess():
        setState(() => _appliedClipDurationSeconds = pending);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Clip duration updated')));
      case CameraFailure(:final reason):
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Could not update: $reason')));
      case CameraTimeout():
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Timed out — try again')));
    }
  }

  void _resetClipDuration() {
    setState(() => _pendingClipDurationSeconds = _appliedClipDurationSeconds);
  }

  /// Matches the sibling `nuraeye-rt` app's own `_formatBytes` exactly —
  /// GB (1 decimal) once the value reaches a full gigabyte, else MB (whole
  /// number), else a raw byte count for anything smaller still.
  String _formatBytes(int bytes) {
    const gb = 1024 * 1024 * 1024;
    const mb = 1024 * 1024;
    if (bytes >= gb) return '${(bytes / gb).toStringAsFixed(1)} GB';
    if (bytes >= mb) return '${(bytes / mb).toStringAsFixed(0)} MB';
    return '$bytes B';
  }

  String _formatClipDuration(int seconds) {
    if (seconds < 60) return '${seconds}s';
    final minutes = seconds ~/ 60;
    final remainder = seconds % 60;
    return remainder == 0 ? '${minutes}m' : '${minutes}m ${remainder}s';
  }

  @override
  Widget build(BuildContext context) {
    if (widget.connection == null) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Add this camera\'s IP address in Settings to view storage.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    if (_isLoading) return const Center(child: CircularProgressIndicator());
    if (_loadError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Could not load storage status: $_loadError'),
              const SizedBox(height: 8),
              TextButton(onPressed: _load, child: const Text('Retry')),
            ],
          ),
        ),
      );
    }

    final status = _status;
    final hasClipDurationBounds =
        _clipDurationMaxSeconds > _clipDurationMinSeconds;

    return SavingOverlay(
      isSaving: _isApplyingEnabled || _isApplyingClipDuration,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          GlassCard(
            padding: EdgeInsets.zero,
            child: ListTile(
              key: const Key('STOR-021'),
              leading: const Icon(Icons.fiber_manual_record_outlined),
              title: const Text('Recording Mode & Schedule'),
              subtitle: const Text('Continuous / Scheduled / Event-Triggered'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {
                final location = GoRouterState.of(context).matchedLocation;
                context.push(
                  '${location.substring(0, location.lastIndexOf('/'))}/${RecordingScreen.routeName}',
                  extra: widget.camera,
                );
              },
            ),
          ),
          const SizedBox(height: 24),
          // Card layout/icons/copy matches the sibling `nuraeye-rt` app's
          // own `StorageSettingsScreen._buildContent` exactly, per direct
          // user request ("check my senior app how he have that").
          GlassCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.sd_storage_outlined),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Text('Local SD Storage', key: Key('STOR-004')),
                    ),
                    IconButton(
                      key: const Key('STOR-024'),
                      icon: const Icon(Icons.refresh),
                      tooltip: 'Reload',
                      onPressed: _load,
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Icon(
                      status != null && status.cardPresent
                          ? Icons.check_circle_outline
                          : Icons.error_outline,
                      size: 16,
                      color: status != null && status.cardPresent
                          ? Colors.green
                          : Theme.of(context).colorScheme.error,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      key: const Key('STOR-022'),
                      status != null && status.cardPresent
                          ? 'SD card present'
                          : 'No SD card present',
                    ),
                  ],
                ),
                if (status == null || !status.cardPresent) ...[
                  const SizedBox(height: 8),
                  Text(
                    'Insert an SD card to enable local recording.',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ] else ...[
                  const SizedBox(height: 8),
                  Text(
                    key: const Key('STOR-023'),
                    'Capacity: ${_formatBytes(status.capacityBytes)} · '
                    'Free: ${_formatBytes(status.freeBytes)}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 8),
                  SwitchListTile(
                    key: const Key('STOR-003'),
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Record to SD card'),
                    value: status.enabled,
                    onChanged: _onToggle,
                  ),
                  Text(
                    'Recording requires an SD card to remain inserted. If '
                    'the card is removed while enabled, recording stops '
                    'until it is reinserted.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.outline,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 24),
          Text(
            'Clip Duration',
            key: const Key('STOR-014'),
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          GlassCard(
            child: !hasClipDurationBounds
                ? const Text(
                    'This camera hasn\'t reported clip-duration bounds yet — '
                    'try again, or check the camera\'s firmware supports '
                    'this.',
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'How long each recorded segment is before the '
                        'camera starts a new one.',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      const SizedBox(height: 8),
                      Slider(
                        key: const Key('STOR-015'),
                        value:
                            (_pendingClipDurationSeconds ??
                                    _clipDurationMinSeconds)
                                .toDouble()
                                .clamp(
                                  _clipDurationMinSeconds.toDouble(),
                                  _clipDurationMaxSeconds.toDouble(),
                                ),
                        min: _clipDurationMinSeconds.toDouble(),
                        max: _clipDurationMaxSeconds.toDouble(),
                        divisions:
                            (_clipDurationMaxSeconds -
                                    _clipDurationMinSeconds) >
                                0
                            ? _clipDurationMaxSeconds - _clipDurationMinSeconds
                            : null,
                        label: _formatClipDuration(
                          _pendingClipDurationSeconds ??
                              _clipDurationMinSeconds,
                        ),
                        onChanged: (value) => setState(
                          () => _pendingClipDurationSeconds = value.round(),
                        ),
                      ),
                      Align(
                        alignment: Alignment.centerRight,
                        child: Text(
                          _formatClipDuration(
                            _pendingClipDurationSeconds ??
                                _clipDurationMinSeconds,
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          TextButton(
                            key: const Key('STOR-016-reset'),
                            onPressed:
                                _pendingClipDurationSeconds !=
                                    _appliedClipDurationSeconds
                                ? _resetClipDuration
                                : null,
                            child: const Text('Reset'),
                          ),
                          const SizedBox(width: 8),
                          FilledButton(
                            key: const Key('STOR-016-apply'),
                            onPressed:
                                !_isApplyingClipDuration &&
                                    _pendingClipDurationSeconds != null &&
                                    _pendingClipDurationSeconds !=
                                        _appliedClipDurationSeconds
                                ? _applyClipDuration
                                : null,
                            child: const Text('Apply'),
                          ),
                        ],
                      ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

/// STOR-018's "Recordings" tab — a real, `RecordingsClient`-backed flat list
/// of recorded clips (last 90 days, newest first, grouped by local calendar
/// day), with per-clip and multi-select-all delete
/// (`RecordingsClient.deleteRecordings`). Mirrors the sibling `nuraeye-rt`
/// app's own `RecordingsScreen` shape (a flat list, not a timeline — that
/// app keeps its scrubbing timeline as a separate screen, same split this
/// app now has between this list and the Camera Live screen's Playback
/// tab). Video playback itself isn't duplicated here — tapping a clip
/// points the user to the camera's Live screen's Playback tab, which
/// already has the full RTSP player built (`camera_live_screen.dart`'s
/// `_PlaybackTab`); this tab's job is browsing/managing what's on the
/// card, not a second video surface.
class _RecordingsTab extends StatefulWidget {
  const _RecordingsTab({required this.connection});

  final CameraConnection? connection;

  @override
  State<_RecordingsTab> createState() => _RecordingsTabState();
}

class _RecordingsTabState extends State<_RecordingsTab> {
  NuraeyeClient? _nuraeye;
  RecordingsClient? _recordings;

  bool _isLoading = true;
  String? _error;
  List<RecordingClip> _clips = [];
  final Set<int> _selected = {};
  bool _isDeleting = false;

  @override
  void initState() {
    super.initState();
    final connection = widget.connection;
    if (connection != null) {
      final nuraeye = NuraeyeClient(connection);
      _nuraeye = nuraeye;
      _recordings = RecordingsClient(nuraeye);
    }
    _load();
  }

  @override
  void dispose() {
    _recordings?.closeDownloadClient();
    _nuraeye?.close();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    final now = DateTime.now();
    final startEpoch =
        now.subtract(const Duration(days: 90)).millisecondsSinceEpoch ~/ 1000;
    final endEpoch = now.millisecondsSinceEpoch ~/ 1000;

    // LAN first, WAN on failure — the same fallback shape this screen's
    // storage status and enable/disable paths already use. Without it this
    // tab is simply empty off-network, even though the Playback tab lists
    // the very same clips over WAN.
    List<RecordingClip>? clips;
    String? failure;
    final recordings = _recordings;
    if (recordings != null) {
      // getAllRecordings, not getRecordings: see camera_live_screen.dart's
      // _getRecordings for why a bare single-page call can silently omit
      // genuinely new clips on a camera with enough history.
      switch (await recordings.getAllRecordings(
        start: startEpoch,
        end: endEpoch,
      )) {
        case CameraSuccess(:final value):
          clips = value.clips;
        case CameraFailure(:final reason):
          failure = reason;
        case CameraTimeout():
          failure = 'Timed out';
      }
    }
    final thingName = widget.connection?.thingName;
    if (clips == null && thingName != null) {
      switch (await WanRecordingsClient(
        thingName,
      ).getRecordings(start: startEpoch, end: endEpoch)) {
        case CameraSuccess(:final value):
          clips = value;
          failure = null;
        case CameraFailure(:final reason):
          failure = reason;
        case CameraTimeout():
          failure = 'Timed out';
      }
    }

    if (!mounted) return;
    setState(() {
      _isLoading = false;
      _error = failure;
      if (clips != null) {
        _clips = List.of(clips)..sort((a, b) => b.start.compareTo(a.start));
      }
    });
  }

  void _toggleSelected(int clipId) {
    setState(() {
      if (!_selected.remove(clipId)) _selected.add(clipId);
    });
  }

  Future<void> _deleteSelected() async {
    final recordings = _recordings;
    if (recordings == null || _selected.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Delete ${_selected.length} clip(s)?'),
        content: const Text('This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(dialogContext).colorScheme.error,
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _isDeleting = true);
    final result = await recordings.deleteRecordings(ids: _selected.toList());
    if (!mounted) return;
    setState(() => _isDeleting = false);
    switch (result) {
      case CameraSuccess(:final value):
        setState(() {
          _clips.removeWhere((c) => _selected.contains(c.id));
          _selected.clear();
        });
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Deleted $value clip(s)')));
      case CameraFailure(:final reason):
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Could not delete: $reason')));
      case CameraTimeout():
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Timed out — try again')));
    }
  }

  String _two(int n) => n.toString().padLeft(2, '0');

  String _formatClipTime(int epochSeconds) {
    final t = DateTime.fromMillisecondsSinceEpoch(
      epochSeconds * 1000,
    ).toLocal();
    return '${t.year}-${_two(t.month)}-${_two(t.day)} '
        '${_two(t.hour)}:${_two(t.minute)}:${_two(t.second)}';
  }

  String _formatDuration(int seconds) {
    final m = seconds ~/ 60;
    final s = seconds % 60;
    return m > 0 ? '${m}m ${s}s' : '${s}s';
  }

  @override
  Widget build(BuildContext context) {
    if (widget.connection == null) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Add this camera\'s IP address in Settings to browse recordings.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    if (_isLoading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Could not load recordings: $_error'),
              const SizedBox(height: 8),
              TextButton(onPressed: _load, child: const Text('Retry')),
            ],
          ),
        ),
      );
    }
    if (_clips.isEmpty) {
      return const Center(child: Text('No recordings in the last 90 days.'));
    }

    return Stack(
      children: [
        ListView.separated(
          padding: EdgeInsets.fromLTRB(16, 16, 16, _selected.isEmpty ? 16 : 76),
          itemCount: _clips.length,
          separatorBuilder: (_, _) => const SizedBox(height: 8),
          itemBuilder: (context, i) {
            final clip = _clips[i];
            final selected = _selected.contains(clip.id);
            return GlassCard(
              padding: EdgeInsets.zero,
              child: CheckboxListTile(
                key: Key('STOR-019-${clip.id}'),
                value: selected,
                onChanged: (_) => _toggleSelected(clip.id),
                controlAffinity: ListTileControlAffinity.leading,
                title: Text(_formatClipTime(clip.start)),
                subtitle: Text(
                  '${_formatDuration(clip.end - clip.start)}'
                  '${clip.trigger != null ? ' · ${clip.trigger}' : ''}'
                  '${clip.active ? ' · recording now' : ''}',
                ),
              ),
            );
          },
        ),
        if (_selected.isNotEmpty)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surface,
                boxShadow: const [
                  BoxShadow(color: Colors.black26, blurRadius: 8),
                ],
              ),
              child: Row(
                children: [
                  Expanded(child: Text('${_selected.length} selected')),
                  _isDeleting
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : TextButton.icon(
                          key: const Key('STOR-020'),
                          onPressed: _deleteSelected,
                          icon: Icon(
                            Icons.delete_outline,
                            color: Theme.of(context).colorScheme.error,
                          ),
                          label: Text(
                            'Delete',
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                        ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
