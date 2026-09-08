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
