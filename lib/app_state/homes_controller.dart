import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/camera.dart';
import 'camera_network.dart';
import 'transport_preference.dart';
import '../models/home.dart';
import 'camera_credentials_store.dart';
import 'camera_settings_cache.dart';

/// Marks a persisted `thumbnailUrl` as a filename under this app's own
/// `camera_snapshots` documents subfolder (written by
/// `_saveSnapshotLocally`/`syncCameraFromDevice` in `camera_sync.dart`),
/// rather than an absolute path or a `picsum.photos` placeholder URL. The
/// absolute path a snapshot was saved under is only valid for the app
/// container instance that wrote it — iOS/the simulator can assign a new
/// container path on a later install, which silently breaks any absolute
/// path saved straight into `SharedPreferences`. Storing just the filename
/// here and re-resolving it against the *current* documents directory in
/// [HomesController.load] keeps local snapshots showing up after a fresh
/// install/relaunch instead of quietly falling back to the placeholder.
const _localSnapshotPrefix = 'local-snapshot:';

/// Converts an in-memory [Camera.thumbnailUrl] (an absolute file path for a
/// locally-saved snapshot, or an `http(s)://` placeholder URL) to what
/// actually gets written to `SharedPreferences` — see [_localSnapshotPrefix].
String? _persistableThumbnailUrl(String? thumbnailUrl) {
  if (thumbnailUrl == null) return null;
  if (thumbnailUrl.startsWith('http://') ||
      thumbnailUrl.startsWith('https://')) {
    return thumbnailUrl;
  }
  final slash = thumbnailUrl.lastIndexOf('/');
  final filename = slash == -1
      ? thumbnailUrl
      : thumbnailUrl.substring(slash + 1);
  return '$_localSnapshotPrefix$filename';
}

/// Persisted subset of [Camera] — identity/connection fields only (what
/// `addCamera`/`syncCameraFromDevice` populate), not every settings field
/// (recording, detection, OSD, imaging, …). Those reset to [Camera]'s own
/// constructor defaults on every app restart; only "don't make me re-scan
/// and re-add this camera" is in scope here.
///
/// The password is deliberately excluded — it's secret and must not sit in
/// plaintext in `SharedPreferences`. It's stored separately in
/// [CameraCredentialsStore] (Android Keystore/iOS Keychain-backed) and
/// stitched back onto the restored [Camera] in [HomesController.load].
Map<String, dynamic> _persistedCameraJson(String homeId, Camera camera) => {
  'homeId': homeId,
  'id': camera.id,
  'name': camera.name,
  'room': camera.room,
  'isOnline': camera.isOnline,
  'host': camera.host,
  'username': camera.username,
  'ipAddress': camera.ipAddress,
  'manufacturer': camera.manufacturer,
  'model': camera.model,
  'firmwareVersion': camera.firmwareVersion,
  'serialNumber': camera.serialNumber,
  'hardwareId': camera.hardwareId,
  'macAddress': camera.macAddress,
  'thingName': camera.thingName,
  'wanLiveViewCapable': camera.wanLiveViewCapable,
  'wanCommandCapable': camera.wanCommandCapable,
  'sirenCapable': camera.sirenCapable,
  'spotlightCapable': camera.spotlightCapable,
  'warningCapable': camera.warningCapable,
  'thumbnailUrl': _persistableThumbnailUrl(camera.thumbnailUrl),
  'timezone': camera.timezone,
  'location': camera.location,
};

