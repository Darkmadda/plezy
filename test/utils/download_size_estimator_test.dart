import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/media_part.dart';
import 'package:plezy/media/media_version.dart';
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

  group('transcodeEstimateMeetsOriginal', () {
    // 1 h at 4000 kbps video + 192 kbps audio → (4192 × 3_600_000 / 8)
    // = 1_886_400_000 bytes, matching the picker's displayed estimate.
    const preset = TranscodeQualityPreset.p720_4mbps;
    const durationMs = 60 * 60 * 1000;
    const estimatedBytes = 1886400000;

    test('matches the unpadded displayed estimate, not the padded free-space one', () {
      expect(estimateDisplayedTranscodeBytes(preset: preset, durationMs: durationMs), estimatedBytes);
      expect(
        estimateTranscodedDownloadBytes(preset: preset, durationMs: durationMs),
        greaterThan(estimatedBytes),
      );
    });

    test('swaps when the real source file is the same size or smaller', () {
      expect(
        transcodeEstimateMeetsOriginal(preset: preset, sourceSizeBytes: estimatedBytes - 1, durationMs: durationMs),
        isTrue,
      );
      expect(
        transcodeEstimateMeetsOriginal(preset: preset, sourceSizeBytes: estimatedBytes, durationMs: durationMs),
        isTrue,
      );
    });

    test('keeps the preset when the source file is larger', () {
      expect(
        transcodeEstimateMeetsOriginal(preset: preset, sourceSizeBytes: estimatedBytes + 1, durationMs: durationMs),
        isFalse,
      );
    });

    test('falls back to source bitrate × duration when the real size is unknown', () {
      // 3000 kbps source → 1_350_000_000 bytes < estimate → swap.
      expect(transcodeEstimateMeetsOriginal(preset: preset, sourceBitrateKbps: 3000, durationMs: durationMs), isTrue);
      // 8000 kbps source → 3_600_000_000 bytes > estimate → keep preset.
      expect(transcodeEstimateMeetsOriginal(preset: preset, sourceBitrateKbps: 8000, durationMs: durationMs), isFalse);
    });

    test('never swaps blind: unknown source, unknown duration, or Original preset', () {
      expect(transcodeEstimateMeetsOriginal(preset: preset, durationMs: durationMs), isFalse);
      expect(transcodeEstimateMeetsOriginal(preset: preset, sourceSizeBytes: 1, durationMs: null), isFalse);
      expect(
        transcodeEstimateMeetsOriginal(
          preset: TranscodeQualityPreset.original,
          sourceSizeBytes: 1,
          durationMs: durationMs,
        ),
        isFalse,
      );
    });
  });

  group('versionSizeBytes', () {
    test('sums all parts and rejects any missing or invalid part size', () {
      expect(
        versionSizeBytes(
          const MediaVersion(
            id: 'v',
            parts: [MediaPart(id: 'a', sizeBytes: 100), MediaPart(id: 'b', sizeBytes: 200)],
          ),
        ),
        300,
      );
      for (final invalid in <int?>[null, 0, -1]) {
        expect(
          versionSizeBytes(
            MediaVersion(
              id: 'v',
              parts: [const MediaPart(id: 'a', sizeBytes: 100), MediaPart(id: 'b', sizeBytes: invalid)],
            ),
          ),
          isNull,
        );
      }
      expect(versionSizeBytes(null), isNull);
      expect(versionSizeBytes(const MediaVersion(id: 'v', parts: [])), isNull);
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
