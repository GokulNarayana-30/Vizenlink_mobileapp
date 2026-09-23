import 'package:camera_api/camera_api.dart';

import '../models/camera.dart';

/// What the last completed call actually *proved* about a camera's reachable
/// transport, keyed by `thingName`.
///
/// `Camera.lastKnownWan` is only ever written in one place — when live view
/// reaches `connected` — so any settings work reached without live view
/// having connected this session finds it `false`/`null` and guesses LAN. On
/// a camera that is genuinely off-LAN that guess costs a full LAN timeout
/// (10-12s) before the WAN call it was always going to need. This records
/// what each attempt already learns for free, so the next one doesn't repeat
/// a doomed attempt.
///
/// Process-lifetime and deliberately not persisted: which network the phone
/// is on is exactly the kind of thing that should not survive a restart.
final Map<String, bool> _learnedWanByThing = {};

/// Forgets what was learned about [thingName] — call when a camera is removed
/// so a stale answer can't outlive it.
void forgetLearnedTransport(String thingName) =>
    _learnedWanByThing.remove(thingName);

/// Records the answer a LAN reachability probe already produced, so settings
/// work never has to discover the transport by wasting a call on it.
///
/// The app runs `LiveStreamUriClient.checkReachable` (`AreYouNuraeyeDevice`)
/// constantly while live view is up and again on every camera sync — this is
/// how that free answer reaches everything else. Prefer calling this over
/// letting [callPreferringKnownTransport] learn from a failure: a probe
/// answers in milliseconds on LAN, whereas discovering the same thing through
/// a real settings call costs that call's full timeout.
void recordTransportFromProbe(
  String? thingName, {
  required bool reachableOnLan,
}) {
  if (thingName == null) return;
  _learnedWanByThing[thingName] = !reachableOnLan;
}

/// What a probe last proved about [thingName]: `true` = reachable only over
/// WAN, `false` = reachable on LAN, `null` = nothing proved yet.
bool? learnedTransportIsWan(String? thingName) =>
    thingName == null ? null : _learnedWanByThing[thingName];

/// Test-only reset hook for the process-lifetime map above.
void debugClearLearnedTransports() => _learnedWanByThing.clear();

/// Calls whichever transport is most likely to work first, and falls back to
/// the other one if it doesn't — so a wrong guess costs latency, never a
/// failed operation.
///
/// Preference order: what a previous call actually proved for this camera,
/// then [camera]'s `lastKnownWan` hint, then LAN. Whichever transport
/// succeeds is recorded, so a run of settings actions converges on the right
/// one after at most a single wasted attempt instead of paying for the same
/// wrong guess every time.
///
/// The LAN-failure-retries-over-WAN path is required by
/// `.claude/rules/mobile-app-screen-conventions.md`'s "LAN/WAN transport
/// selection" item 3; the mirrored WAN-failure-retries-over-LAN path is the
/// same safety net in the other direction, and is what makes preferring WAN
/// up front safe to do at all.
Future<CameraResult<T>> callPreferringKnownTransport<T>({
  required Camera camera,
  required String? thingName,
  required Future<CameraResult<T>> Function() lan,
  required Future<CameraResult<T>> Function() wan,
}) async {
  final learned = thingName == null ? null : _learnedWanByThing[thingName];
  final preferWan = learned ?? (camera.lastKnownWan == true);

  if (preferWan && thingName != null) {
    final wanResult = await wan();
    if (wanResult is CameraSuccess) return wanResult;
    // Back on the camera's own network, or a transient WAN failure — try LAN
    // rather than surfacing an error, and re-learn from whatever answers.
    final lanResult = await lan();
    if (lanResult is CameraSuccess) {
      _learnedWanByThing[thingName] = false;
      return lanResult;
    }
    return wanResult;
  }

  final result = await lan();
  if (result is CameraSuccess) {
    if (thingName != null) _learnedWanByThing[thingName] = false;
    return result;
  }
  if (thingName == null) return result;

  final wanResult = await wan();
  if (wanResult is CameraSuccess) _learnedWanByThing[thingName] = true;
  return wanResult;
}