({String homeId, Camera camera})? _cameraFromPersistedJson(
  Map<String, dynamic> json,
) {
  final homeId = json['homeId'] as String?;
  final id = json['id'] as String?;
  final name = json['name'] as String?;
  if (homeId == null || id == null || name == null) return null;
  return (
    homeId: homeId,
    camera: Camera(
      id: id,
      name: name,
      isOnline: json['isOnline'] as bool? ?? false,
      room: json['room'] as String?,
      host: json['host'] as String?,
      username: json['username'] as String?,
      ipAddress: json['ipAddress'] as String? ?? '—',
      manufacturer: json['manufacturer'] as String? ?? '—',
      model: json['model'] as String? ?? '—',
      firmwareVersion: json['firmwareVersion'] as String? ?? '—',
      serialNumber: json['serialNumber'] as String? ?? '—',
      hardwareId: json['hardwareId'] as String? ?? '—',
      macAddress: json['macAddress'] as String? ?? '—',
      thingName: json['thingName'] as String?,
      wanLiveViewCapable: json['wanLiveViewCapable'] as bool?,
      wanCommandCapable: json['wanCommandCapable'] as bool?,
      sirenCapable: json['sirenCapable'] as bool?,
      spotlightCapable: json['spotlightCapable'] as bool?,
      warningCapable: json['warningCapable'] as bool?,
      thumbnailUrl: json['thumbnailUrl'] as String?,
      timezone: json['timezone'] as String? ?? 'UTC',
      location: json['location'] as String?,
    ),
  );
}

const maxHomes = 10;
const maxRoomsPerHome = 10;

/// Id of the debug-only test camera seeded by `HomesController._seedState`.
/// Never persisted (see `HomesController._persistCameras`/`.load`) so it
/// doesn't duplicate itself across app restarts — it's re-seeded fresh from
/// `_seedState` every debug launch instead.
const _debugTestCameraId = 'debug-test-camera';

class HomesState {
  const HomesState({required this.homes, required this.selectedHomeId});

  final List<Home> homes;
  final String selectedHomeId;

  Home get selectedHome =>
      homes.firstWhere((home) => home.id == selectedHomeId);

  HomesState copyWith({List<Home>? homes, String? selectedHomeId}) {
    return HomesState(
      homes: homes ?? this.homes,
      selectedHomeId: selectedHomeId ?? this.selectedHomeId,
    );
  }
}

class HomesController extends ValueNotifier<HomesState> {
  HomesController({CameraCredentialsStore? credentialsStore})
    : _credentialsStore = credentialsStore ?? CameraCredentialsStore(),
      super(_seedState());

  static const _prefsKey = 'homes_controller_cameras_v1';

  final CameraCredentialsStore _credentialsStore;

  /// True once [load] has run (successfully or not) — persisting before then
  /// would overwrite the saved cameras with the empty seed state, since
  /// [load] itself sets `value` and this class persists on every `value`
  /// write (see the [value] setter override below).
  bool _loaded = false;

