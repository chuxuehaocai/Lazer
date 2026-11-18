import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/lyrics/lyric_document.dart';
import 'package:lazer_nextgen/navigation/pull_down_to_close.dart';
import 'package:lazer_nextgen/player/artwork_lyrics_layout.dart';
import 'package:lazer_nextgen/player/now_playing_page.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/state/ui_preferences.dart';
import 'package:lazer_nextgen/theme/apple_design.dart';
import 'package:lazer_nextgen/widgets/lyric_selection_toolbar.dart';
import 'package:lazer_nextgen/widgets/lyric_text_hit_region.dart';
import 'package:lazer_nextgen/widgets/lyric_viewport.dart';
import 'package:shared_preferences/shared_preferences.dart';

Track _track(String id) => Track(
  id: id,
  title: 'Song $id',
  artist: 'Artist',
  album: 'Album',
  duration: const Duration(minutes: 3),
  coverSeed: 1,
);

class _MobileState extends AppState {
  _MobileState() {
    layoutStyle = AppLayoutStyle.phone;
    playerBackground = AppBackgroundMode.off;
    lyricControlsSeconds = 1;
    lyrics = const [
      LyricLine(Duration.zero, 'First lyric'),
      LyricLine(Duration(seconds: 10), 'Second lyric'),
    ];
  }

  Track selected = _track('first');
  bool isPlaying = false;
  final seeks = <double>[];
  @override
  Track get current => selected;
  @override
  bool get playing => isPlaying;
  @override
  Listenable get all => this;
  @override
  Future<void> ensureCurrentLyrics({bool force = false}) async {}
  @override
  void playerPresentationChanged(bool visible) {}
  @override
  void seek(double fraction) => seeks.add(fraction);

  void nextTrack() {
    selected = _track('next');
    notifyListeners();
  }

  void startPlayback() {
    isPlaying = true;
    notifyListeners();
  }
}

class _PullDown extends PlayerPullDown {
  @override
  bool get canStart => true;
  @override
  void startPull() {}
  @override
  void updatePull(double progress) {}
  @override
  void endPull(double velocity) {}
}

Future<void> _mount(WidgetTester tester, _MobileState state) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  addTearDown(state.dispose);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppleTheme(brightness: Brightness.dark),
      home: NowPlayingPage(state: state, pullDown: _PullDown()),
    ),
  );
  await tester.pump();
  await tester.tap(find.byKey(const ValueKey('now-playing-cover')));
  await tester.pumpAndSettle();
}

ArtworkLyricsLayout _layout(WidgetTester tester) =>
    tester.widget<ArtworkLyricsLayout>(find.byType(ArtworkLyricsLayout));

Future<void> _select(WidgetTester tester) async {
  final row = find.byWidgetPredicate(
    (widget) => widget is LyricTextHitRegion && widget.text == 'First lyric',
  );
  await tester.longPressAt(
    tester.getRect(row).centerLeft + const Offset(15, 0),
  );
  await tester.pump();
  expect(find.byType(LyricSelectionToolbar), findsOneWidget);
}

Future<void> _backgroundTap(WidgetTester tester) async {
  // The gutter is outside both the text hit regions and the artwork.
  await tester.tapAt(const Offset(8, 500));
  await tester.pump();
}

