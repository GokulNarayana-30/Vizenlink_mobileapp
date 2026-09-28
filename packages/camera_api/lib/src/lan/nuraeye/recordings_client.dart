import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../../camera_result.dart';
import '../../recordings_types.dart';
import '../insecure_camera_http_client.dart';
import 'nuraeye_client.dart';

/// `GetRecordings` (`FR-NE-117`) + clip playback/download URI + auth headers (`FR-NE-118`) — LAN
/// only for this pass (`FEAT-039`). Reworked from an originally ONVIF Recording Service/Profile
/// G-based design (see `design/stages/04-recording-playback/DESIGN.md` NF2) to a plain REST
/// list + `Range`-capable download, after finding ONVIF Search's async job-polling browse model
/// a poor fit for a phone client. No WAN counterpart exists yet.
class RecordingsClient {
  RecordingsClient(this._nuraeye);

  final NuraeyeClient _nuraeye;

  /// Reused across every [downloadClip] call on this instance, not recreated per call — a fresh
  /// `HttpClient()` per request means a fresh TCP+TLS handshake every time (this camera's
  /// self-signed cert makes that handshake real, non-trivial work), which was a real,
  /// avoidable slice of "why is downloading slow" when browsing between clips in the same
  /// session (`ClipPlaybackScreen`'s next/previous-event and jump-to-time navigation call this
  /// repeatedly). `dart:io`'s `HttpClient` keeps its own persistent-connection pool per host as
  /// long as the *same instance* is reused, so this alone lets sequential downloads in one
  /// screen session reuse the underlying TLS connection. Call [closeDownloadClient] when done
  /// with this instance (e.g. the owning screen's `dispose()`).
  http.Client? _downloadClient;

  http.Client get _client => _downloadClient ??= createCameraHttpClient();

  /// Closes the reused download client, if one was ever created. Safe to call even if
  /// [downloadClip] was never called.
  void closeDownloadClient() {
    _downloadClient?.close();
    _downloadClient = null;
  }

