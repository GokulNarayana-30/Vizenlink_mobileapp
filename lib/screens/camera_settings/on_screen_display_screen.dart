import 'dart:async';
import 'dart:typed_data';

import 'package:camera_api/camera_api.dart';

import '../../app_state/camera_network.dart';
import 'package:flutter/material.dart';

import '../../app_state/camera_settings_cache.dart';
import '../../app_state/camera_sync.dart';
import '../../app_state/homes_controller.dart';
import '../../models/camera.dart';
import '../../widgets/camera_preview_thumbnail.dart';
import '../../widgets/color_picker_field.dart';
import '../../widgets/fixed_preview_layout.dart';
import '../../widgets/glass_card.dart';
import '../../widgets/gradient_background.dart';
import '../../widgets/navigation_leave_guard.dart';
import '../../widgets/refresh_preview_button.dart';
import '../../widgets/reload_settings_button.dart';
import '../../widgets/saving_overlay.dart';
import '../../widgets/settings_save_button.dart';

/// ONVIF's fixed `tt:Colorspace` URI for RGB (`onvif_types.h`'s
/// `OnvifOSDColorspaceEnum`) — no longer exported by `camera_api` as of the
/// latest client package drop (was `kOnvifColorspaceRgb`), but this is a
/// fixed spec value, not camera-specific, so a local constant is fine
/// instead of touching the package.
const _kOnvifColorspaceRgb = 'http://www.onvif.org/ver10/colorspace/RGB';

enum _DateFormat { ymd, dmy, mdy }

extension on _DateFormat {
  String get label => switch (this) {
    _DateFormat.ymd => 'YYYY-MM-DD',
    _DateFormat.dmy => 'DD-MM-YYYY',
    _DateFormat.mdy => 'MM-DD-YYYY',
  };

  String format(DateTime date) {
    final y = date.year.toString().padLeft(4, '0');
    final mo = date.month.toString().padLeft(2, '0');
    final d = date.day.toString().padLeft(2, '0');
    return switch (this) {
      _DateFormat.ymd => '$y-$mo-$d',
      _DateFormat.dmy => '$d-$mo-$y',
      _DateFormat.mdy => '$mo-$d-$y',
    };
  }
}

enum _TimeFormat { h24, h12 }

extension on _TimeFormat {
  String get label => switch (this) {
    _TimeFormat.h24 => '24-hour',
    _TimeFormat.h12 => '12-hour',
  };

  String format(DateTime time) {
    final hour24 = time.hour.toString().padLeft(2, '0');
    final minute = time.minute.toString().padLeft(2, '0');
    final hour12 = (time.hour % 12 == 0 ? 12 : time.hour % 12).toString();
    final ampm = time.hour < 12 ? 'AM' : 'PM';
    return switch (this) {
      _TimeFormat.h24 => '$hour24:$minute',
      _TimeFormat.h12 => '$hour12:$minute $ampm',
    };
  }
}

/// Position choice for a draggable OSD overlay: one of the four fixed
/// preview corners, or [custom] — in which case the overlay is freely
/// draggable and its position is tracked separately as a fractional
/// offset.
enum _OverlayPosition { topLeft, topRight, bottomLeft, bottomRight, custom }

extension on _OverlayPosition {
  String get label => switch (this) {
    _OverlayPosition.topLeft => 'Top left',
    _OverlayPosition.topRight => 'Top right',
    _OverlayPosition.bottomLeft => 'Bottom left',
    _OverlayPosition.bottomRight => 'Bottom right',
    _OverlayPosition.custom => 'Custom (drag to place)',
  };

  /// Fractional (x, y) offset for a fixed corner. Not used for [custom].
  Offset get fractionalOffset => switch (this) {
    _OverlayPosition.topLeft => const Offset(0.04, 0.04),
    _OverlayPosition.topRight => const Offset(0.7, 0.04),
    _OverlayPosition.bottomLeft => const Offset(0.04, 0.78),
    _OverlayPosition.bottomRight => const Offset(0.7, 0.78),
    _OverlayPosition.custom => Offset.zero,
  };
}

const _defaultTimeOffset = Offset(0.04, 0.04);
const _defaultCustomTextOffset = Offset(0.04, 0.78);

/// `_OverlayPosition` <-> ONVIF `tt:Position/tt:Type` wire values.
String _wirePosType(_OverlayPosition position) => switch (position) {
  _OverlayPosition.topLeft => kOsdPositionUpperLeft,
  _OverlayPosition.topRight => kOsdPositionUpperRight,
  _OverlayPosition.bottomLeft => kOsdPositionLowerLeft,
  _OverlayPosition.bottomRight => kOsdPositionLowerRight,
  _OverlayPosition.custom => kOsdPositionCustom,
};

_OverlayPosition? _overlayPositionFromWire(String? wireValue) =>
    switch (wireValue) {
      kOsdPositionUpperLeft => _OverlayPosition.topLeft,
      kOsdPositionUpperRight => _OverlayPosition.topRight,
      kOsdPositionLowerLeft => _OverlayPosition.bottomLeft,
      kOsdPositionLowerRight => _OverlayPosition.bottomRight,
      kOsdPositionCustom => _OverlayPosition.custom,
      _ => null,
    };

/// [Offset] here is already fractional (0-1, top-left origin, Y-down — same
/// convention `DrawableZone.rect` uses) — exactly what `pixelPointToOnvifPos`/
/// `onvifPosToPixelPoint` expect for a 1x1 "pixel" container.
const _unitContainer = PixelSize(1, 1);

OnvifPoint _offsetToOnvifPos(Offset offset) =>
    pixelPointToOnvifPos(PixelPoint(offset.dx, offset.dy), _unitContainer);

