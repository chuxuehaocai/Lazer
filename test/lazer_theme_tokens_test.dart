import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/theme/lazer_theme.dart';

/// The Lua skin contract: a theme bundle is `{theme: {elements: {...}}}`.
/// These two tests pin the tokens the parchment skin needs so a future
/// refactor cannot silently drop them.
void main() {
  test('parses the now-playing and background tokens', () {
    final tokens = LazerThemeTokens.fromJson(<String, Object?>{
      'id': 'community.naominet.parchment-field-notes',
      'elements': <String, Object?>{
        'groupedCardRadius': 0,
        'controlRadius': 12,
        'glassBlurSigma': 0,
        'railWidth': 232,
        'playerBarHeight': 100,
        'nowPlayingArtworkFraction': .34,
        'nowPlayingArtworkMin': 240,
        'nowPlayingArtworkMax': 440,
        'nowPlayingSidePadding': 32,
        'nowPlayingTitleSize': 30,
        'nowPlayingMetaSize': 18,
        'nowPlayingCoverRadius': 0,
        'backgroundPlayMode': 'off',
        'backgroundOpacity': 1,
        'backgroundBlurSigma': 0,
        'backgroundVeilAlpha': 1,
        'colors': <String, Object?>{'background': '#F0EEE6'},
        'darkColors': <String, Object?>{'background': '#191918'},
      },
    });

    expect(tokens.backgroundPlayMode, 'off');
    expect(tokens.nowPlayingArtworkFraction, .34);
    expect(tokens.nowPlayingCoverRadius, 0);
    expect(tokens.backgroundVeilAlpha, 1);
    expect(tokens.railWidth, 232);
    expect(tokens.colors['background'], isNotNull);
    expect(tokens.darkColors['background'], isNotNull);
  });

  test('unknown background mode keeps the user setting', () {
    final tokens = LazerThemeTokens.fromJson(<String, Object?>{
      'elements': <String, Object?>{'backgroundPlayMode': 'nonsense'},
    });
    expect(tokens.backgroundPlayMode, '');
  });
}
