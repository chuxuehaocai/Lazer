import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/ui/widgets.dart';
import 'package:lazer_nextgen/theme/lazer_theme.dart';

void main() {
  testWidgets('track row hover uses the same surface as current playback', (
    tester,
  ) async {
    const track = Track(
      id: 'track-1',
      title: 'Track',
      artist: 'Artist',
      album: 'Album',
      duration: Duration(minutes: 3),
      coverSeed: 1,
    );

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 900,
            height: 100,
            child: AppTrackRow(
              track: track,
              index: 0,
              current: true,
              onTap: _noop,
            ),
          ),
        ),
      ),
    );

    final inkWell = tester.widget<InkWell>(find.byType(InkWell).first);
    expect(
      inkWell.overlayColor?.resolve(<WidgetState>{WidgetState.hovered}),
      Colors.transparent,
    );
    expect(
      inkWell.overlayColor?.resolve(<WidgetState>{WidgetState.pressed}),
      Colors.transparent,
    );
    final animatedRow = tester
        .widgetList<AnimatedContainer>(
          find.descendant(
            of: find.byType(AppTrackRow),
            matching: find.byType(AnimatedContainer),
          ),
        )
        .single;
    expect(animatedRow.duration, const Duration(milliseconds: 120));
  });

  testWidgets('track row hover duration follows the active theme', (
    tester,
  ) async {
    const track = Track(
      id: 'track-2',
      title: 'Themed track',
      artist: 'Artist',
      album: 'Album',
      duration: Duration(minutes: 3),
      coverSeed: 2,
    );
    const tokens = LazerThemeTokens(trackHoverDurationMs: 240);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          extensions: const <ThemeExtension<LazerThemeTokens>>[tokens],
        ),
        home: const Scaffold(
          body: AppTrackRow(track: track, index: 0, onTap: _noop),
        ),
      ),
    );
    final animatedRow = tester
        .widgetList<AnimatedContainer>(
          find.descendant(
            of: find.byType(AppTrackRow),
            matching: find.byType(AnimatedContainer),
          ),
        )
        .single;
    expect(animatedRow.duration, const Duration(milliseconds: 240));
  });
}

void _noop() {}
