import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lazer_nextgen/audio/audio_engine.dart';
import 'package:lazer_nextgen/data/audio_quality.dart';
import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/gateway/gateway.dart';
import 'package:lazer_nextgen/legacy/legacy_background.dart';
import 'package:lazer_nextgen/legacy/legacy_pages.dart';
import 'package:lazer_nextgen/legacy/legacy_player_bar.dart';
import 'package:lazer_nextgen/legacy/legacy_shell.dart';
import 'package:lazer_nextgen/legacy/legacy_theme.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/state/ui_preferences.dart';
import 'package:lazer_nextgen/widgets/lyric_viewport.dart';

const Track _track = Track(
  id: 'precision-fixture',
  title: 'Frozen mesh',
  artist: 'Test artist',
  album: 'Test album',
  duration: Duration(minutes: 3),
  coverSeed: 1,
);

class _Gateway extends NeteaseGateway {
  @override
  Future<Set<int>> likedSongIds(int uid) async => <int>{};
}

/// A loaded source with no clock of its own, so the player counts as playing
/// without any platform channel.
class _Engine implements AudioEngine {
  @override
  bool active = false;

  @override
  Duration position = Duration.zero;

  @override
  Duration? get duration => _track.duration;

  @override
  Stream<void> get completed => const Stream<void>.empty();

  @override
  Future<void> setUrl(String url) async => active = true;

  @override
  Future<void> play() async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> seek(Duration position) async => this.position = position;

  @override
  Future<void> setVolume(double volume) async {}

  @override
  Future<void> stop() async => active = false;

  @override
  void dispose() {}
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
  }) async => 'file:///fixture.mp3';
  @override
  Future<GatewayLyrics?> lyricsFor(Track track) async =>
      const GatewayLyrics(lrc: '[00:00.00]First lyric');
  @override
  Future<List<Track>> playlistTracks(String id) async => <Track>[_track];
}

Widget _app(Widget home) => MaterialApp(
  theme: buildLegacyTheme(brightness: Brightness.dark),
  home: home,
);

