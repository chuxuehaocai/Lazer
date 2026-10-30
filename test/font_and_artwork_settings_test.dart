import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lazer_nextgen/data/lyrics.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/legacy/font_settings_page.dart';
import 'package:lazer_nextgen/legacy/legacy_settings_page.dart';
import 'package:lazer_nextgen/player/now_playing_page.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/state/ui_preferences.dart';
import 'package:lazer_nextgen/theme/adaptive_contrast.dart';
import 'package:lazer_nextgen/theme/apple_design.dart';
import 'package:lazer_nextgen/theme/font_preferences.dart';
import 'package:lazer_nextgen/widgets/animated_track_cover.dart';
import 'package:lazer_nextgen/player/artwork_lyrics_layout.dart';
import 'package:lazer_nextgen/widgets/player_seek_bar.dart';

const _track = Track(
  id: 'artwork-setting',
  title: 'Test song',
  artist: 'Test artist',
  album: 'Test album',
  duration: Duration(minutes: 3),
  coverSeed: 1,
);

class _State extends AppState {
  _State() {
    lyrics = parseLrc('[00:00.00]First line\n[00:04.00]Second line');
  }
  @override
  Track? get current => _track;
  @override
  Future<void> ensureCurrentLyrics({bool force = false}) async {}
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
    'the mobile artwork preference does not change desktop presentation',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final state = _State()..lyricControlsSeconds = 10;
      addTearDown(state.dispose);
      await tester.pumpWidget(MaterialApp(home: NowPlayingPage(state: state)));
      await tester.pump();
      final art = find.byKey(const ValueKey('legacy-now-playing-cover'));
      final rect = tester.getRect(art);
      await state.setShowArtworkWithLyrics(true);
      await tester.pump();
      await tester.tap(art);
      await tester.pump(const Duration(milliseconds: 450));
      expect(tester.getRect(art), rect);
      expect(find.byType(ArtworkLyricsLayout), findsNothing);
      expect(
        find.byKey(const ValueKey('compact-player-summary')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('lyrics controls stay visible throughout a long seek drag', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final state = _State()..showArtworkWithLyrics = true;
    state.lyricControlsSeconds = 1;
    addTearDown(state.dispose);
    await tester.pumpWidget(MaterialApp(home: NowPlayingPage(state: state)));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('legacy-now-playing-cover')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 450));
    final rail = find.descendant(
      of: find.byType(PlayerSeekBar),
      matching: find.byType(Slider),
    );
    final gesture = await tester.startGesture(tester.getCenter(rail));
    await tester.pump(const Duration(seconds: 2));
    final opacity = find.byKey(const ValueKey('compact-player-summary-fade'));
    expect(tester.widget<FadeTransition>(opacity).opacity.value, 0);
    await gesture.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1500));
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.widget<FadeTransition>(opacity).opacity.value, 1);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test(
    'font categories preserve defaults, clamp values and serialize independently',
    () async {
      final state = _State();
      addTearDown(state.dispose);
      await state.setFontCustomization(
        FontCategory.body,
        const FontCustomization(scale: 1.3, weight: 700),
      );
      await state.setFontCustomization(
        FontCategory.caption,
        const FontCustomization(scale: 9, weight: 100),
      );
      final prefs = await SharedPreferences.getInstance();
      final restored = FontPreferences.decode(
        prefs.getString('lazer_font_preferences'),
      );
      expect(
        restored[FontCategory.body],
        const FontCustomization(scale: 1.3, weight: 700),
      );
      expect(
        restored[FontCategory.caption],
        const FontCustomization(scale: 1.6, weight: 400),
      );
      final theme = buildAppleTheme(fonts: restored);
      expect(theme.textTheme.bodyLarge!.fontSize, closeTo(22.1, .01));
      expect(theme.textTheme.bodyLarge!.fontWeight, FontWeight.w700);
      expect(theme.textTheme.titleMedium!.fontWeight, FontWeight.w600);
      await state.setShowArtworkWithLyrics(true);
      expect(prefs.getBool('lazer_show_artwork_with_lyrics'), isTrue);
      await state.resetFonts();
      expect(prefs.getString('lazer_font_preferences'), isNull);
      expect(state.lyricFontSize, 22);
      expect(state.showArtworkWithLyrics, isTrue);
    },
  );

  test(
    'artwork accents and filled labels maintain readable contrast in both themes',
    () {
      for (final brightness in Brightness.values) {
        for (final seed in [
          Colors.black,
          Colors.white,
          const Color(0xFF0A1017),
          const Color(0xFF102008),
          const Color(0xFFFFEE99),
          Colors.blue,
          Colors.red,
        ]) {
          final scheme = buildAppleTheme(
            brightness: brightness,
            seedAccent: seed,
          ).colorScheme;
          expect(
            colorContrast(scheme.primary, scheme.surface),
            greaterThanOrEqualTo(4.49),
          );
          expect(
            colorContrast(scheme.onPrimary, scheme.primary),
            greaterThanOrEqualTo(4.49),
          );
        }
      }
    },
  );

  testWidgets('settings opens a dedicated font page and editing is live', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final state = _State();
    addTearDown(state.dispose);
    await tester.pumpWidget(
      AnimatedBuilder(
        animation: state,
        builder: (context, _) => MaterialApp(
          theme: buildAppleTheme(fonts: state.fontPreferences),
          home: Scaffold(body: LegacySettingsPage(state: state)),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('open-font-settings')));
    await tester.pumpAndSettle();
    expect(find.byType(FontSettingsPage), findsOneWidget);
    final card = find.byKey(const ValueKey('font-card-pageTitle'));
    await tester.drag(
      find.descendant(of: card, matching: find.byType(Slider)),
      const Offset(48, 0),
    );
    await tester.pumpAndSettle();
    expect(state.fontPreferences[FontCategory.pageTitle].scale, greaterThan(1));
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('歌词字号'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final size in [const Size(390, 844), const Size(844, 390)]) {
    testWidgets('artwork moves, hides with transport and returns at $size', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final state = _State();
      addTearDown(state.dispose);
      state.uiMode = size.width == 844 ? AppUiMode.mobile : AppUiMode.auto;
      state.showArtworkWithLyrics = true;
      state.lyricControlsSeconds = 1;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppleTheme(),
          home: NowPlayingPage(state: state),
        ),
      );
      await tester.pump();
      final art = find.byKey(const ValueKey('legacy-now-playing-cover'));
      final element = tester.element(art);
      final large = tester.getRect(art);
      await tester.tap(art);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 180));
      final moving = tester.getRect(art);
      expect(moving.width, lessThan(large.width));
      expect(
        (large.width - moving.width) / (large.width - 64),
        greaterThan(.65),
        reason: 'the cover travels most of the distance early, then eases in',
      );
      await tester.pump(const Duration(milliseconds: 260));
      final small = tester.getRect(art);
      expect(small.width, closeTo(64, 1));
      expect(identical(tester.element(art), element), isTrue);
      final cover = find
          .ancestor(of: art, matching: find.byType(AnimatedContainer))
          .first;
      expect(
        (tester.widget<AnimatedContainer>(cover).decoration as BoxDecoration)
            .boxShadow,
        isEmpty,
      );
      await tester.pump(const Duration(seconds: 2));
      await tester.pump(const Duration(milliseconds: 380));
      final summary = find.byKey(const ValueKey('compact-player-summary'));
      expect(summary, findsOneWidget);
      final opacity = tester.widget<FadeTransition>(
        find.byKey(const ValueKey('compact-player-summary-fade')),
      );
      expect(opacity.opacity.value, 1);
      await tester.tap(summary);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 380));
      expect(tester.getRect(art).width, closeTo(64, 1));
      await tester.tap(art);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 180));
      final returning = tester.getRect(art);
      expect(
        (returning.width - 64) / (large.width - 64),
        greaterThan(.65),
        reason:
            'returning to the large cover must also start fast and end slow',
      );
      await tester.pump(const Duration(milliseconds: 270));
      expect(tester.getRect(art).width, closeTo(large.width, 1));
      expect(find.byType(AnimatedTrackCover), findsNWidgets(2));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets(
    'an open player updates its theme immediately after a new artwork seed',
    (tester) async {
      final state = _State()..legacyPalette = LegacyPaletteMode.nowPlaying;
      addTearDown(state.dispose);
      await tester.pumpWidget(MaterialApp(home: NowPlayingPage(state: state)));
      await tester.pump();
      final player = find.byType(NowPlayingPage);
      Color accent() => Theme.of(
        tester.element(
          find.descendant(of: player, matching: find.byType(Scaffold)).first,
        ),
      ).colorScheme.primary;
      state.setLegacySeed(const Color(0xFF07182A));
      await tester.pump();
      final first = accent();
      state.setLegacySeed(const Color(0xFF381108));
      await tester.pump();
      expect(accent(), isNot(first));
      expect(tester.takeException(), isNull);
    },
  );
}
