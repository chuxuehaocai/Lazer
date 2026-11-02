import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lazer_nextgen/data/audio_quality.dart';
import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/gateway/gateway.dart';
import 'package:lazer_nextgen/ui/player_bar.dart';
import 'package:lazer_nextgen/ui/shell.dart';
import 'package:lazer_nextgen/theme/apple_design.dart';
import 'package:lazer_nextgen/lyrics/selection_bar.dart';
import 'package:lazer_nextgen/lyrics/viewport.dart';
import 'package:lazer_nextgen/player/desktop_now_playing.dart';
import 'package:lazer_nextgen/state/app_state.dart';

import 'support/serialized_semantics.dart';

const Track _track = Track(
  id: '1',
  title: '探针曲目',
  artist: '测试歌手',
  album: '测试专辑',
  duration: Duration(minutes: 4),
  coverSeed: 1,
);

class _Gateway extends NeteaseGateway {
  @override
  Future<Set<int>> likedSongIds(int uid) async => <int>{};
}

class _Catalog extends Catalog {
  _Catalog() : super(gateway: _Gateway());
  @override
  Future<HomeFeed?> loadHome({int? userId}) async => home;
  @override
  HomeFeed? get home => const HomeFeed(
    recommended: <Playlist>[],
    featuredTracks: <Track>[_track],
    quick: <Track>[_track],
    playlists: <Playlist>[],
    albums: <Album>[],
  );
  @override
  Future<String?> audioUrlFor(
    Track track, {
    AudioQuality quality = AudioQuality.exhigh,
  }) async => null;
  @override
  Future<GatewayLyrics?> lyricsFor(Track track) async => GatewayLyrics(
    lrc: List<String>.generate(
      30,
      (int i) => '[00:${i.toString().padLeft(2, '0')}.00]第 $i 句歌词',
    ).join('\n'),
  );
  @override
  Future<List<Track>> playlistTracks(String id) async => <Track>[_track];
  @override
  Future<SearchResults> search(String query) async =>
      const SearchResults(tracks: <Track>[_track], playlists: <Playlist>[]);
}

Widget _app(AppState state) => MaterialApp(
  theme: buildAppleTheme(brightness: Brightness.dark),
  builder: (BuildContext context, Widget? child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(disableAnimations: true),
    child: child!,
  ),
  home: AppShell(state: state),
);