Offset _onvifPosToOffset(double x, double y) {
  final point = onvifPosToPixelPoint(OnvifPoint(x, y), _unitContainer);
  return Offset(point.dx, point.dy);
}

Color _colorFromWire(OsdColor color) =>
    Color.from(alpha: 1, red: color.x, green: color.y, blue: color.z);

OsdColor _colorToWire(Color color) => OsdColor(
  x: color.r,
  y: color.g,
  z: color.b,
  colorspace: _kOnvifColorspaceRgb,
);

/// Fallback wire strings, used only when the camera hasn't reported a real
/// `dateFormats` list yet (no connection, or the options call failed) —
/// `_resolveDateFormatWire` always prefers a real reported string when one
/// is available. **Confirmed by direct hardware testing** that guessing
/// isn't safe here even for `dmy`/`h12`, which reuse this package's own
/// documented defaults (`kOsdDefaultDateFormat`/`kOsdDefaultTimeFormat`):
/// the real camera rejected a `SetOSD` call with `ter:InvalidArgVal`
/// ("Argument Value Invalid") on the very first hardware test of this
/// screen, and the date/time format fields were the only ones sent by that
/// call with no real-options backing at all — see `_resolveDateFormatWire`/
/// `_resolveTimeFormatWire` for the fix.
const _dateFormatWireByEnum = {
  _DateFormat.ymd: 'yyyy/MM/dd',
  _DateFormat.dmy: kOsdDefaultDateFormat,
  _DateFormat.mdy: 'MM/dd/yyyy',
};

const _timeFormatWireByEnum = {
  _TimeFormat.h24: 'HH:mm:ss',
  _TimeFormat.h12: kOsdDefaultTimeFormat,
};

/// Whether [wire] (one of the camera's own reported `dateFormats` strings)
/// matches [format]'s y/M/d token order — the two vocabularies otherwise
/// don't correspond directly, so this is the shared matching rule both
/// [_resolveDateFormatWire] (picks a wire string to send) and
/// [_availableDateFormats] (picks which dropdown choices to show) use.
bool _dateFormatMatchesWire(_DateFormat format, String wire) {
  final lower = wire.toLowerCase();
  final y = lower.indexOf('y');
  final m = lower.indexOf('m');
  final d = lower.indexOf('d');
  if (y == -1 || m == -1 || d == -1) return false;
  return switch (format) {
    _DateFormat.ymd => y < m && m < d,
    _DateFormat.dmy => d < m && m < y,
    _DateFormat.mdy => m < d && d < y,
  };
}

/// Resolves [format] to one of the camera's own reported `dateFormats`,
/// falling back to `_dateFormatWireByEnum`'s guess only when the camera
/// hasn't reported a real list. Always prefer a real reported string over
/// an invented one — see this file's `OsdOptions` comment for why the guess
/// alone isn't safe to send.
String _resolveDateFormatWire(_DateFormat format, OsdOptions? options) {
  final real = options?.dateFormats;
  if (real == null || real.isEmpty) return _dateFormatWireByEnum[format]!;
  for (final wire in real) {
    if (_dateFormatMatchesWire(format, wire)) return wire;
  }
  return real.first;
}

/// Date format choices to actually offer in the dropdown — only formats
/// that match at least one of the camera's own `getOsdOptions().dateFormats`
/// entries (all 3 when unverified — no connection yet, per
/// `.claude/rules/mobile-app-screen-conventions.md`'s rule #5), always
/// keeping [current] so the dropdown's selected value is never outside its
/// own item list.
List<_DateFormat> _availableDateFormats(
  OsdOptions? options,
  _DateFormat current,
) {
  final real = options?.dateFormats;
  if (real == null || real.isEmpty) return _DateFormat.values;
  final supported = {
    for (final format in _DateFormat.values)
      if (real.any((wire) => _dateFormatMatchesWire(format, wire))) format,
  }..add(current);
  return [
    for (final format in _DateFormat.values)
      if (supported.contains(format)) format,
  ];
}

/// Whether [wire] (one of the camera's own reported `timeFormats` strings)
/// has an AM/PM marker matching [format] — same shared-matching-rule
/// reasoning as [_dateFormatMatchesWire].
bool _timeFormatMatchesWire(_TimeFormat format, String wire) {
  final lower = wire.toLowerCase();
  final hasAmPmMarker =
      lower.contains('tt') || lower.contains(' a') || lower.endsWith('a');
  return hasAmPmMarker == (format == _TimeFormat.h12);
}

/// Resolves [format] to one of the camera's own reported `timeFormats`,
/// same reasoning as [_resolveDateFormatWire].
String _resolveTimeFormatWire(_TimeFormat format, OsdOptions? options) {
  final real = options?.timeFormats;
  if (real == null || real.isEmpty) return _timeFormatWireByEnum[format]!;
  for (final wire in real) {
    if (_timeFormatMatchesWire(format, wire)) return wire;
  }
  return real.first;
}

/// Time format choices to actually offer — same reasoning as
/// [_availableDateFormats].
List<_TimeFormat> _availableTimeFormats(
  OsdOptions? options,
  _TimeFormat current,
) {
  final real = options?.timeFormats;
  if (real == null || real.isEmpty) return _TimeFormat.values;
  final supported = {
    for (final format in _TimeFormat.values)
      if (real.any((wire) => _timeFormatMatchesWire(format, wire))) format,
  }..add(current);
  return [
    for (final format in _TimeFormat.values)
      if (supported.contains(format)) format,
  ];
}