Offset _lyricPoint(WidgetTester tester) =>
    tester
        .getRect(
          find.byWidgetPredicate(
            (widget) =>
                widget is LyricTextHitRegion && widget.text == 'Second lyric',
          ),
        )
        .centerLeft +
    const Offset(15, 0);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('lyric seeking follows fully hidden playback controls', (
    tester,
  ) async {
    final state = _MobileState();
    await _mount(tester, state);
    await tester.tapAt(_lyricPoint(tester));
    await tester.pump();
    expect(state.seeks, isEmpty);
    expect(_layout(tester).lyricsVisible, isTrue);
    expect(_layout(tester).controlsVisible, isTrue);

    state.startPlayback();
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(_layout(tester).controlsVisible, isFalse);
    // The logical flag flips before the visible chrome finishes fading out.
    await tester.tapAt(_lyricPoint(tester));
    await tester.pump();
    expect(state.seeks, isEmpty);
    expect(_layout(tester).lyricsVisible, isTrue);

    await tester.pumpAndSettle();
    await tester.tapAt(_lyricPoint(tester));
    await tester.pump();
    expect(state.seeks, [10 / 180]);
    expect(_layout(tester).controlsVisible, isFalse);

    await _backgroundTap(tester);
    expect(_layout(tester).controlsVisible, isTrue);
    await tester.tapAt(_lyricPoint(tester));
    await tester.pump();
    expect(state.seeks, [10 / 180]);
    expect(_layout(tester).lyricsVisible, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a tap begun during control dismissal cannot seek afterward', (
    tester,
  ) async {
    final state = _MobileState();
    await _mount(tester, state);
    state.startPlayback();
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(milliseconds: 160));
    expect(
      tester.widget<LyricViewport>(find.byType(LyricViewport)).seekEnabled!.value,
      isFalse,
    );
    final pointer = await tester.startGesture(_lyricPoint(tester));
    // Let the chrome finish before releasing this same pointer. A long press
    // would select text, so keep the hold shorter than its recognition delay.
    for (var frame = 0; frame < 25; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(
      tester.widget<LyricViewport>(find.byType(LyricViewport)).seekEnabled!.value,
      isTrue,
    );
    await pointer.up();
    await tester.pump();
    expect(state.seeks, isEmpty);
    expect(_layout(tester).lyricsVisible, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('selection immediately disables and re-enables pull down', (
    tester,
  ) async {
    await _mount(tester, _MobileState());
    await _select(tester);
    expect(
      tester
          .widget<PlayerPullDownRegion>(find.byType(PlayerPullDownRegion))
          .enabled,
      isFalse,
    );
    await tester.tap(
      find.descendant(
        of: find.byType(LyricSelectionToolbar),
        matching: find.byTooltip('关闭'),
      ),
    );
    await tester.pump();
    expect(
      tester
          .widget<PlayerPullDownRegion>(find.byType(PlayerPullDownRegion))
          .enabled,
      isTrue,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'changing songs during selection releases background navigation',
    (tester) async {
      final state = _MobileState();
      await _mount(tester, state);
      await _select(tester);
      state.nextTrack();
      await tester.pump();
      await _backgroundTap(tester);
      expect(_layout(tester).lyricsVisible, isFalse);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('hiding and reopening lyrics clears selection and back veto', (
    tester,
  ) async {
    await _mount(tester, _MobileState());
    await _select(tester);
    final cover = find.byKey(const ValueKey('now-playing-cover'));
    await tester.tap(cover);
    await tester.pumpAndSettle();
    expect(_layout(tester).lyricsVisible, isFalse);
    expect(find.byType(LyricSelectionToolbar), findsNothing);
    expect(
      tester
          .widgetList<PopScope<Object?>>(find.byType(PopScope<Object?>))
          .every((scope) => scope.canPop),
      isTrue,
    );
    await tester.tap(cover);
    await tester.pumpAndSettle();
    await _backgroundTap(tester);
    expect(_layout(tester).lyricsVisible, isFalse);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('rapid artwork and background taps settle into a usable mode', (
    tester,
  ) async {
    await _mount(tester, _MobileState());
    final cover = find.byKey(const ValueKey('now-playing-cover'));
    for (var tap = 0; tap < 20; tap++) {
      await tester.tap(cover);
      await tester.pump(const Duration(milliseconds: 32));
      await _backgroundTap(tester);
      await tester.pump(const Duration(milliseconds: 32));
    }
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    expect(cover.hitTestable(), findsOneWidget);
    expect(
      find.byKey(const ValueKey('now-playing-play')).hitTestable(),
      findsOneWidget,
    );
    await tester.tap(cover);
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    if (_layout(tester).lyricsVisible) await _backgroundTap(tester);
    expect(_layout(tester).lyricsVisible, isFalse);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('backgrounding releases a lost touch hold on the controls', (
    tester,
  ) async {
    final state = _MobileState();
    await _mount(tester, state);
    state.startPlayback();
    await tester.pump();
    final held = await tester.startGesture(const Offset(8, 500));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(seconds: 1));
    expect(_layout(tester).controlsVisible, isFalse);
    await held.cancel();
    await _backgroundTap(tester);
    expect(_layout(tester).controlsVisible, isTrue);
    expect(_layout(tester).lyricsVisible, isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
