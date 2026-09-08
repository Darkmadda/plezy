import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/models/transcode_quality_preset.dart';
import 'package:plezy/utils/download_size_estimator.dart';

void main() {
  group('estimateTranscodedDownloadBytes', () {
    test('estimates video cap + audio allowance with container pad', () {
      // 45 min at 2000 kbps video + 256 kbps audio: (2256 kbps × 2_700_000 ms
      // / 8) = 761_400_000 payload bytes, ×1.08 pad.
      final bytes = estimateTranscodedDownloadBytes(
        preset: TranscodeQualityPreset.p720_2mbps,
        durationMs: 45 * 60 * 1000,
      );
      expect(bytes, (761400000 * 1.08).round());
    });

    test('scales with the preset bitrate', () {
      const durationMs = 60 * 60 * 1000;
      final low = estimateTranscodedDownloadBytes(preset: TranscodeQualityPreset.p480_1_5mbps, durationMs: durationMs);
      final high = estimateTranscodedDownloadBytes(preset: TranscodeQualityPreset.p1080_8mbps, durationMs: durationMs);
      expect(low, isNotNull);
      expect(high, isNotNull);
      expect(high!, greaterThan(low!));
    });

    test('returns null for the original preset — real file size is known elsewhere', () {
      expect(estimateTranscodedDownloadBytes(preset: TranscodeQualityPreset.original, durationMs: 1000), isNull);
    });

    test('returns null without a usable duration', () {
      expect(estimateTranscodedDownloadBytes(preset: TranscodeQualityPreset.p720_2mbps, durationMs: null), isNull);
      expect(estimateTranscodedDownloadBytes(preset: TranscodeQualityPreset.p720_2mbps, durationMs: 0), isNull);
      expect(estimateTranscodedDownloadBytes(preset: TranscodeQualityPreset.p720_2mbps, durationMs: -5), isNull);
    });
  });

  group('TranscodeQualityPreset.fromName', () {
    test('round-trips every preset by name', () {
      for (final preset in TranscodeQualityPreset.values) {
        expect(TranscodeQualityPreset.fromName(preset.name), preset);
      }
    });

    test('falls back to original for null and unknown names', () {
      expect(TranscodeQualityPreset.fromName(null), TranscodeQualityPreset.original);
      expect(TranscodeQualityPreset.fromName('p999_removed'), TranscodeQualityPreset.original);
    });
  });
}
