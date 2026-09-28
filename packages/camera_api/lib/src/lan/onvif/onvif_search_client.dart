import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';

import '../../camera_connection.dart';
import '../../camera_result.dart';
import '../insecure_camera_http_client.dart';
import '../wsse_digest.dart';
import 'soap_fault.dart';

/// One matched clip returned by `GetRecordingSearchResults` (`tt:RecordingInformation`,
/// `onvif_search.c`'s `prvGenerateGetRecordingSearchResultsResponse()`).
class RecordingSearchItem {
  const RecordingSearchItem({
    required this.recordingToken,
    required this.earliestRecording,
    required this.latestRecording,
    required this.content,
    required this.recordingStatus,
    required this.trackToken,
    required this.trackType,
    required this.dataFrom,
    required this.dataTo,
  });

  /// Same UTC epoch-start decimal identity as `OnvifRecordingClient.getRecordings()`'s
  /// `recordingToken` and the REST `RecordingsClient`'s `"id"` field.
  final String recordingToken;
  final DateTime earliestRecording;
  final DateTime latestRecording;
  final String content;

  /// `"Recording"` while the clip is still being actively written, `"Stopped"` once finalized
  /// (`tt:RecordingStatus`, mirrors `mp4_recording_info_t.is_active`).
  final String recordingStatus;
  final String trackToken;
  final String trackType;
  final DateTime dataFrom;
  final DateTime dataTo;
}

/// One matched event returned by `GetEventSearchResults` (`tse:Result`,
/// `onvif_search.c`'s `prvGenerateGetEventSearchResultsResponse()`). The firmware does not
/// correlate an event to a specific recording token in this pass — [recordingToken] is always
/// empty, and [source] carries the raw numeric `EventMgr` event ID as text (`tt:Message`'s
/// `tt:Source`), not a human label — flagged here since it's a real, inferred-from-source
/// limitation of the firmware response, not a client-side simplification.
class EventSearchItem {
  const EventSearchItem({
    required this.time,
    required this.recordingToken,
    required this.trackToken,
    required this.source,
  });

  final DateTime time;
  final String recordingToken;
  final String trackToken;
  final String source;
}

class RecordingSearchResults {
  const RecordingSearchResults({required this.items, required this.searchState});

  final List<RecordingSearchItem> items;

  /// `tse:SearchState` — always `"Completed"` on this device: the firmware's search job runs
  /// synchronously to completion inside `FindRecordings`/`FindEvents` itself, before the search
  /// token is even returned (see `onvif_search.c`'s file header comment and `SearchJob_t`'s own
  /// comment). The two-call `Find*` → `Get*SearchResults` shape is still the real wire protocol
  /// this client must speak — the firmware just never reports anything but `"Completed"` for it.
  final String searchState;
}

class EventSearchResults {
  const EventSearchResults({required this.items, required this.searchState});

  final List<EventSearchItem> items;
  final String searchState;
}

class RecordingSummary {
  const RecordingSummary({
    required this.dataFrom,
    required this.dataUntil,
    required this.numberRecordings,
  });

  final DateTime dataFrom;
  final DateTime dataUntil;
  final int numberRecordings;
}

/// `GetServiceCapabilities` response (`tse:Capabilities`, attributes — `nexml_createTag` with a
/// null text value self-closes the tag, same pattern as `OnvifRecordingClient`'s capabilities).
/// `GeneralStartEvents`/`NLSearch`/`ImageSearch` are hardcoded `false` firmware-side
/// (`onvif_search.c`), not camera-state-derived — reported here anyway rather than assumed, in
/// case a future firmware build changes that.
class SearchServiceCapabilities {
  const SearchServiceCapabilities({
    required this.metadataSearch,
    required this.generalStartEvents,
    required this.nlSearch,
    required this.imageSearch,
  });

  final bool metadataSearch;
  final bool generalStartEvents;
  final bool nlSearch;
  final bool imageSearch;
}

/// LAN-only ONVIF Search client (`/onvif/search`, SOAP, WS-UsernameToken digest auth) — Profile
/// G's search half (`FR-OV-081`). **Client-only for now**, same scope note as
/// `OnvifRecordingClient` — not wired into any screen, parallel to the existing REST path.
///
/// This speaks the real two-call async-job protocol (`FindRecordings`/`FindEvents` → returns a
/// `SearchToken`, then `GetRecordingSearchResults`/`GetEventSearchResults` pages results out by
/// that token) even though the firmware's job actually always completes synchronously
/// underneath — see [RecordingSearchResults.searchState]'s doc. A future firmware change to make
/// search genuinely asynchronous would not require any change to this client's call shape.
class OnvifSearchClient {
  OnvifSearchClient(this.connection, {http.Client? httpClient})
      : _http = httpClient ?? createCameraHttpClient();

  final CameraConnection connection;
  final http.Client _http;

