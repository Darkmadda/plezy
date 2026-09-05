import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/screens/video_player_screen.dart';

void main() {
  const eligible = (
    isAndroid: true,
    isHandheld: true,
    isTv: false,
    isAutomotive: false,
    isLive: false,
    inWatchTogetherSession: false,
    backgroundAudioEnabled: true,
  );

  bool decide({
    bool? isAndroid,
    bool? isHandheld,
    bool? isTv,
    bool? isAutomotive,
    bool? isLive,
    bool? inWatchTogetherSession,
    bool? backgroundAudioEnabled,
  }) => shouldContinueAudioInBackground(
    isAndroid: isAndroid ?? eligible.isAndroid,
    isHandheld: isHandheld ?? eligible.isHandheld,
    isTv: isTv ?? eligible.isTv,
    isAutomotive: isAutomotive ?? eligible.isAutomotive,
    isLive: isLive ?? eligible.isLive,
    inWatchTogetherSession: inWatchTogetherSession ?? eligible.inWatchTogetherSession,
    backgroundAudioEnabled: backgroundAudioEnabled ?? eligible.backgroundAudioEnabled,
  );

  test('handheld Android VOD with the setting on continues audio', () {
    expect(decide(), isTrue);
  });

  test('only Android handhelds qualify', () {
    expect(decide(isAndroid: false), isFalse);
    expect(decide(isHandheld: false), isFalse);
    // TV releases its AV pipeline for shared decoder hardware; Automotive
    // pauses for driver-distraction rules. Both outrank the handheld flag.
    expect(decide(isTv: true), isFalse);
    expect(decide(isAutomotive: true), isFalse);
  });

  test('live TV and Watch Together keep their pause-on-background behavior', () {
    expect(decide(isLive: true), isFalse);
    expect(decide(inWatchTogetherSession: true), isFalse);
  });

  test('the setting is the kill switch', () {
    expect(decide(backgroundAudioEnabled: false), isFalse);
  });

  test('background audio never overlaps the background-pause policy', () {
    // Every combination that continues audio must be one the pause policy
    // would otherwise have paused — continuing is strictly an exemption.
    for (final isTv in [true, false]) {
      for (final isAutomotive in [true, false]) {
        if (decide(isTv: isTv, isAutomotive: isAutomotive)) {
          expect(
            shouldPauseVideoForBackground(isHandheld: true, isTv: isTv, isAutomotive: isAutomotive),
            isTrue,
          );
        }
      }
    }
  });
}
