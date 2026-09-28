import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';

import '../../camera_connection.dart';
import '../../camera_result.dart';
import '../insecure_camera_http_client.dart';
import '../wsse_digest.dart';
import 'soap_fault.dart';

/// One video/audio track inside a [RecordingInfo] (`trc:Track`) — a fixed `"VideoTrack_1"`
/// (H.264) plus a conditional `"AudioTrack_1"` when the firmware build has `AUDIO_ENABLED`
/// (`onvif_recording.c`'s `prvGenerateRecordingItemSnippet()`). Per-clip audio-track presence
/// isn't tracked per recording — it's a build-time flag, a documented simplification on the
/// firmware side (see that function's own comment), not something this client can improve on.
class RecordingTrackInfo {
  const RecordingTrackInfo({
    required this.trackToken,
    required this.trackType,
    required this.description,
  });

  final String trackToken;

  /// `"Video"` or `"Audio"` (`tt:TrackType`).
  final String trackType;
  final String description;
}

/// One stored clip, as reported by `GetRecordings` (`FR-OV-080`, `onvif_recording.c`'s
/// `prvGenerateRecordingItemSnippet()`). [recordingToken] is the same UTC epoch-start decimal
/// identity the existing REST `RecordingsClient` already keys clips by (`nuraeye.c`'s `"id"`
/// field) — no new ID scheme on the firmware side, so a token from this client and a REST `id`
/// for the same physical clip are interchangeable strings.
class RecordingInfo {
  const RecordingInfo({
    required this.recordingToken,
    required this.sourceId,
    required this.sourceName,
    required this.sourceLocation,
    required this.content,
    required this.maximumRetentionTimeSeconds,
    required this.tracks,
  });

  final String recordingToken;

  /// `tt:SourceId` — fixed `"VideoSource_1"` on this device (single, fixed video source).
  final String sourceId;
  final String sourceName;
  final String sourceLocation;

  /// `tt:Content` — a free-text description. Either `"Continuous recording"` or the label of
  /// whatever `EventMgr` event (loitering, tamper, object-detected, ...) overlapped this clip's
  /// time window, matching the REST recordings handler's own trigger-lookup convention.
  final String content;

  /// Parsed from `tt:MaximumRetentionTime`'s `PT<n>S` ISO-8601 duration text (the firmware only
  /// ever emits the seconds form — see `onvif_recording.c`'s `snprintf(..., "PT%uS", ...)`).
  /// `null` if the element was missing or didn't parse as that exact shape.
  final int? maximumRetentionTimeSeconds;

  final List<RecordingTrackInfo> tracks;
}

/// `GetServiceCapabilities` response (`trc:Capabilities`, all fields reported as XML
/// attributes — not child elements, per `nexml_createTag(..., NULL, "DynamicRecordings", ...)`
/// in `onvif_recording.c`, which self-closes the tag when passed a null text value).
class RecordingServiceCapabilities {
  const RecordingServiceCapabilities({
    required this.dynamicRecordings,
    required this.dynamicTracks,
    required this.optionsSupported,
    required this.maxRecordings,
    required this.maxRecordingJobs,
  });

  final bool dynamicRecordings;
  final bool dynamicTracks;
  final bool optionsSupported;
  final double? maxRecordings;
  final int? maxRecordingJobs;
}

/// `GetRecordingOptions` response (`trc:Options`) — this device isn't ONVIF-writable
/// (`CreateRecording`/`SetRecordingConfiguration`/etc. all return `ActionNotSupported`, see
/// `onvif_recording.c`'s action switch), so every spare-capacity figure is always `0`: there is
/// no free/spare capacity to report beyond "none, use the always-on pipeline" (the firmware
/// file's own comment). Parsed generically anyway rather than hardcoded, in case a future
/// firmware build reports something non-zero.
class RecordingOptions {
  const RecordingOptions({
    required this.jobSpare,
    required this.trackSpareTotal,
    required this.trackSpareVideo,
    required this.trackSpareAudio,
    required this.trackSpareMetadata,
  });

  final int? jobSpare;
  final int? trackSpareTotal;
  final int? trackSpareVideo;
  final int? trackSpareAudio;
  final int? trackSpareMetadata;
}

