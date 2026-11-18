import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lazer_nextgen/player/artwork_lyrics_layout.dart';

const _headerKey = ValueKey('controls-header');

Widget _host({
  required bool controlsVisible,
  required ValueChanged<bool> onControlsHiddenChanged,
  bool reduceMotion = false,
}) => MaterialApp(
  home: Scaffold(
    body: Center(
      child: SizedBox(
        width: 390,
        height: 560,
        child: MediaQuery(
          data: MediaQueryData(disableAnimations: reduceMotion),
          child: ArtworkLyricsLayout(
            lyricsVisible: true,
            controlsVisible: controlsVisible,
            onControlsHiddenChanged: onControlsHiddenChanged,
            artwork: const SizedBox.square(dimension: 100),
            lyrics: const SizedBox.expand(),
            details: const SizedBox(height: 50),
            transport: const SizedBox(height: 100),
            header: const SizedBox(key: _headerKey, height: 32),
            summary: const SizedBox(height: 52),
          ),
        ),
      ),
    ),
  ),
);

double _controlsOpacity(WidgetTester tester) => tester
    .widget<FadeTransition>(
      find
          .ancestor(
            of: find.byKey(_headerKey),
            matching: find.byType(FadeTransition),
          )
          .first,
    )
    .opacity
    .value;

void main() {
  testWidgets('controls report hidden only after their fade finishes', (
    tester,
  ) async {
    final changes = <bool>[];
    await tester.pumpWidget(
      _host(controlsVisible: true, onControlsHiddenChanged: changes.add),
    );
    expect(changes, [false]);
    expect(_controlsOpacity(tester), 1);

    await tester.pumpWidget(
      _host(controlsVisible: false, onControlsHiddenChanged: changes.add),
    );
    expect(changes, [false]);
    for (var frame = 0; frame < 5; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
      expect(_controlsOpacity(tester), inExclusiveRange(0, 1));
      expect(changes, [false]);
    }

    await tester.pumpAndSettle();
    expect(_controlsOpacity(tester), 0);
    expect(changes, [false, true]);

    // A reveal revokes permission before the first visible animation frame.
    await tester.pumpWidget(
      _host(controlsVisible: true, onControlsHiddenChanged: changes.add),
    );
    expect(changes, [false, true, false]);
    await tester.pumpAndSettle();
    expect(_controlsOpacity(tester), 1);
    expect(changes, [false, true, false]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reversing unfinished fades never reports hidden', (
    tester,
  ) async {
    final changes = <bool>[];
    await tester.pumpWidget(
      _host(controlsVisible: true, onControlsHiddenChanged: changes.add),
    );

    for (var reversal = 0; reversal < 3; reversal++) {
      await tester.pumpWidget(
        _host(controlsVisible: false, onControlsHiddenChanged: changes.add),
      );
      await tester.pump(const Duration(milliseconds: 48));
      expect(_controlsOpacity(tester), greaterThan(0));
      expect(changes, [false]);
      await tester.pumpWidget(
        _host(controlsVisible: true, onControlsHiddenChanged: changes.add),
      );
      await tester.pump(const Duration(milliseconds: 48));
      expect(changes, [false]);
    }

    await tester.pumpAndSettle();
    expect(_controlsOpacity(tester), 1);
    expect(changes, [false]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reduced motion reports both endpoints immediately', (
    tester,
  ) async {
    final changes = <bool>[];
    await tester.pumpWidget(
      _host(
        controlsVisible: true,
        onControlsHiddenChanged: changes.add,
        reduceMotion: true,
      ),
    );
    expect(changes, [false]);

    await tester.pumpWidget(
      _host(
        controlsVisible: false,
        onControlsHiddenChanged: changes.add,
        reduceMotion: true,
      ),
    );
    expect(_controlsOpacity(tester), 0);
    expect(changes, [false, true]);

    await tester.pumpWidget(
      _host(
        controlsVisible: true,
        onControlsHiddenChanged: changes.add,
        reduceMotion: true,
      ),
    );
    expect(_controlsOpacity(tester), 1);
    expect(changes, [false, true, false]);
    await tester.pump();
    expect(changes, [false, true, false]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('enabling reduced motion settles an unfinished hide', (
    tester,
  ) async {
    final changes = <bool>[];
    await tester.pumpWidget(
      _host(controlsVisible: true, onControlsHiddenChanged: changes.add),
    );
    await tester.pumpWidget(
      _host(controlsVisible: false, onControlsHiddenChanged: changes.add),
    );
    await tester.pump(const Duration(milliseconds: 48));
    expect(_controlsOpacity(tester), inExclusiveRange(0, 1));
    expect(changes, [false]);

    await tester.pumpWidget(
      _host(
        controlsVisible: false,
        onControlsHiddenChanged: changes.add,
        reduceMotion: true,
      ),
    );
    expect(_controlsOpacity(tester), 0);
    expect(changes, [false, true]);
    await tester.pumpAndSettle();
    expect(changes, [false, true]);
    expect(tester.takeException(), isNull);
  });
}