  /// [start]/[end] are UTC epoch seconds (inclusive); omit either for no bound on that side.
  /// **A single call can silently omit newer clips** if the camera has accumulated enough
  /// history — see [RecordingsList.truncated]'s own doc. Prefer [getAllRecordings] unless a
  /// caller has a specific reason to see only one page (e.g. probing whether *any* clip exists
  /// in a narrow range).
  Future<CameraResult<RecordingsList>> getRecordings({
    int? start,
    int? end,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final result = await _nuraeye.call(
      'GetRecordings',
      params: {if (start != null) 'start': start, if (end != null) 'end': end},
      timeout: timeout,
    );
    return switch (result) {
      CameraSuccess(:final value) => _parse(value),
      CameraFailure(:final reason) => CameraFailure<RecordingsList>(reason),
      CameraTimeout() => const CameraTimeout<RecordingsList>(),
    };
  }

  /// Pages through [getRecordings] automatically, advancing `start` to `<last clip's start> + 1`
  /// each time [RecordingsList.truncated] comes back `true`, until a page reports `truncated:
  /// false` or [maxPages] is reached. Real bug found 2026-09-24: `RecordingsScreen` and
  /// `RecordingTimelineScreen` both called the single-page [getRecordings] directly and never
  /// checked `truncated` at all, so a camera with enough history silently hid every clip newer
  /// than whatever filled the first response's JSON buffer (~70-80 clips in practice) — including,
  /// misleadingly, freshly-recorded scheduled-mode clips, which made a fully-working scheduled
  /// recording feature look broken. [end] is not paginated (a single response already includes
  /// every clip up to it or truncates before reaching it — advancing only ever needs to move
  /// `start` forward); pass [end] only to bound the *upper* edge of what's fetched, same as
  /// [getRecordings].
  ///
  /// [maxPages] bounds worst-case work against a heavily-populated card — the returned
  /// [RecordingsList.truncated] is `true` only if this cap was hit before the camera itself
  /// reported a clean, un-truncated final page (real "there might be even more" signal), not
  /// simply because more than one request was needed.
  Future<CameraResult<RecordingsList>> getAllRecordings({
    int? start,
    int? end,
    int maxPages = 20,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final clips = <RecordingClip>[];
    var pageStart = start;
    bool storageAvailable = false;
    bool cardPresent = false;
    var pagesFetched = 0;
    while (true) {
      final result = await getRecordings(start: pageStart, end: end, timeout: timeout);
      switch (result) {
        case CameraSuccess(:final value):
          storageAvailable = value.storageAvailable;
          cardPresent = value.cardPresent;
          clips.addAll(value.clips);
          pagesFetched++;
          if (!value.truncated || value.clips.isEmpty) {
            return CameraSuccess(
              RecordingsList(
                storageAvailable: storageAvailable,
                cardPresent: cardPresent,
                truncated: false,
                clips: clips,
              ),
            );
          }
          if (pagesFetched >= maxPages) {
            return CameraSuccess(
              RecordingsList(
                storageAvailable: storageAvailable,
                cardPresent: cardPresent,
                truncated: true,
                clips: clips,
              ),
            );
          }
          pageStart = value.clips.map((c) => c.start).reduce((a, b) => a > b ? a : b) + 1;
        case CameraFailure(:final reason):
          return CameraFailure<RecordingsList>(reason);
        case CameraTimeout():
          return const CameraTimeout<RecordingsList>();
      }
    }
  }

  /// `FR-NE-119`: the currently-configured recorded-clip duration, in seconds. Build UI bounds
  /// from `CameraCapabilities.recordingClipDurationMinSeconds`/`MaxSeconds`
  /// (`CapabilitiesClient.getCapabilities()`), never a hardcoded range.
  Future<CameraResult<int>> getClipDuration({
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final result = await _nuraeye.call('GetRecordingClipDuration', timeout: timeout);
    return switch (result) {
      CameraSuccess(:final value) => value['clip_duration_seconds'] is int
          ? CameraSuccess<int>(value['clip_duration_seconds'] as int)
          : CameraFailure<int>('GetRecordingClipDuration response missing clip_duration_seconds: $value'),
      CameraFailure(:final reason) => CameraFailure<int>(reason),
      CameraTimeout() => const CameraTimeout<int>(),
    };
  }

  /// Applies for the *next* clip rotation only — the segment currently being written keeps its
  /// original duration. The camera rejects a value outside
  /// `CameraCapabilities.recordingClipDurationMinSeconds`/`MaxSeconds` with a `400` — check
  /// those bounds before calling rather than relying on the rejection alone.
  Future<CameraResult<void>> setClipDuration(
    int seconds, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final result = await _nuraeye.call(
      'SetRecordingClipDuration',
      params: {'clipDurationSeconds': seconds},
      timeout: timeout,
    );
    return switch (result) {
      CameraSuccess() => const CameraSuccess<void>(null),
      CameraFailure(:final reason) => CameraFailure<void>(reason),
      CameraTimeout() => const CameraTimeout<void>(),
    };
  }

  /// `FR-NE-120`: deletes one or more clips by [ids], or every clip via [deleteAll] — pass
  /// exactly one of the two (never both; [ids] is ignored if [deleteAll] is true). One bulk
  /// primitive backs both a multi-select "Delete (n)" action ([ids]) and a "Delete all" action
  /// ([deleteAll]) — see `design/stages/04-recording-playback/DESIGN.md` NF8 for why this
  /// wasn't split into two endpoints. Never deletes the clip currently being recorded, even if
  /// its id is included in [ids] or [deleteAll] is set — the camera silently skips it.
  /// Returns the number of clips actually deleted.
  Future<CameraResult<int>> deleteRecordings({
    List<int>? ids,
    bool deleteAll = false,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    assert(deleteAll || (ids != null && ids.isNotEmpty),
        'deleteRecordings: pass ids or deleteAll: true');
    final result = await _nuraeye.call(
      'DeleteRecordings',
      params: {if (deleteAll) 'deleteAll': true else 'ids': ids},
      timeout: timeout,
    );
    return switch (result) {
      CameraSuccess(:final value) => value['deleted_count'] is int
          ? CameraSuccess<int>(value['deleted_count'] as int)
          : CameraFailure<int>('DeleteRecordings response missing deleted_count: $value'),
      CameraFailure(:final reason) => CameraFailure<int>(reason),
      CameraTimeout() => const CameraTimeout<int>(),
    };
  }

  /// The URI to `GET` (with [clipHeaders]'s `Authorization` header attached) for playback or
  /// download of the clip identified by [clipId] (a [RecordingClip.id] from [getRecordings]).
  /// Supports standard HTTP `Range` byte-request headers for seeking — see `FR-NE-118`.
  Uri clipUri(int clipId) => Uri.https(
        '${_nuraeye.connection.host}:${_nuraeye.connection.httpsPort}',
        '/nuraeye/recordings/$clipId/clip',
      );

  /// Headers to attach to a raw request against [clipUri] (e.g.
  /// `VideoPlayerController.networkUrl(uri, httpHeaders: ...)`)  — same bearer-session token
  /// every other `/nuraeye/*` call uses, obtained without a separate login round trip.
  Future<CameraResult<Map<String, String>>> clipHeaders({
    Duration timeout = const Duration(seconds: 10),
  }) => _nuraeye.authHeadersFor(timeout: timeout);

  /// Downloads the full clip identified by [clipId] into memory. **`video_player`'s native
  /// platform player (ExoPlayer/AVPlayer) has no way to trust this camera's self-signed HTTPS
  /// certificate** — unlike every other client in this package, which goes through
  /// [createCameraHttpClient]'s cert-trust bypass, `VideoPlayerController.networkUrl` hands the
  /// URL straight to the OS player, so a direct network play attempt fails the TLS handshake
  /// before any HTTP request is even sent. This method exists so a caller can instead download
  /// the clip through the already-working, cert-trusting client here and hand `video_player` a
  /// local file (`VideoPlayerController.file`) — see `ClipPlaybackScreen._openClip` in the app
  /// layer, which writes the result to a temp file for playback only, never app-persistent
  /// storage. Callers are responsible for deleting whatever they do with the bytes; this method
  /// itself has no file/caching concept, matching this package's pure-Dart, no-`flutter`-import
  /// design (temp-directory access needs `path_provider`, a Flutter plugin).
  Future<CameraResult<Uint8List>> downloadClip(
    int clipId, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final headersResult = await clipHeaders(timeout: timeout);
    final Map<String, String> headers;
    switch (headersResult) {
      case CameraSuccess(:final value):
        headers = value;
      case CameraFailure(:final reason):
        return CameraFailure<Uint8List>(reason);
      case CameraTimeout():
        return const CameraTimeout<Uint8List>();
    }

    try {
      final response = await _client.get(clipUri(clipId), headers: headers).timeout(timeout);
      if (response.statusCode != 200) {
        return CameraFailure('HTTP ${response.statusCode}: clip download rejected');
      }
      return CameraSuccess(response.bodyBytes);
    } on Exception catch (e) {
      return CameraFailure(e.toString());
    }
  }

  CameraResult<RecordingsList> _parse(Map<String, dynamic> value) {
    final storageAvailable = value['storage_available'];
    final cardPresent = value['card_present'];
    final truncated = value['truncated'];
    final recordings = value['recordings'];
    if (storageAvailable is! bool ||
        cardPresent is! bool ||
        truncated is! bool ||
        recordings is! List) {
      return CameraFailure('GetRecordings response missing fields: $value');
    }

    final clips = <RecordingClip>[];
    for (final entry in recordings) {
      if (entry is! Map<String, dynamic>) {
        return CameraFailure('GetRecordings response has a malformed clip entry: $entry');
      }
      final id = entry['id'];
      final start = entry['start'];
      final end = entry['end'];
      final sizeBytes = entry['size_bytes'];
      final active = entry['active'];
      final trigger = entry['trigger'];
      if (id is! int ||
          start is! int ||
          end is! int ||
          sizeBytes is! int ||
          active is! bool ||
          (trigger != null && trigger is! String)) {
        return CameraFailure('GetRecordings response has a malformed clip entry: $entry');
      }
      clips.add(RecordingClip(
        id: id,
        start: start,
        end: end,
        sizeBytes: sizeBytes,
        active: active,
        trigger: trigger as String?,
      ));
    }

    return CameraSuccess(RecordingsList(
      storageAvailable: storageAvailable,
      cardPresent: cardPresent,
      truncated: truncated,
      clips: clips,
    ));
  }
}