/// LAN-only ONVIF Recording Control client (`/onvif/recording`, SOAP, WS-UsernameToken digest
/// auth) — Profile G's read/discovery half (`FR-OV-080`). **Client-only for now**: a new,
/// parallel path alongside the existing REST-based `RecordingsClient`
/// (`lib/src/lan/nuraeye/recordings_client.dart`), not wired into any screen — per direct user
/// instruction, the REST client stays as the active path until Profile G "becomes strong," at
/// which point the REST client is expected to be removed. Do not use this class to replace any
/// call the REST client already makes.
///
/// Same SOAP envelope/auth pattern as `OnvifImagingClient` — see that class's doc for why.
class OnvifRecordingClient {
  OnvifRecordingClient(this.connection, {http.Client? httpClient})
      : _http = httpClient ?? createCameraHttpClient();

  final CameraConnection connection;
  final http.Client _http;

  /// Lists every stored clip this device currently reports (`FR-OV-080`). The real `GetRecordings`
  /// SOAP action takes no request parameters (`onvif_recording.c` marks `p_req_xml` unused for
  /// this action) — filtering by time range is the Search service's job (`OnvifSearchClient`),
  /// not this one's, matching the real ONVIF service split.
  Future<CameraResult<List<RecordingInfo>>> getRecordings({
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final bodyResult = await _post(
      '<trc:GetRecordings xmlns:trc="http://www.onvif.org/ver10/recording/wsdl"/>',
      timeout,
    );
    return bodyResult.map((body) {
      final doc = XmlDocument.parse(body);
      final items = doc.findAllElements('RecordingItem', namespace: '*');
      return items.map(_parseRecordingItem).toList();
    });
  }

  /// `GetRecordingOptions` — always-zero spare capacity on this device (see [RecordingOptions]'s
  /// doc). The real ONVIF action takes an optional `RecordingToken` to scope the answer to one
  /// recording, but the firmware ignores any request body for this action entirely (`p_req_xml`
  /// unused in `onvif_recording.c`'s switch case) — so this client sends the bare empty request
  /// element, matching what the firmware actually reads.
  Future<CameraResult<RecordingOptions>> getRecordingOptions({
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final bodyResult = await _post(
      '<trc:GetRecordingOptions xmlns:trc="http://www.onvif.org/ver10/recording/wsdl"/>',
      timeout,
    );
    return bodyResult.map((body) {
      final doc = XmlDocument.parse(body);
      int? attrInt(XmlElement el, String name) {
        final v = el.getAttribute(name);
        return v == null ? null : int.tryParse(v);
      }

      final jobEl = doc.findAllElements('Job', namespace: '*');
      final trackEl = doc.findAllElements('Track', namespace: '*');
      return RecordingOptions(
        jobSpare: jobEl.isEmpty ? null : attrInt(jobEl.first, 'Spare'),
        trackSpareTotal: trackEl.isEmpty ? null : attrInt(trackEl.first, 'SpareTotal'),
        trackSpareVideo: trackEl.isEmpty ? null : attrInt(trackEl.first, 'SpareVideo'),
        trackSpareAudio: trackEl.isEmpty ? null : attrInt(trackEl.first, 'SpareAudio'),
        trackSpareMetadata: trackEl.isEmpty ? null : attrInt(trackEl.first, 'SpareMetadata'),
      );
    });
  }

  Future<CameraResult<RecordingServiceCapabilities>> getServiceCapabilities({
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final bodyResult = await _post(
      '<trc:GetServiceCapabilities xmlns:trc="http://www.onvif.org/ver10/recording/wsdl"/>',
      timeout,
    );
    return bodyResult.map((body) {
      final doc = XmlDocument.parse(body);
      final el = doc.findAllElements('Capabilities', namespace: '*');
      bool attrBool(String name) =>
          el.isNotEmpty && el.first.getAttribute(name) == 'true';
      double? attrDouble(String name) {
        final v = el.isEmpty ? null : el.first.getAttribute(name);
        return v == null ? null : double.tryParse(v);
      }

      int? attrInt(String name) {
        final v = el.isEmpty ? null : el.first.getAttribute(name);
        return v == null ? null : int.tryParse(v);
      }

      return RecordingServiceCapabilities(
        dynamicRecordings: attrBool('DynamicRecordings'),
        dynamicTracks: attrBool('DynamicTracks'),
        optionsSupported: attrBool('Options'),
        maxRecordings: attrDouble('MaxRecordings'),
        maxRecordingJobs: attrInt('MaxRecordingJobs'),
      );
    });
  }

  RecordingInfo _parseRecordingItem(XmlElement item) {
    final token = _text(item, 'RecordingToken') ?? '';
    final sourceEl = item.findAllElements('Source', namespace: '*');
    final sourceId = sourceEl.isEmpty ? '' : (_text(sourceEl.first, 'SourceId') ?? '');
    final sourceName = sourceEl.isEmpty ? '' : (_text(sourceEl.first, 'Name') ?? '');
    final sourceLocation = sourceEl.isEmpty ? '' : (_text(sourceEl.first, 'Location') ?? '');
    final content = _text(item, 'Content') ?? '';
    final retentionRaw = _text(item, 'MaximumRetentionTime');
    final retentionSeconds = _parsePtSeconds(retentionRaw);

    final tracks = item.findAllElements('Track', namespace: '*').map((trackEl) {
      final trackToken = _text(trackEl, 'TrackToken') ?? '';
      final cfgEl = trackEl.findAllElements('TrackConfiguration', namespace: '*');
      final trackType = cfgEl.isEmpty ? '' : (_text(cfgEl.first, 'TrackType') ?? '');
      final description = cfgEl.isEmpty ? '' : (_text(cfgEl.first, 'Description') ?? '');
      return RecordingTrackInfo(
        trackToken: trackToken,
        trackType: trackType,
        description: description,
      );
    }).toList();

    return RecordingInfo(
      recordingToken: token,
      sourceId: sourceId,
      sourceName: sourceName,
      sourceLocation: sourceLocation,
      content: content,
      maximumRetentionTimeSeconds: retentionSeconds,
      tracks: tracks,
    );
  }

  /// Parses the ISO-8601 `PT<n>S` shape the firmware always emits for
  /// `tt:MaximumRetentionTime` — not a general ISO-8601 duration parser.
  int? _parsePtSeconds(String? raw) {
    if (raw == null) return null;
    final match = RegExp(r'^PT(\d+)S$').firstMatch(raw);
    if (match == null) return null;
    return int.tryParse(match.group(1)!);
  }

  String? _text(XmlElement parent, String tag) {
    final el = parent.findAllElements(tag, namespace: '*');
    return el.isEmpty ? null : el.first.innerText.trim();
  }

  Future<CameraResult<String>> _post(String bodyXml, Duration timeout) async {
    final digest = WsseDigest.generate(connection.password);
    final envelope = '<?xml version="1.0" encoding="UTF-8"?>'
        '<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope">'
        '<s:Header>'
        '<wsse:Security xmlns:wsse="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd">'
        '<wsse:UsernameToken>'
        '<wsse:Username>${connection.username}</wsse:Username>'
        '<wsse:Password Type="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-username-token-profile-1.0#PasswordDigest">'
        '${digest.digestBase64}</wsse:Password>'
        '<wsse:Nonce EncodingType="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-soap-message-security-1.0#Base64Binary">'
        '${digest.nonceBase64}</wsse:Nonce>'
        '<wsu:Created xmlns:wsu="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd">'
        '${digest.createdIso}</wsu:Created>'
        '</wsse:UsernameToken>'
        '</wsse:Security>'
        '</s:Header>'
        '<s:Body>$bodyXml</s:Body>'
        '</s:Envelope>';

    try {
      final response = await _http
          .post(
            connection.onvifRecordingEndpoint,
            headers: const {'Content-Type': 'application/soap+xml; charset=utf-8'},
            body: envelope,
          )
          .timeout(timeout);

      // [AI Fix] 2026-09-24: SOAP-fault check moved before the status-code check -- real bug
      // found via RecordingTimelineScreen's single-playback-session rejection (module_rtsps.c
      // via OperationProhibited/409): this firmware returns a real <Fault> body on a non-200
      // status for some rejections (unlike the Media2-validation-error case soapFaultReason's
      // own doc describes, which is HTTP 200), and the old ordering returned the raw XML fault
      // body as the error string before soapFaultReason() ever got a chance to parse it --
      // exactly the "SOAP response dumped in the UI" symptom this fixes. A fault is checked for
      // on every response regardless of status; the raw "HTTP <code>: <body>" fallback now only
      // fires for a genuinely non-SOAP failure (e.g. a proxy's own 502/503 HTML page).
      final faultReason = soapFaultReason(response.body);
      if (faultReason != null) return CameraFailure(faultReason);

      if (response.statusCode != 200) {
        return CameraFailure('HTTP ${response.statusCode}: ${response.body}');
      }

      return CameraSuccess(response.body);
    } on Exception catch (e) {
      return CameraFailure(e.toString());
    }
  }

  void close() => _http.close();
}

extension _ResultMap<T> on CameraResult<T> {
  CameraResult<R> map<R>(R Function(T value) f) {
    return switch (this) {
      CameraSuccess(:final value) => CameraSuccess<R>(f(value)),
      CameraFailure(:final reason) => CameraFailure<R>(reason),
      CameraTimeout() => CameraTimeout<R>(),
    };
  }
}