  /// Restores previously-added cameras (see [_persistedCameraJson]'s doc for
  /// what's actually saved) into the seeded homes/rooms. Call once at
  /// startup, awaited before the splash screen hands off — same convention
  /// as [ThemeController.load]. A camera whose saved `homeId` no longer
  /// exists (e.g. a future seed change) is dropped rather than crashing.
  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      if (raw != null) {
        final decoded = jsonDecode(raw) as List<dynamic>;
        final restored =
            [
                  for (final entry in decoded)
                    _cameraFromPersistedJson(entry as Map<String, dynamic>),
                ].nonNulls
                // Defensive: drop any pre-existing persisted copy of the
                // debug-only seed camera from an install predating the guard
                // in `_persistCameras`, so it can't duplicate the fresh one
                // `_seedState` already added.
                .where((r) => r.camera.id != _debugTestCameraId)
                .toList();
        final docsDir = await getApplicationDocumentsDirectory();
        final withPasswords = <({String homeId, Camera camera})>[];
        for (final r in restored) {
          final password = await _credentialsStore.readPassword(r.camera.id);
          final thumbnailUrl = r.camera.thumbnailUrl;
          final resolvedThumbnailUrl =
              thumbnailUrl != null &&
                  thumbnailUrl.startsWith(_localSnapshotPrefix)
              ? '${docsDir.path}/camera_snapshots/'
                    '${thumbnailUrl.substring(_localSnapshotPrefix.length)}'
              : thumbnailUrl;
          withPasswords.add((
            homeId: r.homeId,
            camera: r.camera.copyWith(
              password: password,
              thumbnailUrl: resolvedThumbnailUrl,
            ),
          ));
        }
        if (withPasswords.isNotEmpty) {
          value = value.copyWith(
            homes: [
              for (final home in value.homes)
                home.copyWith(
                  cameras: [
                    ...home.cameras,
                    for (final r in withPasswords)
                      if (r.homeId == home.id) r.camera,
                  ],
                ),
            ],
          );
        }
      }
    } on FormatException {
      // Corrupt saved data — start from the empty seed rather than crash.
    } finally {
      _loaded = true;
    }
  }

  /// Adds a debug-only test camera to the first home so screens (e.g. one
  /// with no real hardware wired up yet) can be exercised without a real
  /// camera — no `host`/`username`/connection, so it exercises every
  /// screen's already-supported "no saved connection yet" local-only save
  /// path, not a fake video/thumbnail standing in for real footage (which
  /// this repo removed outright, see CLAUDE.md's dummy-video removal).
  ///
  /// Deliberately **not** part of [_seedState] — that runs for every
  /// `HomesController()` instance, including ones built directly in tests,
  /// which assert on specific camera counts/lists. Call this once from the
  /// real app's own bootstrap (`main.dart`, guarded by `kDebugMode`) after
  /// [load], never from a test. Idempotent — a second call is a no-op if
  /// the debug camera is already present. Never persisted (see
  /// [_persistCameras]) so it doesn't survive into a release build's data
  /// and doesn't duplicate itself across debug-build restarts.
  void addDebugTestCameraIfNeeded() {
    final homes = value.homes;
    if (homes.isEmpty) return;
    final alreadyPresent = homes.any(
      (home) => home.cameras.any((camera) => camera.id == _debugTestCameraId),
    );
    if (alreadyPresent) return;
    final target = homes.first;
    value = value.copyWith(
      homes: [
        for (final home in homes)
          if (home.id == target.id)
            home.copyWith(
              cameras: [
                ...home.cameras,
                const Camera(
                  id: _debugTestCameraId,
                  name: 'Test Camera (Debug)',
                  // `isOnline: true` despite having no real connection —
                  // real bug found testing this: `camera_settings_screen.
                  // dart` disables every settings section (Detections
                  // included) whenever `isOnline` is false, which made this
                  // fixture unusable for exactly what it exists for. Every
                  // screen already falls back to its local-only save path
                  // correctly when `connection` is null, regardless of
                  // `isOnline` — so this doesn't skip any real code path.
                  isOnline: true,
                  room: 'Living Room',
                ),
              ],
            )
          else
            home,
      ],
    );
  }

  @override
  set value(HomesState newValue) {
    super.value = newValue;
    if (_loaded) unawaited(_persistCameras());
  }

  Future<void> _persistCameras() async {
    final prefs = await SharedPreferences.getInstance();
    final entries = [
      for (final home in value.homes)
        for (final camera in home.cameras)
          if (camera.id != _debugTestCameraId)
            _persistedCameraJson(home.id, camera),
    ];
    await prefs.setString(_prefsKey, jsonEncode(entries));
  }

  static String _thumbnailFor(String seed) =>
      'https://picsum.photos/seed/$seed/480/270';

  static HomesState _seedState() {
    final homes = [
      Home(
        id: 'home-1',
        name: 'Main House',
        rooms: const [
          'Living Room',
          'Backyard',
          'Garage',
          'Kitchen',
          'Bedroom',
        ],
        cameras: const [],
      ),
      Home(
        id: 'home-2',
        name: 'Office',
        rooms: const ['Living Room'],
        cameras: const [],
      ),
    ];
    return HomesState(homes: homes, selectedHomeId: 'home-1');
  }

  void selectHome(String homeId) {
    value = value.copyWith(selectedHomeId: homeId);
  }

  void renameCamera(String homeId, String cameraId, String newName) {
    final updated = [
      for (final home in value.homes)
        if (home.id == homeId)
          home.copyWith(
            cameras: [
              for (final camera in home.cameras)
                if (camera.id == cameraId)
                  camera.copyWith(name: newName)
                else
                  camera,
            ],
          )
        else
          home,
    ];
    value = value.copyWith(homes: updated);
  }

  void updateCameraWifi(String homeId, String cameraId, String wifiNetwork) {
    final updated = [
      for (final home in value.homes)
        if (home.id == homeId)
          home.copyWith(
            cameras: [
              for (final camera in home.cameras)
                if (camera.id == cameraId)
                  camera.copyWith(wifiNetwork: wifiNetwork)
                else
                  camera,
            ],
          )
        else
          home,
    ];
    value = value.copyWith(homes: updated);
  }

  void updateCameraTimezone(String homeId, String cameraId, String timezone) {
    final updated = [
      for (final home in value.homes)
        if (home.id == homeId)
          home.copyWith(
            cameras: [
              for (final camera in home.cameras)
                if (camera.id == cameraId)
                  camera.copyWith(timezone: timezone)
                else
                  camera,
            ],
          )
        else
          home,
    ];
    value = value.copyWith(homes: updated);
  }

  /// Generic camera-settings persistence: finds [cameraId] across all homes
  /// (no need for the caller to know which home it belongs to) and replaces
  /// it with `transform(current)`. Used by the settings screens whose saved
  /// values don't yet drive anything visible (no real CCTV stream — see
  /// CLAUDE.md) but should still be durable, so a future real stream only
  /// needs to read these `Camera` fields, not add new plumbing.
  void updateCamera(
    String cameraId,
    Camera Function(Camera current) transform,
  ) {
    final updated = [
      for (final home in value.homes)
        home.copyWith(
          cameras: [
            for (final camera in home.cameras)
              if (camera.id == cameraId) transform(camera) else camera,
          ],
        ),
    ];
    value = value.copyWith(homes: updated);
  }

  /// Persists a camera's device-account password after a successful
  /// `OnvifDeviceClient.setUserPassword`/`WanDeviceIdentityClient
  /// .setUserPassword` call — updates the in-memory [Camera.password] (so
  /// [Camera.connection] immediately reflects it for any client constructed
  /// from here on) and the secure-storage copy [CameraCredentialsStore]
  /// keeps separately (see [addCamera]'s doc for why password isn't in
  /// [_persistedCameraJson]). Callers must do this immediately on success —
  /// every client still holding the old password will start failing WSSE
  /// auth otherwise, per `setUserPassword`'s own doc.
  void updateCameraPassword(String cameraId, String newPassword) {
    updateCamera(
      cameraId,
      (current) => current.copyWith(password: newPassword),
    );
    unawaited(_credentialsStore.savePassword(cameraId, newPassword));
  }

  void updateCameraOsdSettings(
    String homeId,
    String cameraId, {
    required bool bitrateOsdEnabled,
    required OsdCorner bitrateOsdPosition,
    required bool signalStrengthOsdEnabled,
    required OsdCorner signalStrengthOsdPosition,
    required bool liveTagOsdEnabled,
  }) {
    final updated = [
      for (final home in value.homes)
        if (home.id == homeId)
          home.copyWith(
            cameras: [
              for (final camera in home.cameras)
                if (camera.id == cameraId)
                  camera.copyWith(
                    bitrateOsdEnabled: bitrateOsdEnabled,
                    bitrateOsdPosition: bitrateOsdPosition,
                    signalStrengthOsdEnabled: signalStrengthOsdEnabled,
                    signalStrengthOsdPosition: signalStrengthOsdPosition,
                    liveTagOsdEnabled: liveTagOsdEnabled,
                  )
                else
                  camera,
            ],
          )
        else
          home,
    ];
    value = value.copyWith(homes: updated);
  }

  /// Moves a camera from [fromHomeId] to [toHomeId], optionally assigning it
  /// to [room] in the destination home. If [toHomeId] equals [fromHomeId]
  /// this just reassigns the room within the same home.
  void moveCameraToHome({
    required String fromHomeId,
    required String toHomeId,
    required String cameraId,
    String? room,
  }) {
    if (fromHomeId == toHomeId) {
      final updated = [
        for (final home in value.homes)
          if (home.id == fromHomeId)
            home.copyWith(
              cameras: [
                for (final camera in home.cameras)
                  if (camera.id == cameraId)
                    camera.copyWith(room: room, setRoom: true)
                  else
                    camera,
              ],
            )
          else
            home,
      ];
      value = value.copyWith(homes: updated);
      return;
    }

    final sourceHome = value.homes.firstWhere((home) => home.id == fromHomeId);
    final camera = sourceHome.cameras.firstWhere((c) => c.id == cameraId);
    final movedCamera = camera.copyWith(room: room, setRoom: true);

    final updated = [
      for (final home in value.homes)
        if (home.id == fromHomeId)
          home.copyWith(
            cameras: home.cameras.where((c) => c.id != cameraId).toList(),
          )
        else if (home.id == toHomeId)
          home.copyWith(cameras: [...home.cameras, movedCamera])
        else
          home,
    ];
    value = value.copyWith(homes: updated);
  }

  void toggleFavorite(String homeId, String cameraId) {
    final updatedHomes = [
      for (final home in value.homes)
        if (home.id == homeId)
          home.copyWith(
            cameras: [
              for (final camera in home.cameras)
                if (camera.id == cameraId)
                  camera.copyWith(isFavorite: !camera.isFavorite)
                else
                  camera,
            ],
          )
        else
          home,
    ];
    value = value.copyWith(homes: updatedHomes);
  }

  void togglePin(String homeId, String cameraId) {
    final updatedHomes = [
      for (final home in value.homes)
        if (home.id == homeId)
          home.copyWith(
            cameras: [
              for (final camera in home.cameras)
                if (camera.id == cameraId)
                  camera.copyWith(isPinned: !camera.isPinned)
                else
                  camera,
            ],
          )
        else
          home,
    ];
    value = value.copyWith(homes: updatedHomes);
  }

  /// Moves the camera with [cameraId] to sit immediately before
  /// [beforeCameraId] (or to the end of the list if null) within [homeId]'s
  /// camera order. Used to persist drag-to-reorder from the Dashboard.
  void reorderCamera(String homeId, String cameraId, String? beforeCameraId) {
    final updatedHomes = [
      for (final home in value.homes)
        if (home.id == homeId)
          home.copyWith(
            cameras: _reordered(home.cameras, cameraId, beforeCameraId),
          )
        else
          home,
    ];
    value = value.copyWith(homes: updatedHomes);
  }

  static List<Camera> _reordered(
    List<Camera> cameras,
    String cameraId,
    String? beforeCameraId,
  ) {
    final moved = cameras.firstWhere((camera) => camera.id == cameraId);
    final remaining = cameras.where((camera) => camera.id != cameraId).toList();
    final insertIndex = beforeCameraId == null
        ? remaining.length
        : remaining.indexWhere((camera) => camera.id == beforeCameraId);
    remaining.insert(insertIndex == -1 ? remaining.length : insertIndex, moved);
    return remaining;
  }

  bool get canAddHome => value.homes.length < maxHomes;

  void addHome(String name) {
    if (!canAddHome) return;
    final newHome = Home(
      id: 'home-${DateTime.now().microsecondsSinceEpoch}',
      name: name,
    );
    value = value.copyWith(homes: [...value.homes, newHome]);
  }

  void renameHome(String homeId, String newName) {
    final updated = [
      for (final home in value.homes)
        if (home.id == homeId) home.copyWith(name: newName) else home,
    ];
    value = value.copyWith(homes: updated);
  }

  void deleteHome(String homeId) {
    if (value.homes.length <= 1) return;
    final remaining = value.homes.where((home) => home.id != homeId).toList();
    final selectedHomeId = value.selectedHomeId == homeId
        ? remaining.first.id
        : value.selectedHomeId;
    value = HomesState(homes: remaining, selectedHomeId: selectedHomeId);
  }

  bool canAddRoom(String homeId) {
    final home = value.homes.firstWhere((home) => home.id == homeId);
    return home.rooms.length < maxRoomsPerHome;
  }

  /// Returns the newly created camera so callers can chain further action on
  /// it (e.g. an immediate `syncCameraFromDevice` call right after scan
  /// setup) without a separate lookup.
  Camera addCamera(
    String homeId, {
    required String name,
    String? room,
    required bool isOnline,
    String? host,
    String? username,
    String? password,
    String? manufacturer,
    String? model,
    String? firmwareVersion,
    String? serialNumber,
    String? hardwareId,
    String? macAddress,
    String? thingName,
    bool? wanLiveViewCapable,
    bool? wanCommandCapable,
    bool? sirenCapable,
    bool? spotlightCapable,
    bool? warningCapable,
  }) {
    final cameraId = 'cam-${DateTime.now().microsecondsSinceEpoch}';
    final newCamera = Camera(
      id: cameraId,
      name: name,
      isOnline: isOnline,
      room: room,
      thumbnailUrl: _thumbnailFor(cameraId),
      host: host,
      username: username,
      password: password,
      ipAddress: host ?? '—',
      manufacturer: manufacturer ?? '—',
      model: model ?? '—',
      firmwareVersion: firmwareVersion ?? '—',
      serialNumber: serialNumber ?? '—',
      hardwareId: hardwareId ?? '—',
      macAddress: macAddress ?? '—',
      thingName: thingName,
      wanLiveViewCapable: wanLiveViewCapable,
      wanCommandCapable: wanCommandCapable,
      sirenCapable: sirenCapable,
      spotlightCapable: spotlightCapable,
      warningCapable: warningCapable,
    );
    final updated = [
      for (final home in value.homes)
        if (home.id == homeId)
          home.copyWith(cameras: [...home.cameras, newCamera])
        else
          home,
    ];
    value = value.copyWith(homes: updated);
    unawaited(_credentialsStore.savePassword(cameraId, password));
    return newCamera;
  }

  void addRoom(String homeId, String roomName) {
    final updated = [
      for (final home in value.homes)
        if (home.id == homeId &&
            home.rooms.length < maxRoomsPerHome &&
            !home.rooms.contains(roomName))
          home.copyWith(rooms: [...home.rooms, roomName])
        else
          home,
    ];
    value = value.copyWith(homes: updated);
  }

  void renameRoom(String homeId, String oldName, String newName) {
    final updated = [
      for (final home in value.homes)
        if (home.id == homeId)
          home.copyWith(
            rooms: [
              for (final room in home.rooms) room == oldName ? newName : room,
            ],
            cameras: [
              for (final camera in home.cameras)
                if (camera.room == oldName)
                  camera.copyWith(room: newName, setRoom: true)
                else
                  camera,
            ],
          )
        else
          home,
    ];
    value = value.copyWith(homes: updated);
  }

  void deleteCamera(String homeId, String cameraId) {
    // Captured before filtering: a stale NetworkAnswerCache entry for this
    // host must not leak forward if the same camera (or another with the
    // same IP) gets re-added later, possibly with different firmware/
    // capabilities.
    String? removedHost;
    String? removedThingName;
    for (final home in value.homes) {
      if (home.id != homeId) continue;
      for (final camera in home.cameras) {
        if (camera.id == cameraId) {
          removedHost = camera.connection?.host;
          removedThingName = camera.connection?.thingName;
          break;
        }
      }
    }

    final updated = [
      for (final home in value.homes)
        if (home.id == homeId)
          home.copyWith(
            cameras: home.cameras
                .where((camera) => camera.id != cameraId)
                .toList(),
          )
        else
          home,
    ];
    value = value.copyWith(homes: updated);
    unawaited(_credentialsStore.deletePassword(cameraId));
    if (removedHost != null) {
      NetworkAnswerCache.clearForHost(removedHost);
      CameraNetwork.evictHost(removedHost);
    }
    if (removedThingName != null) forgetLearnedTransport(removedThingName);
  }

  void reorderCameras(String homeId, int oldIndex, int newIndex) {
    final updated = [
      for (final home in value.homes)
        if (home.id == homeId)
          home.copyWith(
            cameras: () {
              final newCameras = List<Camera>.from(home.cameras);
              final camera = newCameras.removeAt(oldIndex);
              newCameras.insert(newIndex, camera);
              return newCameras;
            }(),
          )
        else
          home,
    ];
    value = value.copyWith(homes: updated);
  }

  void deleteRoom(String homeId, String roomName) {
    final updated = [
      for (final home in value.homes)
        if (home.id == homeId)
          home.copyWith(
            rooms: home.rooms.where((room) => room != roomName).toList(),
            cameras: [
              for (final camera in home.cameras)
                if (camera.room == roomName)
                  camera.copyWith(setRoom: true)
                else
                  camera,
            ],
          )
        else
          home,
    ];
    value = value.copyWith(homes: updated);
  }
}
