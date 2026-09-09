import '../media/media_version.dart';
import '../models/transcode_quality_preset.dart';

/// Audio allowance folded into the estimate: quality presets cap only the
/// video stream, and a transcoded download carries one audio track (AAC/AC3
/// well under this ceiling).
const int _audioAllowanceKbps = 256;

/// Container/muxing overhead pad. The bitrate cap is an upper bound the
/// encoder undershoots, so a small pad keeps the estimate a soft ceiling
/// without wildly overstating the free-space requirement.
const double _containerOverheadFactor = 1.08;

/// Estimated on-disk size of a transcoded download, or null when the preset
/// is Original (real file size is known elsewhere) or the duration is
/// unknown. A live transcode stream has no Content-Length, so this estimate
/// is what the progress UI and the free-space preflight work against.
int? estimateTranscodedDownloadBytes({required TranscodeQualityPreset preset, required int? durationMs}) {
  final videoKbps = preset.videoBitrateKbps;
  if (videoKbps == null || durationMs == null || durationMs <= 0) return null;
  // kbps × ms / 8 = bytes (1000 bits/s × s / 8 bits-per-byte).
  final payloadBytes = (videoKbps + _audioAllowanceKbps) * durationMs ~/ 8;
  return (payloadBytes * _containerOverheadFactor).round();
}

/// Audio allowance for the *displayed* estimate — the quality picker's size
/// hint. Unpadded and lower than [_audioAllowanceKbps]: the picker aims for a
/// realistic middle figure, not the free-space soft ceiling above.
const int _displayedAudioEstimateKbps = 192;

/// The unpadded transcode-size estimate behind the quality picker's
/// "3.6 GB (45%)" hint. Also drives [transcodeEstimateMeetsOriginal] so the
/// picker's displayed percentage and the fall-back-to-original decision can
/// never disagree.
int? estimateDisplayedTranscodeBytes({required TranscodeQualityPreset preset, required int? durationMs}) {
  final videoKbps = preset.videoBitrateKbps;
  if (videoKbps == null || durationMs == null || durationMs <= 0) return null;
  return (videoKbps + _displayedAudioEstimateKbps) * durationMs ~/ 8;
}

/// The source-size figure transcode estimates are compared against: the real
/// file size when known, otherwise source bitrate × duration. Null when
/// neither is known.
int? estimateSourceBytes({int? sourceSizeBytes, int? sourceBitrateKbps, int? durationMs}) {
  if (sourceSizeBytes != null && sourceSizeBytes > 0) return sourceSizeBytes;
  if (sourceBitrateKbps != null && sourceBitrateKbps > 0 && durationMs != null && durationMs > 0) {
    return sourceBitrateKbps * durationMs ~/ 8;
  }
  return null;
}

/// Whether downloading [preset] is expected to produce a file at least as
/// large as the original. A transcode can never beat its source's quality, so
/// when this returns true the original is the strictly better download —
/// equal-or-better quality at no extra size. Returns false for the Original
/// preset and whenever either side of the comparison is unknown (never swap
/// blind).
bool transcodeEstimateMeetsOriginal({
  required TranscodeQualityPreset preset,
  int? sourceSizeBytes,
  int? sourceBitrateKbps,
  int? durationMs,
}) {
  final estimate = estimateDisplayedTranscodeBytes(preset: preset, durationMs: durationMs);
  final source = estimateSourceBytes(
    sourceSizeBytes: sourceSizeBytes,
    sourceBitrateKbps: sourceBitrateKbps,
    durationMs: durationMs,
  );
  return estimate != null && source != null && estimate >= source;
}

/// Total real size of a version's parts, or null when any part lacks one —
/// a partial sum would understate the file and skew size comparisons.
int? versionSizeBytes(MediaVersion? version) {
  if (version == null || version.parts.isEmpty) return null;
  var total = 0;
  for (final part in version.parts) {
    final sizeBytes = part.sizeBytes;
    if (sizeBytes == null || sizeBytes <= 0) return null;
    total += sizeBytes;
  }
  return total > 0 ? total : null;
}