  Future<CameraResult<SearchServiceCapabilities>> getServiceCapabilities({
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final bodyResult = await _post(
      '<tse:GetServiceCapabilities xmlns:tse="http://www.onvif.org/ver10/search/wsdl"/>',
      timeout,
    );
    return bodyResult.map((body) {
      final doc = XmlDocument.parse(body);
      final el = doc.findAllElements('Capabilities', namespace: '*');
      bool attrBool(String name) =>
          el.isNotEmpty && el.first.getAttribute(name) == 'true';
      return SearchServiceCapabilities(
        metadataSearch: attrBool('MetadataSearch'),
        generalStartEvents: attrBool('GeneralStartEvents'),
        nlSearch: attrBool('NLSearch'),
        imageSearch: attrBool('ImageSearch'),
      );
    });
  }

  /// Starts a recording search over `[startTime, endTime]` (either bound may be omitted — the
  /// firmware's `prvParseOptionalTimeRange()` tolerates a missing `StartPoint`/`EndPoint` and
  /// treats it as `0`/unbounded). Returns the `SearchToken` to page results with via
  /// [getRecordingSearchResults]. The real ONVIF `FindRecordings` request also carries `Scope`,
  /// `MaxMatches`, and `KeepAliveTime` fields — the firmware ignores all three (its own request
  /// handling never reads them, per `onvif_search.c`'s switch case), so this client does not
  /// send them; flagged as an inferred wire-format simplification, not confirmed against a real
  /// multi-scope ONVIF client.
  Future<CameraResult<String>> findRecordings({
    DateTime? startTime,
    DateTime? endTime,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final buf = StringBuffer('<tse:FindRecordings xmlns:tse="http://www.onvif.org/ver10/search/wsdl">');
    if (startTime != null) buf.write('<tse:StartPoint>${_toIso8601(startTime)}</tse:StartPoint>');
    if (endTime != null) buf.write('<tse:EndPoint>${_toIso8601(endTime)}</tse:EndPoint>');
    buf.write('</tse:FindRecordings>');

    final bodyResult = await _post(buf.toString(), timeout);
    return bodyResult.map((body) {
      final doc = XmlDocument.parse(body);
      return _docText(doc, 'SearchToken') ?? '';
    });
  }

  Future<CameraResult<RecordingSearchResults>> getRecordingSearchResults(
    String searchToken, {
    int maxResults = 32,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final bodyResult = await _post(
      '<tse:GetRecordingSearchResults xmlns:tse="http://www.onvif.org/ver10/search/wsdl">'
      '<tse:SearchToken>$searchToken</tse:SearchToken>'
      '<tse:MaxResults>$maxResults</tse:MaxResults>'
      '</tse:GetRecordingSearchResults>',
      timeout,
    );
    return bodyResult.map((body) {
      final doc = XmlDocument.parse(body);
      final items = doc.findAllElements('RecordingInformation', namespace: '*').map((el) {
        final trackEl = el.findAllElements('Track', namespace: '*');
        return RecordingSearchItem(
          recordingToken: _text(el, 'RecordingToken') ?? '',
          earliestRecording: _dateTime(_text(el, 'EarliestRecording')),
          latestRecording: _dateTime(_text(el, 'LatestRecording')),
          content: _text(el, 'Content') ?? '',
          recordingStatus: _text(el, 'RecordingStatus') ?? '',
          trackToken: trackEl.isEmpty ? '' : (_text(trackEl.first, 'TrackToken') ?? ''),
          trackType: trackEl.isEmpty ? '' : (_text(trackEl.first, 'TrackType') ?? ''),
          dataFrom: trackEl.isEmpty ? _dateTime(null) : _dateTime(_text(trackEl.first, 'DataFrom')),
          dataTo: trackEl.isEmpty ? _dateTime(null) : _dateTime(_text(trackEl.first, 'DataTo')),
        );
      }).toList();
      final searchState = _docText(doc, 'SearchState') ?? '';
      return RecordingSearchResults(items: items, searchState: searchState);
    });
  }

  /// Same time-range/omitted-params caveats as [findRecordings] apply to `FindEvents`.
  Future<CameraResult<String>> findEvents({
    DateTime? startTime,
    DateTime? endTime,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final buf = StringBuffer('<tse:FindEvents xmlns:tse="http://www.onvif.org/ver10/search/wsdl">');
    if (startTime != null) buf.write('<tse:StartPoint>${_toIso8601(startTime)}</tse:StartPoint>');
    if (endTime != null) buf.write('<tse:EndPoint>${_toIso8601(endTime)}</tse:EndPoint>');
    buf.write('</tse:FindEvents>');

    final bodyResult = await _post(buf.toString(), timeout);
    return bodyResult.map((body) {
      final doc = XmlDocument.parse(body);
      return _docText(doc, 'SearchToken') ?? '';
    });
  }

  Future<CameraResult<EventSearchResults>> getEventSearchResults(
    String searchToken, {
    int maxResults = 32,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final bodyResult = await _post(
      '<tse:GetEventSearchResults xmlns:tse="http://www.onvif.org/ver10/search/wsdl">'
      '<tse:SearchToken>$searchToken</tse:SearchToken>'
      '<tse:MaxResults>$maxResults</tse:MaxResults>'
      '</tse:GetEventSearchResults>',
      timeout,
    );
    return bodyResult.map((body) {
      final doc = XmlDocument.parse(body);
      final items = doc.findAllElements('Result', namespace: '*').map((el) {
        final msgEl = el.findAllElements('Message', namespace: '*');
        return EventSearchItem(
          time: _dateTime(el.getAttribute('Time')),
          recordingToken: el.getAttribute('RecordingToken') ?? '',
          trackToken: el.getAttribute('TrackToken') ?? '',
          source: msgEl.isEmpty ? '' : (_text(msgEl.first, 'Source') ?? ''),
        );
      }).toList();
      final searchState = _docText(doc, 'SearchState') ?? '';
      return EventSearchResults(items: items, searchState: searchState);
    });
  }

  Future<CameraResult<RecordingSummary>> getRecordingSummary({
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final bodyResult = await _post(
      '<tse:GetRecordingSummary xmlns:tse="http://www.onvif.org/ver10/search/wsdl"/>',
      timeout,
    );
    return bodyResult.map((body) {
      final doc = XmlDocument.parse(body);
      final el = doc.findAllElements('Summary', namespace: '*');
      final summaryEl = el.isEmpty ? doc.rootElement : el.first;
      return RecordingSummary(
        dataFrom: _dateTime(_text(summaryEl, 'DataFrom')),
        dataUntil: _dateTime(_text(summaryEl, 'DataUntil')),
        numberRecordings: int.tryParse(_text(summaryEl, 'NumberRecordings') ?? '') ?? 0,
      );
    });
  }

  /// `tse:GetSearchState` — always `"Completed"` on this device, see
  /// [RecordingSearchResults.searchState]'s doc.
  Future<CameraResult<String>> getSearchState(
    String searchToken, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final bodyResult = await _post(
      '<tse:GetSearchState xmlns:tse="http://www.onvif.org/ver10/search/wsdl">'
      '<tse:SearchToken>$searchToken</tse:SearchToken>'
      '</tse:GetSearchState>',
      timeout,
    );
    return bodyResult.map((body) {
      final doc = XmlDocument.parse(body);
      return _docText(doc, 'State') ?? '';
    });
  }

  /// Frees the search job slot on the camera (`onvif_search.c` has a fixed pool of
  /// `ONVIF_MAX_SEARCH_JOBS = 2` slots — an un-ended job leaks a slot until reused/reset).
  /// Returns the `tse:Endpoint` timestamp the firmware reports (its own current time, not the
  /// search's actual end point — see `prvGenerateEndSearchResponse()`'s use of `rtc_read()`).
  Future<CameraResult<DateTime>> endSearch(
    String searchToken, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final bodyResult = await _post(
      '<tse:EndSearch xmlns:tse="http://www.onvif.org/ver10/search/wsdl">'
      '<tse:SearchToken>$searchToken</tse:SearchToken>'
      '</tse:EndSearch>',
      timeout,
    );
    return bodyResult.map((body) {
      final doc = XmlDocument.parse(body);
      return _dateTime(_docText(doc, 'Endpoint'));
    });
  }

  /// Formats a UTC dateTime the way `prvIso8601ToEpoch()`/`prvEpochToIso8601()` expect:
  /// `YYYY-MM-DDTHH:MM:SSZ` (no fractional seconds, no non-`Z` offset — the firmware ignores
  /// any offset it does see, per that function's own comment, so this client never sends one).
  String _toIso8601(DateTime dt) {
    final utc = dt.toUtc();
    String p2(int v) => v.toString().padLeft(2, '0');
    return '${utc.year.toString().padLeft(4, '0')}-${p2(utc.month)}-${p2(utc.day)}'
        'T${p2(utc.hour)}:${p2(utc.minute)}:${p2(utc.second)}Z';
  }

  /// Parses the same `YYYY-MM-DDTHH:MM:SSZ` shape back into a [DateTime]; falls back to the
  /// Unix epoch on `null`/unparseable input (mirrors the firmware's own "epoch 0" fallback in
  /// `prvGenerateGetRecordingSummaryResponse()` when there are no recordings at all).
  DateTime _dateTime(String? raw) {
    if (raw == null) return DateTime.utc(1970);
    return DateTime.tryParse(raw)?.toUtc() ?? DateTime.utc(1970);
  }

  String? _text(XmlElement parent, String tag) {
    final el = parent.findAllElements(tag, namespace: '*');
    return el.isEmpty ? null : el.first.innerText.trim();
  }

  /// Same as [_text] but scoped to the whole parsed document — used for the single-child-value
  /// responses (`SearchToken`, `SearchState`, `State`, `Endpoint`) where there's no natural
  /// element to scope the lookup to besides the document itself, matching
  /// `onvif_soap_generateOneChildTagResponse()`'s flat one-tag-under-the-response-root shape.
  String? _docText(XmlDocument doc, String tag) {
    final el = doc.findAllElements(tag, namespace: '*');
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
            connection.onvifSearchEndpoint,
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
