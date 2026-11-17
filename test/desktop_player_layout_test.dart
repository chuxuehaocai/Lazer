import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/player/desktop_now_playing.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/theme/apple_design.dart';
import 'package:lazer_nextgen/tv/tv_mode.dart';

const _track = Track(
  id: 'layout',
  title: '午前1時39分に死にたい feat. 初音ミク — a long track title',
  translatedTitle: '想在凌晨 1:39 分死去',
  artist: 'Magens',
  album: '午前1時39分に死にたい feat. 初音ミク',
  duration: Duration(minutes: 3),
  coverSeed: 1,
);

Widget _host(
  AppState state, {
  bool controls = true,
  bool tv = false,
  double textScale = 1,
}) => MaterialApp(
  theme: buildAppleTheme(brightness: Brightness.dark),
  home: TvScope(
    active: tv,
    child: MediaQuery(
      data: MediaQueryData(
        padding: const EdgeInsets.only(top: 46),
        viewPadding: const EdgeInsets.only(top: 46),
        textScaler: TextScaler.linear(textScale),
      ),
      child: Scaffold(
        body: DesktopNowPlaying(
          state: state,
          track: _track,
          artwork: const ColoredBox(
            key: ValueKey('layout-art'),
            color: Colors.blue,
          ),
          lyrics: const ColoredBox(
            key: ValueKey('layout-lyrics'),
            color: Colors.red,
          ),
          comments: const SizedBox(),
          queue: const SizedBox(),
          pane: DesktopNowPlayingPane.lyrics,
          onPaneChanged: (_) {},
          onBack: () {},
          onSaveArtwork: () {},
          onFullscreen: () {},
          controlsVisible: controls,
          onActivity: () {},
        ),
      ),
    ),
  ),
);

void main() {
  testWidgets('wide desktop prioritizes artwork without crowding metadata', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final state = AppState();
    addTearDown(state.dispose);
    await tester.pumpWidget(_host(state));
    await tester.pumpAndSettle();
    final art = tester.getRect(find.byKey(const ValueKey('layout-art')));
    final lyrics = tester.getRect(find.byKey(const ValueKey('layout-lyrics')));
    expect(art.width, greaterThanOrEqualTo(350));
    expect(art.width, art.height);
    expect(art.right, lessThan(lyrics.left));
    expect(art.top, greaterThanOrEqualTo(46));
    final metadata = tester.getRect(
      find.byKey(const ValueKey('desktop-player-metadata')),
    );
    final dock = tester.getRect(
      find.byKey(const ValueKey('desktop-dock-content')),
    );
    expect(metadata.bottom, lessThanOrEqualTo(dock.top));
    expect(metadata.left, closeTo(art.left, .1));
    expect(
      tester.getCenter(find.byKey(const ValueKey('desktop-play-pause'))).dx,
      closeTo(640, .1),
    );
    expect(
      tester.getCenter(find.byKey(const ValueKey('desktop-seek-bar'))).dx,
      closeTo(640, .1),
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final sample in [
    (size: const Size(800, 480), scale: 1.0, tv: false),
    (size: const Size(1280, 720), scale: 1.8, tv: false),
    (size: const Size(1280, 720), scale: 1.0, tv: true),
  ]) {
    testWidgets('compact and accessible layout stays usable: $sample', (
      tester,
    ) async {
      tester.view.physicalSize = sample.size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final state = AppState();
      addTearDown(state.dispose);
      await tester.pumpWidget(
        _host(state, tv: sample.tv, textScale: sample.scale),
      );
      await tester.pumpAndSettle();
      final art = tester.getRect(find.byKey(const ValueKey('layout-art')));
      expect(art.width, greaterThanOrEqualTo(72));
      expect(art.width, art.height);
      expect(
        find.byKey(const ValueKey('desktop-play-pause')).hitTestable(),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('hidden dock releases space and leaves no invisible controls', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final state = AppState();
    addTearDown(state.dispose);
    await tester.pumpWidget(_host(state));
    await tester.pumpAndSettle();
    final visibleSize = tester.getSize(
      find.byKey(const ValueKey('layout-art')),
    );
    await tester.pumpWidget(_host(state, controls: false));
    await tester.pumpAndSettle();
    expect(
      tester.getSize(find.byKey(const ValueKey('layout-art'))).width,
      greaterThan(visibleSize.width),
    );
    expect(
      find.byKey(const ValueKey('desktop-play-pause')).hitTestable(),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
