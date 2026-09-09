import '../media/media_item.dart';
import '../media/media_stream.dart';
import '../media/media_version.dart';
import '../models/transcode_quality_preset.dart';
import 'codec_utils.dart';
import 'quality_preset_labels.dart';
import 'resolution_label.dart';
import 'formatters.dart';

List<String> buildMediaQualityLabels(MediaItem item, {int versionIndex = 0}) {
  final version = _selectedVersion(item.mediaVersions, versionIndex);
  if (version == null) return const [];

  final labels = <String>[];
  final resolution = _formatResolution(version);
  if (resolution != null) labels.add(resolution);

  final video = _firstStreamOfKind(version, MediaStreamKind.video);
  if (video?.dolbyVision == true) {
    labels.add(_formatDolbyVision(video!));
  } else if (video?.hdr == true) {
    labels.add('HDR');
  }

  final audio = _selectedAudioStream(version);
  final audioLabel = _formatAudio(audio);
  if (audioLabel != null) labels.add(audioLabel);

  return labels;
}

/// Chip labels for a media card, preferring what is actually on disk.
///
/// A completed download at original quality keeps the source chips but swaps
/// in the real on-disk size. A completed transcoded download replaces the
/// chips with its preset label — the source's resolution/HDR/audio no longer
/// describe the downloaded file. Anything not (yet) downloaded falls through
/// to the source metadata, including its server-reported size.
List<String> buildDownloadAwareQualityLabels(
  MediaItem item, {
  bool downloadCompleted = false,
  int downloadTotalBytes = 0,
  String? downloadQualityPreset,
  int versionIndex = 0,
}) {
  if (!downloadCompleted) {
    return [
      ...buildMediaQualityLabels(item, versionIndex: versionIndex),
      ?buildMediaSizeLabel(item, versionIndex: versionIndex),
    ];
  }
  final preset = TranscodeQualityPreset.fromName(downloadQualityPreset);
  final sizeLabel = downloadTotalBytes > 0 ? ByteFormatter.formatBytes(downloadTotalBytes) : null;
  if (preset.isOriginal) {
    return [
      ...buildMediaQualityLabels(item, versionIndex: versionIndex),
      ?(sizeLabel ?? buildMediaSizeLabel(item, versionIndex: versionIndex)),
    ];
  }
  return [qualityPresetLabel(preset), ?sizeLabel];
}

String? buildMediaSizeLabel(MediaItem item, {int versionIndex = 0}) {
  final version = _selectedVersion(item.mediaVersions, versionIndex);
  if (version == null || version.parts.isEmpty) return null;

  var totalBytes = 0;
  for (final part in version.parts) {
    final sizeBytes = part.sizeBytes;
    if (sizeBytes == null || sizeBytes <= 0) return null;
    totalBytes += sizeBytes;
  }

  return ByteFormatter.formatBytes(totalBytes);
}

String _formatDolbyVision(MediaStream stream) {
  final profile = stream.dolbyVisionProfile;
  return profile == null || profile <= 0 ? 'DV' : 'DV P$profile';
}

MediaVersion? _selectedVersion(List<MediaVersion>? versions, int versionIndex) {
  if (versions == null || versions.isEmpty) return null;
  if (versionIndex >= 0 && versionIndex < versions.length) {
    return versions[versionIndex];
  }
  return versions.first;
}

String? _formatResolution(MediaVersion version) {
  final raw = version.videoResolution?.trim();
  if (raw != null && raw.isNotEmpty) return resolutionDisplayLabel(raw);

  final fallback = resolutionLabelFromDimensions(version.width, version.height);
  return fallback == null ? null : resolutionDisplayLabel(fallback);
}

MediaStream? _firstStreamOfKind(MediaVersion version, MediaStreamKind kind) {
  for (final part in version.parts) {
    for (final stream in part.streams) {
      if (stream.kind == kind) return stream;
    }
  }
  return null;
}

MediaStream? _selectedAudioStream(MediaVersion version) {
  MediaStream? first;
  for (final part in version.parts) {
    for (final stream in part.streams) {
      if (stream.kind != MediaStreamKind.audio) continue;
      first ??= stream;
      if (stream.selected) return stream;
    }
  }
  return first;
}

String? _formatAudio(MediaStream? stream) {
  if (stream == null) return null;

  final parts = <String>[];
  final codec = stream.codec?.trim();
  if (codec != null && codec.isNotEmpty) parts.add(_formatAudioCodec(codec));

  if (_isAtmos(stream)) {
    parts.add('Atmos');
  } else {
    final channels = CodecUtils.formatAudioChannels(stream.channels);
    if (channels != null) parts.add(channels);
  }

  return parts.isEmpty ? null : parts.join(' ');
}

String _formatAudioCodec(String codec) {
  return switch (codec.toLowerCase()) {
    'eac3' || 'ec3' => 'EAC3',
    'ac3' => 'AC3',
    _ => CodecUtils.formatAudioCodec(codec),
  };
}

bool _isAtmos(MediaStream stream) {
  return [
    stream.codec,
    stream.title,
    stream.displayTitle,
  ].whereType<String>().any((value) => value.toLowerCase().contains('atmos'));
}
