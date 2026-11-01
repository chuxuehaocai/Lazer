import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lazer_nextgen/data/audio_quality.dart';
import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/gateway/gateway.dart';
import 'package:lazer_nextgen/legacy/legacy_background.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/state/ui_preferences.dart';

class _Catalog extends Catalog {
  @override
  Future<HomeFeed?> loadHome({int? userId}) async => null;
  @override
  Future<String?> audioUrlFor(
    Track track, {
    AudioQuality quality = AudioQuality.exhigh,
  }) async => null;
  @override
  Future<GatewayLyrics?> lyricsFor(Track track) async => null;
}

Track _track(String id, {String? cover}) => Track(
  id: id,
  title: id,
  artist: 'Artist',
  album: 'Album',
  duration: const Duration(minutes: 3),
  coverSeed: 1,
  coverUrl: cover,
);

AlbumCoverPalette _palette(Color seed) =>
    AlbumCoverPalette(seed: seed, mesh: albumFlowColors(seed));

const Color _green = Color(0xFF2E7D32);
const Color _red = Color(0xFFB71C1C);

/// The palette the canvas is actually painting.
List<Color> _paintedMesh(WidgetTester tester) =>
    tester.widget<AlbumFlowBackground>(find.byType(AlbumFlowBackground)).colors;

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('the player canvas follows the cover the track changed to', (
    tester,
  ) async {
    Widget page(Track track) => MaterialApp(
      home: AlbumBlurFlow(
        track: track,
        mode: LegacyBackgroundMode.nowPlayingStatic,
        pageColor: Colors.black,
        paletteLoader: (String? url) async =>
            url!.endsWith('/a') ? _palette(_green) : _palette(_red),
      ),
    );
    await tester.pumpWidget(page(_track('a', cover: 'https://cover.test/a')));
    await tester.pump();
    expect(_paintedMesh(tester), albumFlowColors(_green));

    await tester.pumpWidget(page(_track('b', cover: 'https://cover.test/b')));
    await tester.pump();
    expect(_paintedMesh(tester), albumFlowColors(_red));

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'a cover that cannot be read leaves the previous colours behind',
    (tester) async {
      // The extractor fails for the *new* track. The canvas must still stop
      // painting the old song's colours, or the backdrop silently lags a track
      // behind whenever a CDN node refuses a cover.
      Widget page(Track track) => MaterialApp(
        home: AlbumBlurFlow(
          track: track,
          mode: LegacyBackgroundMode.nowPlayingStatic,
          pageColor: Colors.black,
          paletteLoader: (String? url) async {
            if (url!.endsWith('/b')) throw StateError('cover refused');
            return _palette(_green);
          },
        ),
      );
      await tester.pumpWidget(page(_track('a', cover: 'https://cover.test/a')));
      await tester.pump();
      expect(_paintedMesh(tester), albumFlowColors(_green));

      await tester.pumpWidget(page(_track('b', cover: 'https://cover.test/b')));
      // The palette reader retries while the cover may still be downloading, so
      // the fallback only lands once that wait is over.
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
      expect(
        _paintedMesh(tester),
        albumFlowColors(albumFallbackSeedForTrack(_track('b'))),
      );
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('the browse backdrop follows the cover the track changed to', (
    tester,
  ) async {
    Widget page(Track track) => MaterialApp(
      home: LegacyAlbumBackdrop(
        track: track,
        mode: LegacyBackgroundMode.nowPlayingStatic,
        uiAlpha: .7,
        paletteLoader: (String? url) async =>
            url!.endsWith('/a') ? _palette(_green) : _palette(_red),
      ),
    );
    await tester.pumpWidget(page(_track('a', cover: 'https://cover.test/a')));
    await tester.pump();
    expect(_paintedMesh(tester), albumFlowColors(_green));

    await tester.pumpWidget(page(_track('b', cover: 'https://cover.test/b')));
    await tester.pump();
    expect(_paintedMesh(tester), albumFlowColors(_red));
  });

  testWidgets('the browse backdrop drops a previous track it cannot replace', (
    tester,
  ) async {
    final List<Color> seeds = <Color>[];
    Widget page(Track track) => MaterialApp(
      home: LegacyAlbumBackdrop(
        track: track,
        mode: LegacyBackgroundMode.nowPlayingStatic,
        uiAlpha: .7,
        onSeed: seeds.add,
        paletteLoader: (String? url) async {
          if (url!.endsWith('/b')) return null;
          return _palette(_green);
        },
      ),
    );
    await tester.pumpWidget(page(_track('a', cover: 'https://cover.test/a')));
    await tester.pump();
    expect(_paintedMesh(tester), albumFlowColors(_green));

    await tester.pumpWidget(page(_track('b', cover: 'https://cover.test/b')));
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    // The canvas follows this track's own seed; the browse accent keeps its
    // previous contract and reports the shared default.
    final Color fallback = albumFallbackSeedForTrack(_track('b'));
    expect(_paintedMesh(tester), albumFlowColors(fallback));
    expect(seeds.last, kAlbumDefaultSeed);
  });

  test(
    'a seed that could not be read is retried once, then left alone',
    () async {
      var calls = 0;
      final state = AppState(
        catalog: _Catalog(),
        artworkSeedLoader: (String? url) async {
          calls++;
          if (calls == 1) throw StateError('cdn refused');
          return _red;
        },
      );
      addTearDown(state.dispose);
      state.legacyPalette = LegacyPaletteMode.nowPlaying;
      state.playQueue(<Track>[_track('a', cover: 'https://cover.test/a')]);
      await Future<void>.delayed(Duration.zero);
      expect(calls, 1);
      expect(state.legacyAccentSeed, isNull);

      // The next report reopens the identity: the artwork is very likely in the
      // cache by then, and latching the failure would strand the accent.
      await state.refreshArtworkSeed();
      expect(calls, 2);
      expect(state.legacyAccentSeed, _red);

      await state.refreshArtworkSeed();
      expect(calls, 2, reason: 'a settled accent is not re-extracted');
    },
  );

  test('a track without a cover is never re-extracted', () async {
    var calls = 0;
    final state = AppState(
      catalog: _Catalog(),
      artworkSeedLoader: (String? url) async {
        calls++;
        return null;
      },
    );
    addTearDown(state.dispose);
    state.playQueue(<Track>[_track('a')]);
    await Future<void>.delayed(Duration.zero);
    await state.refreshArtworkSeed();
    await state.refreshArtworkSeed();
    expect(calls, 1);
  });
}
