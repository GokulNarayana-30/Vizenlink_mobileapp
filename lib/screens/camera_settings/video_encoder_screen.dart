import 'package:camera_api/camera_api.dart';

import '../../app_state/camera_network.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../app_state/homes_controller.dart';
import '../../models/camera.dart';
import '../../widgets/glass_card.dart';
import '../../widgets/gradient_background.dart';
import 'video_stream_encoder_screen.dart';

String _resolutionLabel(Resolution resolution) =>
    '${resolution.width}×${resolution.height}';

/// One-line summary of a stream's current settings, for a landing row's
/// subtitle — e.g. "1080p · H.265 · 4.0 Mbps · 15 fps".
String _streamSummary(StreamEncoderConfig c) {
  final codec = c.encoderType == CameraEncoderType.h265 ? 'H.265' : 'H.264';
  final mbps = c.bitrateKbps / 1000;
  final bitrate = mbps >= 1
      ? '${mbps.toStringAsFixed(mbps.truncateToDouble() == mbps ? 0 : 1)} Mbps'
      : '${c.bitrateKbps.round()} kbps';
  return '${_resolutionLabel(c.resolution)} · $codec · $bitrate · '
      '${c.frameRate.round()} fps';
}

/// The encoder-config token backing each stream — the same mapping
/// `video_stream_encoder_screen.dart` uses to address a config, here used in
/// reverse to decide which streams the camera actually has.
const _tokenForStream = {
  VideoStream.highRes: kHighResVideoEncoderToken,
  VideoStream.medium: kMediumResVideoEncoderToken,
  VideoStream.low: kLowResVideoEncoderToken,
};

const _titleForStream = {
  VideoStream.highRes: 'High-res stream',
  VideoStream.medium: 'Medium stream',
  VideoStream.low: 'Low stream',
};

const _keyForStream = {
  VideoStream.highRes: Key('ENC-019'),
  VideoStream.medium: Key('ENC-020'),
  VideoStream.low: Key('ENC-021'),
};

/// Video Encoder landing list — one row per encoder stream the camera
/// actually reports, discovered via `OnvifVideoEncoderClient.getProfiles()`
/// rather than assumed to be exactly three (`SETTINGS_API_GUIDE.md`: never
/// hardcode a count or a `VideoEncoderCfg_N` list). Until that call resolves,
/// and on any camera with no saved connection or a failed lookup, all three
/// known streams are listed — the previous unconditional behavior. Tapping a
/// row opens [VideoStreamEncoderScreen] scoped to that stream. See
/// `docs/screens/camera_settings/video_display/video_encoder_screen.md`.
class VideoEncoderScreen extends StatefulWidget {
  const VideoEncoderScreen({
    super.key,
    required this.camera,
    required this.homesController,
  });

  static const routeName = 'video-encoder';

  final Camera camera;
  final HomesController homesController;

  @override
  State<VideoEncoderScreen> createState() => _VideoEncoderScreenState();
}

class _VideoEncoderScreenState extends State<VideoEncoderScreen> {
  /// Streams the camera confirmed it has. Null means "not known" — still
  /// loading, no saved connection, or the lookup failed — in which case all
  /// three are shown rather than hiding real streams on a bad round trip.
  List<VideoStream>? _availableStreams;

  @override
  void initState() {
    super.initState();
    _loadProfiles();
  }

  Future<void> _loadProfiles() async {
    final connection = widget.camera.connection;
    if (connection == null) return;
    final client = OnvifVideoEncoderClient(
      connection,
      httpClient: CameraNetwork.clientFor(connection.host),
      endpoint: CameraNetwork.media2EndpointFor(connection.host),
    );
    final result = await client.getProfiles();
    CameraNetwork.rememberMedia2Endpoint(
      connection.host,
      client.resolvedEndpoint,
    );
    client.close();
    if (!mounted || result is! CameraSuccess<List<MediaProfile>>) return;
    final reported = {for (final p in result.value) p.videoEncoderConfigToken};
    final streams = [
      for (final stream in VideoStream.values)
        if (reported.contains(_tokenForStream[stream])) stream,
    ];
    // An empty result would blank the screen — treat it as "unknown" and keep
    // showing all three rather than claiming this camera has no streams.
    if (streams.isEmpty) return;
    setState(() => _availableStreams = streams);
  }

  Camera get _camera {
    for (final home in widget.homesController.value.homes) {
      for (final c in home.cameras) {
        if (c.id == widget.camera.id) return c;
      }
    }
    return widget.camera;
  }

  void _openStream(BuildContext context, VideoStream stream) {
    context.push(
      '${GoRouterState.of(context).matchedLocation}/'
      '${VideoStreamEncoderScreen.routeName}',
      extra: (camera: _camera, stream: stream),
    );
  }

  @override
  Widget build(BuildContext context) {
    final streams = _availableStreams ?? VideoStream.values;
    return GradientBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          key: const Key('ENC-001'),
          title: const Text('Video Encoder'),
        ),
        body: AnimatedBuilder(
          animation: widget.homesController,
          builder: (context, _) {
            final cam = _camera;
            return ListView(
              padding: const EdgeInsets.all(16),
              children: [
                for (final stream in streams) ...[
                  if (stream != streams.first) const SizedBox(height: 12),
                  _StreamRow(
                    settingsKey: _keyForStream[stream]!,
                    title: _titleForStream[stream]!,
                    summary: _streamSummary(cam.encoderConfigFor(stream)),
                    onTap: () => _openStream(context, stream),
                  ),
                ],
              ],
            );
          },
        ),
      ),
    );
  }
}

class _StreamRow extends StatelessWidget {
  const _StreamRow({
    required this.settingsKey,
    required this.title,
    required this.summary,
    required this.onTap,
  });

  final Key settingsKey;
  final String title;
  final String summary;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return GlassCard(
      padding: EdgeInsets.zero,
      child: ListTile(
        key: settingsKey,
        leading: const Icon(Icons.videocam_outlined),
        title: Text(title),
        subtitle: Text(summary),
        trailing: Icon(
          Icons.chevron_right,
          color: colorScheme.onSurfaceVariant,
        ),
        onTap: onTap,
      ),
    );
  }
}
