import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/player/desktop_now_playing.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/theme/apple_design.dart';
import 'package:lazer_nextgen/tv/tv_mode.dart';
import 'package:lazer_nextgen/widgets/volume_control.dart';

const _track = Track(
  id: 'fixture',
  title: 'A song',
  artist: 'Artist',
  album: 'Album',
  duration: Duration(minutes: 3),
  coverSeed: 2,
);

class _PlayerState extends AppState {
  int toggles = 0;

  @override
  Track get current => _track;

  @override
  bool get playing => toggles.isOdd;

  @override
  void togglePlay() {
    toggles++;
    notifyListeners();
  }
}

void main() {
  for (final mode in [
    (remote: false, largeScreen: false),
    (remote: true, largeScreen: true),
    (remote: true, largeScreen: false),
  ]) {
    testWidgets('player transport layout and activation: $mode', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final state = _PlayerState();
      final playFocus = FocusNode();
      addTearDown(state.dispose);
      addTearDown(playFocus.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppleTheme(brightness: Brightness.dark),
          home: TvScope(
            active: mode.remote,
            largeScreen: mode.largeScreen,
            child: Scaffold(
              body: DesktopNowPlaying(
                state: state,
                track: _track,
                artwork: const ColoredBox(color: Colors.blue),
                lyrics: const Text('Lyrics'),
                comments: const Text('Comments'),
                queue: const Text('Queue'),
                pane: DesktopNowPlayingPane.lyrics,
                onPaneChanged: (_) {},
                onBack: () {},
                onSaveArtwork: () {},
                controlsVisible: true,
                onActivity: () {},
                playPauseFocus: playFocus,
              ),
            ),
          ),
        ),
      );
      final play = find.byKey(const ValueKey('desktop-play-pause'));
      final seek = find.byKey(const ValueKey('desktop-seek-bar'));
      expect(
        tester.getBottomLeft(play).dy,
        lessThanOrEqualTo(tester.getTopLeft(seek).dy),
      );
      final actions = find.byKey(const ValueKey('desktop-player-actions'));
      for (final key in [
        'desktop-search-osu',
        'desktop-add-to-playlist',
        'desktop-download',
      ]) {
        expect(
          find.descendant(of: actions, matching: find.byKey(ValueKey(key))),
          findsOneWidget,
        );
      }
      expect(
        find.byType(VolumeControl),
        mode.largeScreen ? findsNothing : findsOneWidget,
      );
      // The player has no fullscreen button: the volume slider closes the row.
      // Fullscreen stays on the keyboard (F) and on the window controls.
      expect(find.byKey(const ValueKey('desktop-fullscreen')), findsNothing);
      if (!mode.largeScreen) {
        // With the fullscreen icon gone, the slider is the trailing control and
        // it ends flush with the dock's content edge: the window inset (16) plus
        // the transport's own padding (24). Before, that last 48 dp belonged to
        // the fullscreen button, so the slider stopped short of it.
        final Rect volume = tester.getRect(find.byType(VolumeControl));
        final double contentRight =
            tester.view.physicalSize.width / tester.view.devicePixelRatio -
            16 -
            24;
        expect(volume.right, closeTo(contentRight, .5));
        // Full width of the slider's own cap, not the shrunken 48 dp form it
        // falls back to when its slot is too narrow.
        expect(volume.width, greaterThan(100));
        // Nothing of the player's own sits to the right of it any more.
        for (final Finder other in <Finder>[
          find.byKey(const ValueKey('desktop-play-pause')),
          find.byKey(const ValueKey('desktop-queue')),
        ]) {
          expect(other, findsOneWidget);
          expect(
            tester.getRect(other).right,
            lessThanOrEqualTo(volume.left),
            reason: 'the volume slider has to be the trailing control',
          );
        }
      }

      playFocus.requestFocus();
      await tester.pump();
      if (mode.remote) {
        final outline = tester.widget<TvFocusOutline>(
          find.descendant(of: play, matching: find.byType(TvFocusOutline)),
        );
        expect(outline.borderRadius, BorderRadius.circular(24));
        await tester.sendKeyEvent(LogicalKeyboardKey.select);
      } else {
        await tester.tap(play);
      }
      await tester.pump();
      expect(state.toggles, 1);
      expect(
        find.descendant(of: play, matching: find.byIcon(Icons.pause_rounded)),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
