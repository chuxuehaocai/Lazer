import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lazer_nextgen/data/lyrics.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/player/now_playing_page.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/theme/font_preferences.dart';

import 'support/serialized_semantics.dart';

class _State extends AppState {
  _State() {
    lyrics = parseLrc(
      '[00:00.00]First lyric\n[00:04.00]Second lyric\n[00:08.00]Third lyric',
    );
  }
  @override
  Track? get current => const Track(
    id: 'accessible',
    title: 'Accessible player',
    artist: 'Artist',
    album: 'Album',
    duration: Duration(minutes: 2),
    coverSeed: 1,
  );
  @override
  Future<void> ensureCurrentLyrics({bool force = false}) async {}
}

void main() {
  final binding = RecordingSemanticsBinding();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    binding.recorder.reset();
  });
  tearDown(() => binding.recorder.enabled = false);

  for (final width in [390.0, 1280.0]) {
    testWidgets(
      'animated controls keep every serialized AX node connected at $width',
      (tester) async {
        tester.view.physicalSize = Size(width, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final semantics = tester.ensureSemantics();
        final state = _State()..showArtworkWithLyrics = true;
        addTearDown(state.dispose);
        state.lyricControlsSeconds = 1;
        await tester.pumpWidget(
          MaterialApp(home: NowPlayingPage(state: state)),
        );
        await tester.pump();
        Future<void> frames(int count) async {
          for (int i = 0; i < count; i++) {
            await tester.pump(const Duration(milliseconds: 16));
          }
        }

        if (width >= 720) {
          for (int cycle = 0; cycle < 3; cycle++) {
            await tester.tap(
              find.byKey(const ValueKey('legacy-now-playing-cover')),
            );
            await frames(20);
            await tester.tap(find.byKey(const ValueKey('desktop-queue')));
            await frames(20);
            await tester.tap(find.byKey(const ValueKey('desktop-lyrics')));
            await frames(20);
            state.seek(.04 * (cycle + 1));
            await frames(85);
          }
        } else {
          for (int cycle = 0; cycle < 3; cycle++) {
            await tester.tap(
              find.byKey(const ValueKey('legacy-now-playing-cover')),
            );
            await frames(30);
            state.seek(.04 * (cycle + 1));
            await frames(85);
            await tester.tap(
              find.byKey(const ValueKey('compact-player-summary')),
            );
            await frames(25);
            await state.setFontCustomization(
              FontCategory.playerTitle,
              FontCustomization(
                scale: 1 + cycle * .1,
                weight: 400 + cycle * 100,
              ),
            );
            await frames(3);
            await tester.tap(
              find.byKey(const ValueKey('legacy-now-playing-cover')),
            );
            await frames(30);
          }
        }
        expect(binding.recorder.commits, greaterThan(20));
        expect(
          binding.recorder.errors,
          isEmpty,
          reason:
              'AXTree rejects orphan updates, even if the final Flutter tree is valid',
        );
        expect(tester.takeException(), isNull);
        binding.recorder.enabled = false;
        await tester.pumpWidget(const SizedBox.shrink());
        semantics.dispose();
      },
    );
  }
}