/// Position choices to actually offer — only what the camera's own
/// `getOsdOptions().positionTypes` reports (all 5 when unverified — no
/// connection yet), always keeping [current] so a dropdown's selected value
/// is never outside its own item list.
List<_OverlayPosition> _availablePositions(
  OsdOptions? options,
  _OverlayPosition current,
) {
  if (options == null) return _OverlayPosition.values;
  final supported =
      options.positionTypes
          .map(_overlayPositionFromWire)
          .whereType<_OverlayPosition>()
          .toSet()
        ..add(current);
  return [
    for (final position in _OverlayPosition.values)
      if (supported.contains(position)) position,
  ];
}

/// On-Screen Display: a live preview showing Time and Custom Text overlays.
/// Each has a position (one of 4 fixed corners, or Custom — freely
/// draggable) and a text color. Backed by `OsdClient` (ONVIF Media2
/// `GetOSDs`/`CreateOSD`/`SetOSD`/`DeleteOSD`/`GetOSDOptions`) when the
/// camera has a saved connection — Time is the `DateAndTime` OSD slot,
/// Custom Text is the `Plain` slot; each slot's server-assigned token is
/// tracked internally so Save knows whether to `SetOSD` (already exists) or
/// `CreateOSD` (doesn't yet), and disabling a slot that exists on the camera
/// sends `DeleteOSD`. Falls back to local-only `HomesController`-free draft
/// state (`simulateCameraSave`) for a camera with no saved connection yet —
/// this screen never persisted its fields through `HomesController` even
/// before this, unlike other camera-settings screens (see CLAUDE.md). LAN
/// is always tried first for both load and save; a WAN retry (`WanOsdClient`
/// — a single `setOsd` covers both LAN's `createTimestampOsd`/
/// `createTextOsd`/`updateTimestampPosition`/`updateTextOsd`, keyed by
/// whether a token is passed) only kicks in when the LAN call itself
/// fails/times out and `connection.thingName` is known, per
/// `.claude/rules/mobile-app-screen-conventions.md`'s LAN/WAN convention.
/// Per that same convention, WAN OSD *Options* are never fetched on a
/// normal load — only the current-value `getOsds` read gets a WAN fallback
/// there. Bitrate and Signal Strength
/// (app-side, non-draggable status badges that actually apply to the Camera
/// Live page) live on the separate Tags screen, since they affect the
/// Camera Live page rather than this screen's own preview. Save is disabled
/// until a field changes.
///
/// Two separate capability gates apply, per `SETTINGS_API_GUIDE.md`: device-
/// wide OSD support (`Media2CapabilitiesClient.getServiceCapabilities()
/// .osdSupported`) hides the whole Time/Custom Text UI when explicitly
/// `false` (OSD-025) — a `getOsds`/`getOsdOptions` failure alone can't be
/// used for this, since it leaves `_osdOptions` `null`, indistinguishable
/// from "still loading". Font color support (`OsdOptions
/// .fontColorRangeAvailable`/`.fontColors`) only hides the two color pickers
/// (OSD-022/023). Neither substitutes for the other.
class OnScreenDisplayScreen extends StatefulWidget {
  const OnScreenDisplayScreen({
    super.key,
    required this.camera,
    required this.homesController,
  });

  static const routeName = 'on-screen-display';

  final Camera camera;
  final HomesController homesController;

  @override
  State<OnScreenDisplayScreen> createState() => _OnScreenDisplayScreenState();
}

class _OnScreenDisplayScreenState extends State<OnScreenDisplayScreen> {
  bool _timeEnabled = true;
  _OverlayPosition _timePosition = _OverlayPosition.custom;
  Offset _timeCustomOffset = _defaultTimeOffset;
  Color _timeColor = Colors.white;
  _DateFormat _dateFormat = _DateFormat.ymd;
  _TimeFormat _timeFormat = _TimeFormat.h24;

  bool _customTextEnabled = false;
  _OverlayPosition _customTextPosition = _OverlayPosition.custom;
  Offset _customTextCustomOffset = _defaultCustomTextOffset;
  Color _customTextColor = Colors.white;
  final _customTextController = TextEditingController();

  bool _isDirty = false;
  bool _isSaving = false;
  bool _isRefreshing = false;
  int _previewReloadKey = 0;

  /// A transient WAN preview fetched when [_refreshPreview]'s LAN attempt
  /// fails — never persisted (see `fetchWanPreviewSnapshot`'s doc), just
  /// held here for as long as this screen is open. Cleared once a LAN
  /// refresh succeeds again, so the persisted (and now fresher) thumbnail
  /// takes back over.
  Uint8List? _wanPreviewBytes;

  /// Server-assigned OSD token for each slot that already exists on the
  /// camera — null means that slot doesn't exist there yet, so Save should
  /// `CreateOSD` for it instead of `SetOSD`.
  String? _timeToken;
  String? _customTextToken;

  /// The camera's own OSD capability envelope (`getOsdOptions`) — null means
  /// "camera not verified yet". Used to gate the Position dropdowns and the
  /// color pickers to what the camera actually reports.
  OsdOptions? _osdOptions;

  /// Device-wide OSD support (`Media2CapabilitiesClient.getServiceCapabilities()
  /// .osdSupported`) — null means unverified. This is a coarser, separate gate
  /// from [_osdOptions]/[_colorUnsupported]: a camera whose Media2 service
  /// doesn't offer OSD at all still lets `getOsds`/`getOsdOptions` return a
  /// (non-success) result, which on its own leaves [_osdOptions] `null` and
  /// would otherwise look identical to "still loading" — this flag is what
  /// actually distinguishes "verified unsupported" from "unverified", per
  /// `packages/camera_api/SETTINGS_API_GUIDE.md`'s two-gate OSD design.
  bool? _osdSupported;

