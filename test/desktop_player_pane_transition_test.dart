import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/player/desktop_now_playing.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/tv/tv_mode.dart';

void main() {
  testWidgets('player panes fade through and retire outgoing remote targets', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final state = AppState();
    addTearDown(state.dispose);
    final nodes = {
      for (final pane in DesktopNowPlayingPane.values) pane: FocusNode(),
    };
    addTearDown(() {
      for (final node in nodes.values) {
        node.dispose();
      }
    });
    var pane = DesktopNowPlayingPane.lyrics;
    late StateSetter update;
    Widget content(DesktopNowPlayingPane value) => Center(
      child: TextButton(
        focusNode: nodes[value],
        onPressed: () {},
        child: Text('pane-${value.name}'),
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Material(
          child: TvScope(
            active: true,
            child: TvTraversalScope(
              child: StatefulBuilder(
                builder: (context, setState) {
                  update = setState;
                  return DesktopNowPlaying(
                    state: state,
                    track: const Track(
                      id: 'pane-test',
                      title: 'Pane test',
                      artist: 'Artist',
                      album: 'Album',
                      duration: Duration(minutes: 3),
                      coverSeed: 1,
                    ),
                    artwork: const ColoredBox(color: Colors.blue),
                    lyrics: content(DesktopNowPlayingPane.lyrics),
                    comments: content(DesktopNowPlayingPane.comments),
                    queue: content(DesktopNowPlayingPane.queue),
                    pane: pane,
                    onPaneChanged: (value) => update(() => pane = value),
                    onBack: () {},
                    onSaveArtwork: () {},
                    onFullscreen: () {},
                    controlsVisible: true,
                    onActivity: () {},
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    nodes[pane]!.requestFocus();
    await tester.pump();
    expect(nodes[pane]!.hasPrimaryFocus, isTrue);
    for (final (next, frames) in [
      (DesktopNowPlayingPane.comments, 5),
      (DesktopNowPlayingPane.queue, 4),
      (DesktopNowPlayingPane.lyrics, 40),
    ]) {
      final previous = pane;
      update(() => pane = next);
      await tester.pump();
      expect(nodes[previous]!.canRequestFocus, isFalse);
      for (var frame = 0; frame < frames; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
        final visible = <DesktopNowPlayingPane>[];
        for (final candidate in DesktopNowPlayingPane.values) {
          final label = find.text('pane-${candidate.name}');
          if (label.evaluate().isEmpty) continue;
          final opacity = tester
              .widgetList<FadeTransition>(
                find.ancestor(of: label, matching: find.byType(FadeTransition)),
              )
              .fold(1.0, (value, fade) => value * fade.opacity.value);
          if (opacity > .00001) visible.add(candidate);
        }
        expect(visible.length, lessThanOrEqualTo(1), reason: '$visible');
      }
    }
    await tester.pumpAndSettle();
    expect(find.text('pane-lyrics'), findsOneWidget);
    expect(find.text('pane-comments'), findsNothing);
    expect(find.text('pane-queue'), findsNothing);
    expect(nodes[DesktopNowPlayingPane.lyrics]!.canRequestFocus, isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