/// The flowing canvas never stops on its own, so any test that waits for the
/// tree to settle asks the platform for reduced motion first — the mesh then
/// paints once and holds still.
Widget _reducedMotion(Widget child) => Builder(
  builder: (BuildContext context) => MediaQuery(
    data: MediaQuery.of(context).copyWith(disableAnimations: true),
    child: child,
  ),
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('the precision plan scales the mesh and slows it down', () {
    expect(
      normalizeDynamicBackgroundQuality(0.02),
      kDynamicBackgroundQualityMin,
    );
    expect(normalizeDynamicBackgroundQuality(9), kDynamicBackgroundQualityMax);
    expect(normalizeDynamicBackgroundQuality(double.nan), isNot(isNaN));
    expect(
      normalizeDynamicBackgroundQuality(0.78),
      kDynamicBackgroundQualityDefault,
      reason: 'values snap to the five percent grid',
    );

    final DynamicBackgroundPrecision full = DynamicBackgroundPrecision.of(1);
    expect(full.columns, kFlowMeshColumns);
    expect(full.rows, kFlowMeshRows);
    expect(full.frameInterval, kFlowFrameIntervalFull);
    expect(full.vertexCount, 551);

    final DynamicBackgroundPrecision low = DynamicBackgroundPrecision.of(0.1);
    expect(low.columns, lessThan(full.columns));
    expect(low.rows, lessThan(full.rows));
    expect(low.columns, greaterThanOrEqualTo(4));
    expect(low.rows, greaterThanOrEqualTo(3));
    expect(low.frameInterval, kFlowFrameIntervalLow);

    final DynamicBackgroundPrecision tuned = DynamicBackgroundPrecision.of(
      kDynamicBackgroundQualityDefault,
    );
    expect(tuned.columns, 22);
    expect(tuned.rows, 14);
    expect(tuned.frameInterval.inMilliseconds, 20);
    expect(tuned.vertexCount, lessThan(full.vertexCount));
  });

  test('the setting persists, clamps and resets', () async {
    final AppState state = AppState(catalog: _Catalog());
    addTearDown(state.dispose);
    expect(state.dynamicBackgroundQuality, kDynamicBackgroundQualityDefault);

    await state.setDynamicBackgroundQuality(0.02);
    expect(state.dynamicBackgroundQuality, kDynamicBackgroundQualityMin);
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getDouble('lazer_dynamic_background_quality'),
      kDynamicBackgroundQualityMin,
    );

    final AppState restarted = AppState(catalog: _Catalog());
    addTearDown(restarted.dispose);
    await restarted.bootstrap();
    expect(restarted.dynamicBackgroundQuality, kDynamicBackgroundQualityMin);

    await restarted.resetDynamicBackgroundQuality();
    expect(
      restarted.dynamicBackgroundQuality,
      kDynamicBackgroundQualityDefault,
    );
    expect(
      prefs.getDouble('lazer_dynamic_background_quality'),
      kDynamicBackgroundQualityDefault,
    );
  });

  testWidgets('the settings slider drives the flowing canvas', (tester) async {
    tester.view.physicalSize = const Size(1280, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final AppState state = AppState(catalog: _Catalog());
    addTearDown(state.dispose);

    await tester.pumpWidget(
      _app(
        AnimatedBuilder(
          animation: state,
          builder: (BuildContext context, _) =>
              Scaffold(body: LegacySettingsPage(state: state)),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final Finder slider = find.descendant(
      of: find.byKey(const ValueKey('dynamic-background-quality')),
      matching: find.byType(Slider),
    );
    await tester.ensureVisible(slider);
    await tester.pumpAndSettle();
    expect(tester.widget<Slider>(slider).min, kDynamicBackgroundQualityMin);
    expect(tester.widget<Slider>(slider).max, kDynamicBackgroundQualityMax);
    // The subtitle reports the mesh the canvas actually draws.
    expect(find.textContaining('网格 22×14'), findsOneWidget);

    await tester.drag(slider, const Offset(-400, 0));
    await tester.pumpAndSettle();
    expect(
      state.dynamicBackgroundQuality,
      lessThan(kDynamicBackgroundQualityDefault),
    );
    expect(find.textContaining('网格 22×14'), findsNothing);

    await tester.ensureVisible(
      find.byKey(const ValueKey('dynamic-background-quality-reset')),
    );
    await tester.pump();
    await tester.tap(
      find.byKey(const ValueKey('dynamic-background-quality-reset')),
    );
    await tester.pumpAndSettle();
    expect(state.dynamicBackgroundQuality, kDynamicBackgroundQualityDefault);
    expect(find.textContaining('网格 22×14'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the browse backdrop follows the stored precision', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final AppState state = AppState(catalog: _Catalog());
    addTearDown(state.dispose);

    await tester.pumpWidget(_app(_reducedMotion(LegacyShell(state: state))));
    await tester.pumpAndSettle();

    AlbumFlowBackground flow() => tester.widget<AlbumFlowBackground>(
      find.descendant(
        of: find.byType(LegacyAlbumBackdrop),
        matching: find.byType(AlbumFlowBackground),
      ),
    );
    expect(flow().quality, kDynamicBackgroundQualityDefault);
    expect(flow().preview, isFalse);

    await state.setDynamicBackgroundQuality(0.35);
    await tester.pumpAndSettle();
    expect(flow().quality, 0.35);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the player slides in on the cheap canvas, then on the mesh', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final AppState state = AppState(
      catalog: _Catalog(),
      audioEngine: _Engine(),
    );
    addTearDown(state.dispose);
    await state.setPlayerBackgroundQuality(0.5);
    state.playQueue(const <Track>[_track]);

    await tester.pumpWidget(_app(LegacyShell(state: state)));
    await tester.pump(const Duration(milliseconds: 200));

    AlbumFlowBackground playerFlow() => tester.widget<AlbumFlowBackground>(
      find.descendant(
        of: find.byType(AlbumBlurFlow),
        matching: find.byType(AlbumFlowBackground),
      ),
    );
    bool lyricGate() => tester
        .widget<TickerMode>(
          find
              .ancestor(
                of: find.byType(LyricViewport),
                matching: find.byType(TickerMode),
              )
              .first,
        )
        .enabled;

    await tester.tap(
      find.descendant(
        of: find.byType(LegacyPlayerBar),
        matching: find.text(_track.title),
      ),
    );
    await tester.pump();

    // Entrance frame: one gradient instead of the warped mesh, and a lyric
    // ticker that is held still.
    expect(playerFlow().preview, isTrue);
    expect(playerFlow().animated, isFalse);
    expect(playerFlow().quality, 0.5);
    expect(lyricGate(), isFalse);

    for (int i = 0; i < 34; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(playerFlow().preview, isFalse);
    expect(playerFlow().animated, isTrue);
    expect(lyricGate(), isTrue);
    expect(tester.takeException(), isNull);

    // Stop the transport ticker before the tree goes away.
    state.togglePlay();
    await tester.pump();
  });
}
