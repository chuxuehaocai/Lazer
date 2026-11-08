import 'support/music_gateway.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lazer_nextgen/data/audio_quality.dart';
import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/player/now_playing_page.dart';
import 'package:lazer_nextgen/ui/player_bar.dart';
import 'package:lazer_nextgen/ui/shell.dart';
import 'package:lazer_nextgen/theme/apple_design.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/state/ui_preferences.dart';
import 'package:lazer_nextgen/widgets/playback_queue_view.dart';
import 'package:lazer_nextgen/widgets/song_comments_view.dart';

const Track _track = Track(
  id: 'fixture:test:song:1939575649',
  title: 'パベル',
  artist: 'いよわ / 重音テト',
  album: 'パベル',
  duration: Duration(minutes: 2, seconds: 26),
  coverSeed: 3,
  translatedTitle: '巴别塔',
);

const String _lrc =
    '[00:00.00]拙いペースを守る 守る\n'
    '[00:06.00]いつの間に建った\n'
    '[00:12.00]未開の塔で答えを考え中\n'
    '[00:18.00]カルチャーを文字で話す 話す';

const String _tlyric =
    '[00:00.00]谨慎地遵守着步调\n'
    '[00:06.00]在不知不觉间建成的\n'
    '[00:12.00]在未开拓的高塔上思考着答案\n'
    '[00:18.00]用文字讲述文化';

class _Gateway extends TestMusicGateway {}

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
  Future<GatewayLyrics?> lyricsFor(Track track) async =>
      const GatewayLyrics(lrc: _lrc, tlyric: _tlyric);
  @override
  Future<List<Track>> playlistTracks(String id) async => <Track>[_track];
}

Widget _app(Widget home) => MaterialApp(
  theme: buildAppleTheme(brightness: Brightness.dark),
  builder: (BuildContext context, Widget? child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(disableAnimations: true),
    child: child!,
  ),
  home: home,
);

Future<AppState> _playing(WidgetTester tester) async {
  final AppState state = AppState(catalog: _Catalog());
  addTearDown(state.dispose);
  state.playQueue(const <Track>[_track]);
  await tester.pump(const Duration(milliseconds: 50));
  return state;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('the legacy palette follows the song only when asked to', () async {
    final AppState state = AppState(catalog: _Catalog());
    addTearDown(state.dispose);
    expect(state.paletteMode, AppPaletteMode.fixed);
    expect(state.artworkSeed, isNull);

    await state.setAppPalette(AppPaletteMode.nowPlaying);
    state.setAppSeed(const Color(0xFFB23A48));
    expect(state.artworkSeed, const Color(0xFFB23A48));
    expect(
      (await SharedPreferences.getInstance()).getString('lazer_legacy_palette'),
      'nowPlaying',
    );

    // The seeded scheme and the fixed scheme must differ in accent.
    final ThemeData fixed = buildAppleTheme(brightness: Brightness.dark);
    final ThemeData seeded = buildAppleTheme(
      brightness: Brightness.dark,
      seedAccent: const Color(0xFFB23A48),
    );
    expect(seeded.colorScheme.primary, isNot(fixed.colorScheme.primary));
    expect(seeded.textTheme.bodyMedium?.fontSize, 15);

    final AppState restarted = AppState(catalog: _Catalog());
    addTearDown(restarted.dispose);
    await restarted.bootstrap();
    expect(restarted.paletteMode, AppPaletteMode.nowPlaying);
    expect(AppPaletteModeLabels.parse('nope'), AppPaletteMode.fixed);
  });

  testWidgets('the legacy player bar fits its 84 dp rule', (tester) async {
    for (final Size size in <Size>[
      const Size(1440, 900),
      const Size(1100, 760),
      const Size(900, 700),
      const Size(520, 900),
    ]) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      final AppState state = await _playing(tester);
      await tester.pumpWidget(_app(AppShell(state: state)));
      await tester.pump(const Duration(milliseconds: 120));
      expect(find.byType(AppPlayerBar), findsOneWidget);
      expect(
        tester.takeException(),
        isNull,
        reason: 'the transport bar overflowed at $size',
      );
    }
    addTearDown(tester.view.reset);
  });

  testWidgets('the legacy shell hosts the queue card and the comments page', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final AppState state = await _playing(tester);
    await tester.pumpWidget(_app(AppShell(state: state)));
    await tester.pump(const Duration(milliseconds: 200));

    await tester.tap(find.byTooltip('播放队列'));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byType(PlaybackQueueView), findsOneWidget);
    // Tapping the barrier closes the card again.
    await tester.tapAt(const Offset(60, 400));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byType(PlaybackQueueView), findsNothing);

    await tester.tap(find.byTooltip('评论'));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byType(SongCommentsView), findsOneWidget);
    await tester.tap(find.byTooltip('返回'));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byType(SongCommentsView), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the legacy now playing page folds onto a narrow window', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(520, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final AppState state = await _playing(tester);
    await tester.pumpWidget(_app(NowPlayingPage(state: state)));
    await tester.pump(const Duration(milliseconds: 120));
    expect(tester.takeException(), isNull);
  });
}