  /// True only while a saved connection exists and its `getOsds`/
  /// `getOsdOptions`/`getServiceCapabilities` responses haven't landed yet —
  /// gates the capability-derived controls (color pickers, and the whole
  /// Time/Custom Text UI via [_osdSupported]) so they never render off a
  /// default/unverified guess and then flicker once the real answer
  /// arrives. No connection means there's nothing to wait for.
  late bool _isLoading = _camera.connection != null;

  /// Whether the camera's own `getOsdOptions()` response explicitly ruled
  /// out font color (neither a continuous range nor a discrete list) — only
  /// meaningful once [_isLoading] is `false`.
  bool get _colorUnsupported =>
      _osdOptions != null &&
      !_osdOptions!.fontColorRangeAvailable &&
      _osdOptions!.fontColors.isEmpty;

  /// Looked up fresh from [HomesController] on every build (not
  /// [widget.camera] directly) so a refreshed snapshot from [_refreshPreview]
  /// actually shows up without leaving and re-entering this screen.
  Camera get _camera {
    for (final home in widget.homesController.value.homes) {
      for (final camera in home.cameras) {
        if (camera.id == widget.camera.id) return camera;
      }
    }
    return widget.camera;
  }

  @override
  void initState() {
    super.initState();
    _loadRealOsd();
  }

  Future<void> _loadRealOsd() async {
    final connection = _camera.connection;
    if (connection == null) return;
    final client = OsdClient(
      connection,
      httpClient: CameraNetwork.clientFor(connection.host),
      endpoint: CameraNetwork.media2EndpointFor(connection.host),
    );
    final capabilitiesClient = Media2CapabilitiesClient(
      connection,
      httpClient: CameraNetwork.clientFor(connection.host),
    );
    final results = await Future.wait([
      client.getOsds(),
      NetworkAnswerCache.getOrFetch(
        connection.host,
        'osdOptions',
        fetch: client.getOsdOptions,
      ),
      capabilitiesClient.getServiceCapabilities(),
    ]);
    CameraNetwork.rememberMedia2Endpoint(
      connection.host,
      client.resolvedEndpoint,
    );
    client.close();
    capabilitiesClient.close();

    var osdsResult = results[0] as CameraResult<List<OsdEntry>>;
    final optionsResult = results[1] as CameraResult<OsdOptions>;
    final capabilitiesResult = results[2] as CameraResult<Media2Capabilities>;

    // Options are LAN-only on a normal load (see this class's doc comment)
    // — only the current-value getOsds read falls back to WAN here. (No
    // Camera.lastKnownWan skip-LAN fast path here, unlike other screens'
    // loads: Options must be fetched over LAN regardless of transport, so
    // this screen's load always pays that LAN round trip anyway — nothing
    // left to skip.)
    final thingName = connection.thingName;
    if (osdsResult is! CameraSuccess && thingName != null) {
      osdsResult = await WanOsdClient(thingName).getOsds();
    }
    if (!mounted) return;

    setState(() {
      if (osdsResult case CameraSuccess(:final value)) {
        OsdEntry? timeEntry;
        OsdEntry? textEntry;
        for (final entry in value) {
          if (entry.textType == 'DateAndTime') timeEntry = entry;
          if (entry.textType == 'Plain') textEntry = entry;
        }

        _timeEnabled = timeEntry != null;
        _timeToken = timeEntry?.token;
        if (timeEntry != null) {
          final position = _overlayPositionFromWire(timeEntry.posType);
          if (position != null) _timePosition = position;
          if (timeEntry.posType == kOsdPositionCustom &&
              timeEntry.posX != null &&
              timeEntry.posY != null) {
            _timeCustomOffset = _onvifPosToOffset(
              timeEntry.posX!,
              timeEntry.posY!,
            );
          }
          if (timeEntry.fontColor != null) {
            _timeColor = _colorFromWire(timeEntry.fontColor!);
          }
        }

        _customTextEnabled = textEntry != null;
        _customTextToken = textEntry?.token;
        if (textEntry != null) {
          _customTextController.text = textEntry.plainText ?? '';
          final position = _overlayPositionFromWire(textEntry.posType);
          if (position != null) _customTextPosition = position;
          if (textEntry.posType == kOsdPositionCustom &&
              textEntry.posX != null &&
              textEntry.posY != null) {
            _customTextCustomOffset = _onvifPosToOffset(
              textEntry.posX!,
              textEntry.posY!,
            );
          }
          if (textEntry.fontColor != null) {
            _customTextColor = _colorFromWire(textEntry.fontColor!);
          }
        }
      }
      if (optionsResult case CameraSuccess(:final value)) {
        _osdOptions = value;
      }
      if (capabilitiesResult case CameraSuccess(:final value)) {
        _osdSupported = value.osdSupported;
      }
      _isLoading = false;
    });
  }

