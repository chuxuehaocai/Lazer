import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/theme/apple_design.dart';
import 'package:lazer_nextgen/theme/lazer_theme.dart';
import 'package:lazer_nextgen/widgets/player_seek_bar.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _track = Track(
  id: 'seek-ink',
  title: 'Track',
  artist: 'Artist',
  album: 'Album',
  duration: Duration(minutes: 4),
  coverSeed: 1,
);

class _SeekState extends AppState {
  @override
  int get queueIndex => 0;
  @override
  Track? get current => _track;
  @override
  double get progress => .25;
  @override
  double get seekLimitFraction => 1;
  @override
  Listenable get all => this;
  @override
  void seek(double value) {}
}

/// The parchment palette exactly as the Early Development plugin declares it.
///
/// Kept literal on purpose: the point of these tests is that the rail reads the
/// skin's own `accent`, so the fixture must carry the same numbers the plugin
/// ships in `plugin/lib/tokens.lua` (`clay = #D97757`, `stone = #CCCBC8`).
LazerThemeTokens _parchment() => LazerThemeTokens.fromJson(<String, Object?>{
  'id': 'parchment.field-notes',
  'name': 'Early Development',
  'version': 1,
  'elements': <String, Object?>{
    'backgroundPlayMode': 'off',
    'colors': <String, Object?>{
      'background': '#F0EEE6',
      'secondaryGroupedBackground': '#FAF9F5',
      'label': '#141413',
      'secondaryLabel': '#87867F',
      'separator': '#CCCBC8',
      'accent': '#D97757',
    },
    // The plugin ships a night variant; without it `buildAppleTheme` reuses
    // the light colours verbatim, which would keep the parchment page — and the
    // clay — even in dark mode.
    'darkColors': <String, Object?>{
      'background': '#191918',
      'secondaryGroupedBackground': '#242423',
      'label': '#F0EEE6',
      'secondaryLabel': '#B5B2A9',
      'separator': '#454540',
      'accent': '#E68E70',
    },
  },
});

Future<void> _mount(
  WidgetTester tester,
  AppState state, {
  LazerThemeTokens? skin,
  Brightness brightness = Brightness.light,
}) async {
  addTearDown(state.dispose);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppleTheme(brightness: brightness, ui: skin ?? LazerThemeTokens.apple),
      home: Scaffold(
        body: Center(
          child: SizedBox(width: 400, child: PlayerSeekBar(state: state)),
        ),
      ),
    ),
  );
  await tester.pump();
}

/// The [SliderThemeData] the rail actually hands to Material's slider.
SliderThemeData _rail(WidgetTester tester) {
  final Finder slider = find.byType(Slider).first;
  final Finder theme = find
      .ancestor(of: slider, matching: find.byType(SliderTheme))
      .first;
  return tester.widget<SliderTheme>(theme).data;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  group('seek rail ink', () {
    testWidgets('the built-in theme keeps the white rail on the cover wash', (
      tester,
    ) async {
      await _mount(tester, _SeekState());
      final SliderThemeData rail = _rail(tester);
      expect(rail.activeTrackColor, Colors.white);
      expect(rail.thumbColor, Colors.white);
      expect(rail.inactiveTrackColor, Colors.white.withValues(alpha: .32));
    });

    testWidgets('a paper skin paints the rail in its own clay', (tester) async {
      await _mount(tester, _SeekState(), skin: _parchment());
      final SliderThemeData rail = _rail(tester);
      const clay = Color(0xFFD97757);
      expect(rail.activeTrackColor, clay);
      expect(rail.thumbColor, clay);
      // The buffered lane must not be plain white: it is the tone that filled
      // the rail from the playhead to the end in the reported screenshot.
      expect(rail.secondaryActiveTrackColor, isNot(Colors.white));
      expect(
        rail.secondaryActiveTrackColor!.a,
        closeTo(.34, .001),
        reason: 'clay at 34% is the quiet lane; a louder alpha reads as a stripe',
      );
      // Past the seek limit stays the design system's divider, not more clay.
      expect(rail.inactiveTrackColor, const Color(0xFFCCCBC8));
    });

    testWidgets('the clay is the token, not the contrast-corrected accent', (
      tester,
    ) async {
      await _mount(tester, _SeekState(), skin: _parchment());
      final SliderThemeData rail = _rail(tester);
      // `adaptiveAccent` darkens clay to reach 4.5:1 against parchment because
      // buttons and body copy are inked with it; that value is #B54B29. A 3 px
      // rail must stay the clay the design system named.
      expect(rail.activeTrackColor, const Color(0xFFD97757));
      expect(rail.activeTrackColor, isNot(const Color(0xFFB54B29)));
    });

    testWidgets('a paper skin in dark mode keeps white on the dark page', (
      tester,
    ) async {
      await _mount(
        tester,
        _SeekState(),
        skin: _parchment(),
        brightness: Brightness.dark,
      );
      final SliderThemeData rail = _rail(tester);
      expect(rail.activeTrackColor, Colors.white);
      expect(rail.thumbColor, Colors.white);
    });

    testWidgets('a skin that keeps the album wash keeps the white rail', (
      tester,
    ) async {
      // Mio-shaped skin: colours, but the player still paints the cover art.
      final skin = LazerThemeTokens.fromJson(<String, Object?>{
        'id': 'demo.flow',
        'elements': <String, Object?>{
          'colors': <String, Object?>{'accent': '#D97757'},
        },
      });
      await _mount(tester, _SeekState(), skin: skin);
      final SliderThemeData rail = _rail(tester);
      expect(rail.activeTrackColor, Colors.white);
    });

    testWidgets('an explicit colour still wins over the skin', (tester) async {
      // `player_bar.dart` passes ColorScheme.primary because the shell bar sits
      // on the dark player surface, not on the page.
      final state = _SeekState();
      addTearDown(state.dispose);
      const explicit = Color(0xFF112233);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppleTheme(ui: _parchment()),
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 400,
                child: PlayerSeekBar(state: state, color: explicit),
              ),
            ),
          ),
        ),
      );
      expect(_rail(tester).activeTrackColor, explicit);
      expect(_rail(tester).thumbColor, explicit);
    });
  });
}