void main() {
  final binding = RecordingSemanticsBinding();
  setUp(binding.recorder.reset);
  tearDown(() => binding.recorder.enabled = false);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<void> frames(WidgetTester tester, [int count = 20]) async {
    for (int i = 0; i < count; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
  }

  void report(String step) {
    // ignore: avoid_print
    print(
      'PROBE $step: commits=${binding.recorder.commits} '
      'errors=${binding.recorder.errors}',
    );
  }

  testWidgets('desktop lyrics probe', (WidgetTester tester) async {
    final SemanticsHandle semantics = tester.ensureSemantics();
    final AppState state = AppState(catalog: _Catalog());
    addTearDown(state.dispose);
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_app(state));
    await tester.pumpAndSettle();
    state.playQueue(<Track>[_track]);
    await frames(tester, 40);

    final Finder title = find.descendant(
      of: find.byType(AppPlayerBar),
      matching: find.text(_track.title),
    );
    await tester.tap(title.first);
    await frames(tester, 120);
    report('first open');
    // ignore: avoid_print
    print(
      'PROBE lyrics open: viewport=${find.byType(LyricViewport).evaluate().length} '
      'lyricsKey=${find.byKey(const ValueKey<DesktopNowPlayingPane>(DesktopNowPlayingPane.lyrics)).evaluate().length}',
    );

    for (int i = 1; i <= 60; i++) {
      state.seek(i / 61);
      await frames(tester, 4);
      if (i % 10 == 0) report('seek $i');
    }

    final Finder line = find.byKey(const ValueKey<String>('lyric-line-20'));
    if (line.evaluate().isNotEmpty) {
      await tester.longPress(line.first);
      await frames(tester, 30);
      report('long press');
      // ignore: avoid_print
      print(
        'PROBE selection: toolbar=${find.byType(LyricSelectionToolbar).evaluate().length}',
      );
      final Finder selectAll = find.byTooltip('全选');
      if (selectAll.evaluate().isNotEmpty) {
        await tester.tap(selectAll.first);
        await frames(tester, 20);
        report('select all');
      }
      final Finder close = find.byTooltip('关闭');
      if (close.evaluate().isNotEmpty) {
        await tester.tap(close.first);
        await frames(tester, 20);
        report('selection closed');
      }
    } else {
      report('missing lyric line');
    }
    semantics.dispose();
  });

  testWidgets('desktop shell probe', (WidgetTester tester) async {
    final SemanticsHandle semantics = tester.ensureSemantics();
    final AppState state = AppState(catalog: _Catalog());
    addTearDown(state.dispose);
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_app(state));
    await tester.pumpAndSettle();
    await frames(tester);
    report('desktop settled');

    state.playQueue(<Track>[_track]);
    await frames(tester, 40);
    report('desktop playing');

    Future<void> ticking([int count = 80]) async {
      int step = 0;
      for (int f = 0; f < count; f++) {
        if (f % 6 == 0) {
          step++;
          state.seek((step % 40) / 40);
        }
        await tester.pump(const Duration(milliseconds: 16));
      }
    }

    final TestGesture hover = await tester.createGesture(
      kind: ui.PointerDeviceKind.mouse,
    );
    await hover.addPointer(location: Offset.zero);
    for (final String label in <String>[
      '喜欢',
      '上一首',
      '暂停',
      '下一首',
      '循环播放',
      '评论',
      '歌词',
      '音量',
      '播放队列',
    ]) {
      final Finder target = find.byTooltip(label);
      if (target.evaluate().isEmpty) {
        report('missing tooltip $label');
        continue;
      }
      await hover.moveTo(tester.getCenter(target.first));
      tester.state<RawTooltipState>(target.first).ensureTooltipVisible();
      await frames(tester, 12);
      report('hover $label');
    }

    final Finder seek = find.bySemanticsLabel('播放进度');
    if (seek.evaluate().isNotEmpty) {
      await hover.moveTo(tester.getCenter(seek.first));
      final TestGesture drag = await tester.startGesture(
        tester.getCenter(seek.first),
        kind: ui.PointerDeviceKind.mouse,
      );
      await drag.moveBy(const Offset(80, 0));
      await frames(tester, 16);
      await drag.up();
      await frames(tester, 8);
      report('seek drag');
    } else {
      report('missing seek');
    }
    await hover.moveTo(const Offset(1, 1));
    await frames(tester, 8);
    report('hover reset');

    final Finder title = find.descendant(
      of: find.byType(AppPlayerBar),
      matching: find.text(_track.title),
    );
    if (title.evaluate().isNotEmpty) {
      for (int round = 0; round < 4; round++) {
        await tester.tap(title.first);
        state.seek(.1);
        await ticking();
        report('desktop open round $round');
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        state.seek(.2);
        await ticking();
        report('desktop close round $round');
      }
      await tester.tap(title.first);
      state.seek(.3);
      await ticking(120);
      report('desktop now playing open');
      // ignore: avoid_print
      print(
        'PROBE now playing state: panel='
        '${find.byKey(const ValueKey<String>('desktop-now-playing')).evaluate().length} '
        'viewport=${find.byType(LyricViewport).evaluate().length} '
        'lyricsKey=${find.byKey(const ValueKey<DesktopNowPlayingPane>(DesktopNowPlayingPane.lyrics)).evaluate().length} '
        'commentsKey=${find.byKey(const ValueKey<DesktopNowPlayingPane>(DesktopNowPlayingPane.comments)).evaluate().length} '
        'queueKey=${find.byKey(const ValueKey<DesktopNowPlayingPane>(DesktopNowPlayingPane.queue)).evaluate().length} '
        'lyrics=${state.lyrics.length} loading=${state.lyricsLoading} '
        'track=${state.current?.id}',
      );

      for (int i = 1; i <= 40; i++) {
        state.seek(i / 41);
        await frames(tester, 3);
      }
      report('desktop ticks');

      final Finder viewport = find.byType(LyricViewport);
      if (viewport.evaluate().isNotEmpty) {
        await tester.longPressAt(tester.getCenter(viewport.first));
        await frames(tester, 12);
        report('desktop lyric long press');
        final Finder close = find.byTooltip('关闭');
        if (close.evaluate().isNotEmpty) {
          await tester.tap(close.first);
          await frames(tester, 12);
          report('desktop lyric selection closed');
        }
      } else {
        report('missing lyric viewport');
      }

      for (final String key in <String>[
        'desktop-comments',
        'desktop-queue',
        'desktop-lyrics',
      ]) {
        final Finder pane = find.byKey(ValueKey<String>(key));
        if (pane.evaluate().isEmpty) {
          report('missing pane $key');
          continue;
        }
        await tester.tap(pane.first);
        await frames(tester, 24);
        report('pane $key');
      }

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await frames(tester, 60);
      report('desktop now playing closed');
    }

    final Finder queue = find.byTooltip('播放队列');
    if (queue.evaluate().isNotEmpty) {
      await tester.tap(queue.first);
      await frames(tester, 20);
      report('desktop queue open');
      await tester.tap(queue.first);
      await frames(tester, 20);
      report('desktop queue closed');
    }

    tester.view.physicalSize = const Size(520, 900);
    await frames(tester, 40);
    report('mobile');

    semantics.dispose();
  });
}
