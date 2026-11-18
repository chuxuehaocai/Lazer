import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/lyrics/lyric_document.dart';
import 'package:lazer_nextgen/player/artwork_lyrics_layout.dart';
import 'package:lazer_nextgen/player/now_playing_page.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/state/ui_preferences.dart';
import 'package:lazer_nextgen/theme/adaptive_app_theme.dart';
import 'package:lazer_nextgen/theme/apple_design.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _track = Track(
  id: 'mobile-reference',
  title: 'The mobile player keeps its artwork and lyric presentation',
  artist: 'Artist',
  album: 'Album',
  duration: Duration(minutes: 3),
  coverSeed: 1,
);

class _MobileState extends AppState {
  _MobileState() {
    autoDpiScale = false;
    layoutStyle = AppLayoutStyle.phone;
    playerBackground = AppBackgroundMode.off;
    lyricControlsSeconds = 1;
    lyrics = const [
      LyricLine(Duration.zero, 'The first lyric'),
      LyricLine(Duration(seconds: 10), 'The second lyric'),
    ];
  }

  bool isPlaying = false;

  @override
  Track get current => _track;
  @override
  bool get playing => isPlaying;
  @override
  Future<void> ensureCurrentLyrics({bool force = false}) async {}
  @override
  void playerPresentationChanged(bool visible) {}
  @override
  void togglePlay() {
    isPlaying = !isPlaying;
    notifyListeners();
  }

  void reportPlayback() => notifyListeners();
}

Future<void> _mount(
  WidgetTester tester,
  _MobileState state,
  Size size, {
  double textScale = 1,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  addTearDown(state.dispose);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppleTheme(brightness: Brightness.dark),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(textScale),
          disableAnimations: true,
        ),
        child: AdaptiveAppTheme(state: state, child: child!),
      ),
      home: NowPlayingPage(state: state),
    ),
  );
  await tester.pump();
}

ArtworkLyricsLayout _layout(WidgetTester tester) =>
    tester.widget<ArtworkLyricsLayout>(find.byType(ArtworkLyricsLayout));

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final sample in [
    (size: const Size(320, 568), textScale: 1.0),
    (size: const Size(390, 844), textScale: 1.0),
    (size: const Size(844, 390), textScale: 1.0),
    (size: const Size(390, 844), textScale: 2.0),
  ]) {
    testWidgets('mobile artwork and lyrics remain usable at $sample', (
      tester,
    ) async {
      final state = _MobileState();
      await _mount(tester, state, sample.size, textScale: sample.textScale);
      final cover = find.byKey(const ValueKey('now-playing-cover'));
      final play = find.byKey(const ValueKey('now-playing-play'));
      final more = find.byKey(const ValueKey('now-playing-more'));
      expect(_layout(tester).lyricsVisible, isFalse);
      expect(cover.hitTestable(), findsOneWidget);
      expect(play.hitTestable(), findsOneWidget);
      expect(more.hitTestable(), findsOneWidget);

      final artworkSize = tester.getSize(cover);
      await tester.tap(cover);
      await tester.pumpAndSettle();
      expect(_layout(tester).lyricsVisible, isTrue);
      expect(tester.getSize(cover).width, lessThan(artworkSize.width));
      expect(play.hitTestable(), findsOneWidget);

      // The v2.0.210 artwork/lyrics composition remains intact, while the
      // later paused-playback fix keeps its transport available indefinitely.
      await tester.pump(const Duration(seconds: 3));
      expect(_layout(tester).controlsVisible, isTrue);
      expect(play.hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('mobile lyrics survive rotation and playback notifications', (
    tester,
  ) async {
    final state = _MobileState();
    await _mount(tester, state, const Size(390, 844));
    await tester.tap(find.byKey(const ValueKey('now-playing-cover')));
    await tester.pumpAndSettle();
    tester.view.physicalSize = const Size(844, 390);
    await tester.pumpAndSettle();
    expect(_layout(tester).lyricsVisible, isTrue);
    await tester.tap(find.byKey(const ValueKey('now-playing-play')));
    await tester.pump();

    // Progress notifications must not restart the idle countdown.
    for (var tick = 0; tick < 15; tick++) {
      state.reportPlayback();
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(_layout(tester).controlsVisible, isFalse);
    state.togglePlay();
    await tester.pump();
    expect(_layout(tester).controlsVisible, isTrue);
    expect(
      find.byKey(const ValueKey('now-playing-play')).hitTestable(),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'player keeps one palette across phone and desktop presentations',
    (tester) async {
      final state = _MobileState()..layoutStyle = AppLayoutStyle.auto;
      await _mount(tester, state, const Size(390, 844));
      AppleSemanticColors colors() => AppleSemanticColors.of(
        tester.element(find.byKey(const ValueKey('now-playing-cover'))),
      );
      expect(colors().background, AppleSemanticColors.dark.background);
      expect(colors().accent, AppleColors.lazerBlue);

      tester.view.physicalSize = const Size(1280, 800);
      await tester.pumpAndSettle();
      expect(colors().background, AppleSemanticColors.dark.background);
      expect(colors().accent, AppleColors.lazerBlue);

      tester.view.physicalSize = const Size(390, 844);
      await tester.pumpAndSettle();
      expect(colors().background, AppleSemanticColors.dark.background);
      expect(colors().accent, AppleColors.lazerBlue);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