  /// Manual reload — re-fetches this screen's fields from the camera, for
  /// when a change made elsewhere (another client, the camera's own web UI)
  /// hasn't shown up here yet. Distinct from [_save] (pushes local edits)
  /// and [_refreshPreview] (only refetches the preview image).
  Future<void> _reloadSettings() async {
    if (_camera.connection == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No saved connection for this camera yet'),
        ),
      );
      return;
    }
    setState(() => _isLoading = true);
    await _loadRealOsd();
  }

  @override
  void dispose() {
    _customTextController.dispose();
    super.dispose();
  }

  void _markDirty(VoidCallback update) {
    setState(() {
      update();
      _isDirty = true;
    });
  }

  Future<void> _refreshPreview() async {
    final connection = _camera.connection;
    if (connection == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No saved connection for this camera yet'),
        ),
      );
      return;
    }
    setState(() => _isRefreshing = true);
    final succeeded = await refreshCameraSnapshot(
      homesController: widget.homesController,
      cameraId: widget.camera.id,
      connection: connection,
    );
    if (!mounted) return;
    if (succeeded) {
      setState(() {
        _isRefreshing = false;
        _previewReloadKey++;
        _wanPreviewBytes = null;
      });
      return;
    }

    // LAN failed — fall back to a transient WAN preview rather than
    // surfacing an error outright, per mobile-app-screen-conventions.md's
    // LAN/WAN convention. The last-shown preview (whether the persisted
    // thumbnail or a previous WAN frame) stays on screen until this
    // resolves, not blanked out mid-refresh.
    final wanBytes = await fetchWanPreviewSnapshot(connection: connection);
    if (!mounted) return;
    setState(() {
      _isRefreshing = false;
      if (wanBytes != null) _wanPreviewBytes = wanBytes;
    });
    if (wanBytes == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Failed to refresh preview')),
      );
    }
  }

  Future<void> _save() async {
    final connection = _camera.connection;
    setState(() => _isSaving = true);

    final bool succeeded;
    final failures = <String>[];
    String reasonOf(CameraResult<Object?> result) => switch (result) {
      CameraFailure(:final reason) => reason,
      CameraTimeout() => 'timed out',
      CameraSuccess() => '',
    };

    if (connection != null) {
      final client = OsdClient(
        connection,
        httpClient: CameraNetwork.clientFor(connection.host),
        endpoint: CameraNetwork.media2EndpointFor(connection.host),
      );
      final thingName = connection.thingName;
      final wanClient = thingName != null ? WanOsdClient(thingName) : null;
      // Skips each LAN attempt below entirely when this camera's last
      // confirmed transport was WAN — see Camera.lastKnownWan's doc.
      final preferWan = _camera.lastKnownWan == true && wanClient != null;

      // Time (DateAndTime) slot.
      if (_timeEnabled) {
        final posType = _wirePosType(_timePosition);
        final onvifPos = _timePosition == _OverlayPosition.custom
            ? _offsetToOnvifPos(_timeCustomOffset)
            : null;
        final dateWire = _resolveDateFormatWire(_dateFormat, _osdOptions);
        final timeWire = _resolveTimeFormatWire(_timeFormat, _osdOptions);
        final color = _colorToWire(_timeColor);
        final timeToken = _timeToken;
        if (timeToken != null) {
          CameraResult<void>? result;
          if (!preferWan) {
            result = await client.updateTimestampPosition(
              timeToken,
              posType: posType,
              posX: onvifPos?.x ?? 0,
              posY: onvifPos?.y ?? 0,
              dateFormat: dateWire,
              timeFormat: timeWire,
              fontColor: color,
            );
          }
          // A failed LAN Apply/Set retries over WAN before surfacing an
          // error, per mobile-app-screen-conventions.md's LAN/WAN
          // convention. WAN's single setOsd covers both create and update.
          if (result is! CameraSuccess && wanClient != null) {
            final wanResult = await wanClient.setOsd(
              token: timeToken,
              textType: 'DateAndTime',
              posType: posType,
              posX: onvifPos?.x ?? 0,
              posY: onvifPos?.y ?? 0,
              dateFormat: dateWire,
              timeFormat: timeWire,
              fontColor: color,
            );
            result = wanResult is CameraSuccess
                ? const CameraSuccess(null)
                : CameraFailure(reasonOf(wanResult));
          }
          if (result is! CameraSuccess) {
            failures.add('time (${reasonOf(result!)})');
          }
        } else {
          CameraResult<String>? result;
          if (!preferWan) {
            result = await client.createTimestampOsd(
              posType: posType,
              posX: onvifPos?.x ?? 0.8,
              posY: onvifPos?.y ?? 1,
              dateFormat: dateWire,
              timeFormat: timeWire,
              fontColor: color,
            );
          }
          if (result is! CameraSuccess && wanClient != null) {
            result = await wanClient.setOsd(
              textType: 'DateAndTime',
              posType: posType,
              posX: onvifPos?.x ?? 0.8,
              posY: onvifPos?.y ?? 1,
              dateFormat: dateWire,
              timeFormat: timeWire,
              fontColor: color,
            );
          }
          if (result case CameraSuccess(:final value)) {
            _timeToken = value;
          } else {
            failures.add('time (${reasonOf(result!)})');
          }
        }
      } else if (_timeToken != null) {
        CameraResult<void>? result;
        if (!preferWan) result = await client.deleteOsd(_timeToken!);
        if (result is! CameraSuccess && wanClient != null) {
          result = await wanClient.deleteOsd(_timeToken!);
        }
        if (result is CameraSuccess) {
          _timeToken = null;
        } else {
          failures.add('time (${reasonOf(result!)})');
        }
      }

      // Custom Text (Plain) slot — treated as "off" when enabled but empty,
      // same as the preview's own display condition.
      final hasCustomText =
          _customTextEnabled && _customTextController.text.isNotEmpty;
      if (hasCustomText) {
        final posType = _wirePosType(_customTextPosition);
        final onvifPos = _customTextPosition == _OverlayPosition.custom
            ? _offsetToOnvifPos(_customTextCustomOffset)
            : null;
        final color = _colorToWire(_customTextColor);
        final customTextToken = _customTextToken;
        if (customTextToken != null) {
          CameraResult<void>? result;
          if (!preferWan) {
            result = await client.updateTextOsd(
              customTextToken,
              _customTextController.text,
              posType: posType,
              posX: onvifPos?.x ?? -1,
              posY: onvifPos?.y ?? 1,
              fontColor: color,
            );
          }
          if (result is! CameraSuccess && wanClient != null) {
            final wanResult = await wanClient.setOsd(
              token: customTextToken,
              textType: 'Plain',
              text: _customTextController.text,
              posType: posType,
              posX: onvifPos?.x ?? -1,
              posY: onvifPos?.y ?? 1,
              fontColor: color,
            );
            result = wanResult is CameraSuccess
                ? const CameraSuccess(null)
                : CameraFailure(reasonOf(wanResult));
          }
          if (result is! CameraSuccess) {
            failures.add('custom text (${reasonOf(result!)})');
          }
        } else {
          CameraResult<String>? result;
          if (!preferWan) {
            result = await client.createTextOsd(
              _customTextController.text,
              posType: posType,
              posX: onvifPos?.x ?? -1,
              posY: onvifPos?.y ?? 1,
              fontColor: color,
            );
          }
          if (result is! CameraSuccess && wanClient != null) {
            result = await wanClient.setOsd(
              textType: 'Plain',
              text: _customTextController.text,
              posType: posType,
              posX: onvifPos?.x ?? -1,
              posY: onvifPos?.y ?? 1,
              fontColor: color,
            );
          }
          if (result case CameraSuccess(:final value)) {
            _customTextToken = value;
          } else {
            failures.add('custom text (${reasonOf(result!)})');
          }
        }
      } else if (_customTextToken != null) {
        CameraResult<void>? result;
        if (!preferWan) result = await client.deleteOsd(_customTextToken!);
        if (result is! CameraSuccess && wanClient != null) {
          result = await wanClient.deleteOsd(_customTextToken!);
        }
        if (result is CameraSuccess) {
          _customTextToken = null;
        } else {
          failures.add('custom text (${reasonOf(result!)})');
        }
      }

      CameraNetwork.rememberMedia2Endpoint(
        connection.host,
        client.resolvedEndpoint,
      );
      client.close();
      succeeded = failures.isEmpty;
    } else {
      succeeded = await simulateCameraSave();
    }

    if (!mounted) return;
    setState(() => _isSaving = false);
    if (succeeded) {
      setState(() => _isDirty = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Changes saved')));
      if (connection != null) unawaited(_refreshPreview());
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            failures.isEmpty
                ? 'Failed to save changes. Try again.'
                : 'Failed to save: ${failures.join(', ')}',
          ),
        ),
      );
    }
  }

  Future<bool> _confirmLeave() => confirmDiscardOnLeave(
    context: context,
    isDirty: _isDirty,
    onSave: _save,
    isDirtyAfterSave: () => _isDirty,
    dialogKey: const Key('OSD-019'),
    discardKey: const Key('OSD-020'),
    saveKey: const Key('OSD-021'),
  );

  @override
  Widget build(BuildContext context) {
    return LeaveGuard(
      canLeave: _confirmLeave,
      child: GradientBackground(
        child: Scaffold(
          backgroundColor: Colors.transparent,
          appBar: AppBar(
            key: const Key('OSD-001'),
            title: const Text('On-Screen Display'),
            actions: [
              ReloadSettingsButton(
                settingsKey: const Key('OSD-024'),
                isBusy: _isLoading || _isSaving,
                onPressed: _reloadSettings,
              ),
              SettingsSaveButton(
                settingsKey: const Key('OSD-004'),
                isDirty: _isDirty,
                isSaving: _isSaving,
                onPressed: _save,
              ),
            ],
          ),
          body: SavingOverlay(
            isSaving: _isSaving || _isLoading,
            label: _isLoading ? 'Loading…' : 'Saving…',
            child: FixedPreviewLayout(
              preview: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _OsdPreview(
                    key: ValueKey(_previewReloadKey),
                    settingsKey: const Key('OSD-005'),
                    camera: _camera,
                    overrideBytes: _wanPreviewBytes,
                    timeEnabled: _timeEnabled,
                    timeText:
                        '${_dateFormat.format(DateTime.now())} '
                        '${_timeFormat.format(DateTime.now())}',
                    timeColor: _timeColor,
                    timePosition: _timePosition,
                    timeCustomOffset: _timeCustomOffset,
                    onTimeCustomOffsetChanged: (offset) =>
                        _markDirty(() => _timeCustomOffset = offset),
                    customText: _customTextController.text,
                    customTextEnabled: _customTextEnabled,
                    customTextColor: _customTextColor,
                    customTextPosition: _customTextPosition,
                    customTextCustomOffset: _customTextCustomOffset,
                    onCustomTextCustomOffsetChanged: (offset) =>
                        _markDirty(() => _customTextCustomOffset = offset),
                  ),
                  const SizedBox(height: 8),
                  RefreshPreviewButton(
                    settingsKey: const Key('OSD-018'),
                    isRefreshing: _isRefreshing,
                    onPressed: _refreshPreview,
                  ),
                ],
              ),
              scrollableChildren: [
                if (_osdSupported == false && !_isLoading) ...[
                  GlassCard(
                    child: Text(
                      "This camera doesn't support On-Screen Display.",
                      key: const Key('OSD-025'),
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ),
                ] else ...[
                  GlassCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SwitchListTile(
                          key: const Key('OSD-006'),
                          contentPadding: EdgeInsets.zero,
                          title: const Text('Time'),
                          value: _timeEnabled,
                          onChanged: (value) =>
                              _markDirty(() => _timeEnabled = value),
                        ),
                        const SizedBox(height: 8),
                        DropdownButtonFormField<_DateFormat>(
                          key: const Key('OSD-016'),
                          initialValue: _dateFormat,
                          isExpanded: true,
                          decoration: const InputDecoration(
                            labelText: 'Date format',
                          ),
                          items: [
                            for (final format in _availableDateFormats(
                              _osdOptions,
                              _dateFormat,
                            ))
                              DropdownMenuItem(
                                value: format,
                                child: Text(
                                  format.label,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                          ],
                          onChanged: _timeEnabled
                              ? (value) =>
                                    _markDirty(() => _dateFormat = value!)
                              : null,
                        ),
                        const SizedBox(height: 8),
                        DropdownButtonFormField<_TimeFormat>(
                          key: const Key('OSD-017'),
                          initialValue: _timeFormat,
                          isExpanded: true,
                          decoration: const InputDecoration(
                            labelText: 'Time format',
                          ),
                          items: [
                            for (final format in _availableTimeFormats(
                              _osdOptions,
                              _timeFormat,
                            ))
                              DropdownMenuItem(
                                value: format,
                                child: Text(
                                  format.label,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                          ],
                          onChanged: _timeEnabled
                              ? (value) =>
                                    _markDirty(() => _timeFormat = value!)
                              : null,
                        ),
                        const SizedBox(height: 8),
                        DropdownButtonFormField<_OverlayPosition>(
                          key: const Key('OSD-012'),
                          initialValue: _timePosition,
                          isExpanded: true,
                          decoration: const InputDecoration(
                            labelText: 'Position',
                          ),
                          items: [
                            for (final position in _availablePositions(
                              _osdOptions,
                              _timePosition,
                            ))
                              DropdownMenuItem(
                                value: position,
                                child: Text(
                                  position.label,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                          ],
                          onChanged: _timeEnabled
                              ? (value) =>
                                    _markDirty(() => _timePosition = value!)
                              : null,
                        ),
                        if (_timePosition == _OverlayPosition.custom) ...[
                          const SizedBox(height: 4),
                          Text(
                            'Drag on the preview to reposition',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                        // Hidden outright when the camera reports neither a
                        // continuous RGB range nor a discrete color list — per
                        // OsdOptions' doc, a color control with nothing behind
                        // it isn't a real choice.
                        if (_osdOptions == null ||
                            _osdOptions!.fontColorRangeAvailable ||
                            _osdOptions!.fontColors.isNotEmpty) ...[
                          const SizedBox(height: 12),
                          Text(
                            'Color',
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                          const SizedBox(height: 8),
                          ColorPickerField(
                            settingsKey: const Key('OSD-013'),
                            color: _timeColor,
                            enabled: _timeEnabled,
                            onChanged: (color) =>
                                _markDirty(() => _timeColor = color),
                          ),
                        ],
                        if (!_isLoading && _colorUnsupported) ...[
                          const SizedBox(height: 8),
                          Text(
                            'Color not supported by this camera.',
                            key: const Key('OSD-022'),
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  GlassCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SwitchListTile(
                          key: const Key('OSD-007'),
                          contentPadding: EdgeInsets.zero,
                          title: const Text('Custom text'),
                          value: _customTextEnabled,
                          onChanged: (value) =>
                              _markDirty(() => _customTextEnabled = value),
                        ),
                        const SizedBox(height: 8),
                        TextField(
                          key: const Key('OSD-008'),
                          controller: _customTextController,
                          enabled: _customTextEnabled,
                          decoration: const InputDecoration(labelText: 'Text'),
                          onChanged: (_) => _markDirty(() {}),
                        ),
                        const SizedBox(height: 8),
                        DropdownButtonFormField<_OverlayPosition>(
                          key: const Key('OSD-014'),
                          initialValue: _customTextPosition,
                          isExpanded: true,
                          decoration: const InputDecoration(
                            labelText: 'Position',
                          ),
                          items: [
                            for (final position in _availablePositions(
                              _osdOptions,
                              _customTextPosition,
                            ))
                              DropdownMenuItem(
                                value: position,
                                child: Text(
                                  position.label,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                          ],
                          onChanged: _customTextEnabled
                              ? (value) => _markDirty(
                                  () => _customTextPosition = value!,
                                )
                              : null,
                        ),
                        if (_customTextPosition == _OverlayPosition.custom) ...[
                          const SizedBox(height: 4),
                          Text(
                            'Drag on the preview to reposition',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                        if (_osdOptions == null ||
                            _osdOptions!.fontColorRangeAvailable ||
                            _osdOptions!.fontColors.isNotEmpty) ...[
                          const SizedBox(height: 12),
                          Text(
                            'Color',
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                          const SizedBox(height: 8),
                          ColorPickerField(
                            settingsKey: const Key('OSD-015'),
                            color: _customTextColor,
                            enabled: _customTextEnabled,
                            onChanged: (color) =>
                                _markDirty(() => _customTextColor = color),
                          ),
                        ],
                        if (!_isLoading && _colorUnsupported) ...[
                          const SizedBox(height: 8),
                          Text(
                            'Color not supported by this camera.',
                            key: const Key('OSD-023'),
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _OsdPreview extends StatelessWidget {
  const _OsdPreview({
    super.key,
    required this.settingsKey,
    required this.camera,
    this.overrideBytes,
    required this.timeEnabled,
    required this.timeText,
    required this.timeColor,
    required this.timePosition,
    required this.timeCustomOffset,
    required this.onTimeCustomOffsetChanged,
    required this.customText,
    required this.customTextEnabled,
    required this.customTextColor,
    required this.customTextPosition,
    required this.customTextCustomOffset,
    required this.onCustomTextCustomOffsetChanged,
  });

  final Key settingsKey;
  final Camera camera;

  /// See `CameraPreviewThumbnail.overrideBytes`'s doc — same
  /// never-persisted transient-frame contract.
  final Uint8List? overrideBytes;
  final bool timeEnabled;
  final String timeText;
  final Color timeColor;
  final _OverlayPosition timePosition;
  final Offset timeCustomOffset;
  final ValueChanged<Offset> onTimeCustomOffsetChanged;
  final String customText;
  final bool customTextEnabled;
  final Color customTextColor;
  final _OverlayPosition customTextPosition;
  final Offset customTextCustomOffset;
  final ValueChanged<Offset> onCustomTextCustomOffsetChanged;

  @override
  Widget build(BuildContext context) {
    return Stack(
      key: settingsKey,
      children: [
        CameraPreviewThumbnail(
          settingsKey: const Key('OSD-005-image'),
          camera: camera,
          overrideBytes: overrideBytes,
        ),
        Positioned.fill(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final areaSize = constraints.biggest;
              return Stack(
                clipBehavior: Clip.hardEdge,
                children: [
                  if (timeEnabled)
                    _OverlayChip(
                      position: timePosition,
                      areaSize: areaSize,
                      customOffset: timeCustomOffset,
                      onCustomOffsetChanged: onTimeCustomOffsetChanged,
                      child: Text(
                        timeText,
                        style: TextStyle(
                          color: timeColor,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  if (customTextEnabled && customText.isNotEmpty)
                    _OverlayChip(
                      position: customTextPosition,
                      areaSize: areaSize,
                      customOffset: customTextCustomOffset,
                      onCustomOffsetChanged: onCustomTextCustomOffsetChanged,
                      child: Text(
                        customText,
                        style: TextStyle(
                          color: customTextColor,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }
}

/// Renders [child] at [position]: a fixed corner (non-draggable), or, when
/// [position] is [_OverlayPosition.custom], at [customOffset] and freely
/// draggable — measuring its own rendered size after layout (via a
/// `GlobalKey`/`RenderBox`, since text width varies with content) and
/// clamping against that actual footprint rather than a guessed constant,
/// so it can't be dragged or resized-into partway off the preview edges.
class _OverlayChip extends StatefulWidget {
  const _OverlayChip({
    required this.position,
    required this.areaSize,
    required this.customOffset,
    required this.onCustomOffsetChanged,
    required this.child,
  });

  final _OverlayPosition position;
  final Size areaSize;
  final Offset customOffset;
  final ValueChanged<Offset> onCustomOffsetChanged;
  final Widget child;

  @override
  State<_OverlayChip> createState() => _OverlayChipState();
}

class _OverlayChipState extends State<_OverlayChip> {
  final _chipKey = GlobalKey();
  Size _chipSize = Size.zero;

  bool get _isCustom => widget.position == _OverlayPosition.custom;

  Offset get _fractionalOffset =>
      _isCustom ? widget.customOffset : widget.position.fractionalOffset;

  double get _maxLeft =>
      (widget.areaSize.width - _chipSize.width).clamp(0.0, double.infinity);
  double get _maxTop =>
      (widget.areaSize.height - _chipSize.height).clamp(0.0, double.infinity);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _measureAndClamp());
  }

  @override
  void didUpdateWidget(covariant _OverlayChip oldWidget) {
    super.didUpdateWidget(oldWidget);
    WidgetsBinding.instance.addPostFrameCallback((_) => _measureAndClamp());
  }

  void _measureAndClamp() {
    if (!mounted) return;
    final renderBox = _chipKey.currentContext?.findRenderObject() as RenderBox?;
    if (renderBox == null || !renderBox.hasSize) return;
    final newSize = renderBox.size;
    if (newSize != _chipSize) setState(() => _chipSize = newSize);

    if (!_isCustom) return;
    if (widget.areaSize.width == 0 || widget.areaSize.height == 0) return;
    final left = (_fractionalOffset.dx * widget.areaSize.width).clamp(
      0.0,
      (widget.areaSize.width - newSize.width).clamp(0.0, double.infinity),
    );
    final top = (_fractionalOffset.dy * widget.areaSize.height).clamp(
      0.0,
      (widget.areaSize.height - newSize.height).clamp(0.0, double.infinity),
    );
    final clamped = Offset(
      left / widget.areaSize.width,
      top / widget.areaSize.height,
    );
    if ((clamped - _fractionalOffset).distanceSquared > 0.0000001) {
      widget.onCustomOffsetChanged(clamped);
    }
  }

  @override
  Widget build(BuildContext context) {
    final left = (_fractionalOffset.dx * widget.areaSize.width).clamp(
      0.0,
      _maxLeft,
    );
    final top = (_fractionalOffset.dy * widget.areaSize.height).clamp(
      0.0,
      _maxTop,
    );

    final content = Container(key: _chipKey, child: widget.child);

    if (!_isCustom) {
      return Positioned(left: left, top: top, child: content);
    }

    return Positioned(
      left: left,
      top: top,
      child: GestureDetector(
        onPanUpdate: (details) {
          if (widget.areaSize.width == 0 || widget.areaSize.height == 0) {
            return;
          }
          final newLeft = (left + details.delta.dx).clamp(0.0, _maxLeft);
          final newTop = (top + details.delta.dy).clamp(0.0, _maxTop);
          widget.onCustomOffsetChanged(
            Offset(
              newLeft / widget.areaSize.width,
              newTop / widget.areaSize.height,
            ),
          );
        },
        child: content,
      ),
    );
  }
}
