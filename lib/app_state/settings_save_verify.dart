import 'package:camera_api/camera_api.dart';

/// Confirms a settings mutation actually failed before a screen reports it as
/// failed, instead of trusting a timeout at face value.
///
/// Every real settings screen's Apply path is: try the LAN client, fall back
/// to WAN once on failure, report failure if neither returns
/// `CameraSuccess`. That's wrong for a `CameraTimeout` specifically — this
/// camera's ONVIF (LAN) responses can arrive well past the 10s default with
/// no retry on the same transport, especially under the concurrent load this
/// app can put on it (background live view, a multi-call sync burst). The
/// mutation itself can have landed; only its acknowledgment was lost. A real
/// rejection (`CameraFailure`) means the camera's state didn't change, so
/// re-checking it is safe either way — verification will correctly confirm
/// the failure rather than paper over it.
///
/// [fetchCurrent] re-reads the value with the same LAN-then-WAN preference
/// the mutation itself used. [matchesExpected] compares that reread value
/// against what was actually sent. Returns `true` only if the fetch
/// succeeded and the camera's own state already reflects the change.
Future<bool> verifyAfterTimeout<T>({
  required Future<CameraResult<T>> Function() fetchCurrent,
  required bool Function(T current) matchesExpected,
}) async {
  final result = await fetchCurrent();
  if (result case CameraSuccess(:final value)) {
    return matchesExpected(value);
  }
  return false;
}
