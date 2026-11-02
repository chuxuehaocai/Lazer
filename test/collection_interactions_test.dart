import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/data/catalog_details.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/ui/chart_page.dart';
import 'package:lazer_nextgen/ui/playlist_page.dart';
import 'package:lazer_nextgen/theme/apple_design.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/tv/large_screen_pages.dart';
import 'package:lazer_nextgen/tv/large_screen_widgets.dart';
import 'package:lazer_nextgen/tv/tv_mode.dart';
import 'package:lazer_nextgen/widgets/cover_transition.dart';
import 'package:lazer_nextgen/widgets/track_batch_bar.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _tracks = <Track>[
  Track(
    id: '1',
    title: 'First song',
    artist: 'Artist',
    album: 'Album',
    duration: Duration(minutes: 3),
    coverSeed: 1,
  ),
  Track(
    id: '2',
    title: 'Second song',
    artist: 'Artist',
    album: 'Album',
    duration: Duration(minutes: 4),
    coverSeed: 2,
  ),
  Track(
    id: 'local:third',
    title: 'Local song',
    artist: 'Artist',
    album: 'Album',
    duration: Duration(minutes: 5),
    coverSeed: 3,
  ),
];
const _playlist = Playlist(
  id: '12',
  name: 'Collection',
  trackIds: [],
  coverSeed: 1,
  trackCount: 3,
);
const _album = Album(
  id: '9',
  title: 'Collection',
  artist: 'Artist',
  year: '2026',
  coverSeed: 1,
  note: '',
);

MusicChart _chart(String id, {bool matched = true}) => MusicChart(
  id: id,
  title: 'Chart $id',
  source: 'Source',
  issueLabel: 'Current',
  entries: <ChartEntry>[
    for (var index = 0; index < 2; index++)
      ChartEntry(
        rank: index + 1,
        title: '$id song $index',
        artist: 'Artist',
        track: matched ? _tracks[index] : null,
      ),
  ],
);

class _Catalog extends Catalog {
  final Map<String, Completer<MusicChart>> pendingCharts = {};

  @override
  Future<List<Track>?> cachedPlaylistTracks(String playlistId) async => null;
  @override
  Future<List<Track>> playlistTracks(String playlistId) async => _tracks;
  @override
  Future<AlbumDetails> albumDetailsFor(
    String key, {
    bool force = false,
  }) async => const AlbumDetails(album: _album, tracks: _tracks);
  @override
  Future<MusicChart> prepareChart(MusicChart chart, {bool force = false}) {
    return pendingCharts
        .putIfAbsent(chart.id, Completer<MusicChart>.new)
        .future;
  }
}

class _State extends AppState {
  _State(_Catalog catalog) : super(catalog: catalog);
  final List<List<Track>> played = [];
  @override
  void playQueue(List<Track> tracks, {int startIndex = 0}) =>
      played.add(tracks);
}

Widget _app(Widget page, {bool tv = false}) => TvScope(
  active: tv,
  child: MaterialApp(
    theme: buildAppleTheme(brightness: Brightness.dark),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(disableAnimations: true),
      child: child!,
    ),
    home: Scaffold(body: page),
  ),
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final album in <bool>[false, true]) {
    for (final tv in <bool>[false, true]) {
      testWidgets(
        '${tv ? 'large screen' : 'phone'} ${album ? 'album' : 'playlist'} long-press selects tracks and opens selected downloads',
        (tester) async {
          tester.view.physicalSize = tv
              ? const Size(1200, 1000)
              : const Size(430, 1100);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          final state = _State(_Catalog());
          addTearDown(state.dispose);
          await state.setDownloadDirectory('E:\\Downloads');
          final page = tv
              ? LargeScreenCollectionPage(
                  state: state,
                  playlist: _playlist,
                  album: album ? _album : null,
                )
              : AppPlaylistPage(
                  state: state,
                  playlist: _playlist,
                  album: album ? _album : null,
                );
          await tester.pumpWidget(_app(page, tv: tv));
          await tester.pumpAndSettle();
          await tester.longPress(find.text('First song'));
          await tester.pumpAndSettle();
          expect(find.byType(TrackBatchBar), findsOneWidget);
          expect(find.text('已选 1 首'), findsOneWidget);
          expect(state.played, isEmpty);
          await tester.tap(find.text('Second song'));
          await tester.pumpAndSettle();
          expect(find.text('已选 2 首'), findsOneWidget);
          expect(state.played, isEmpty);
          await tester.tap(find.byKey(const ValueKey('batch-download')));
          await tester.pumpAndSettle();
          expect(find.text('下载 2 首歌曲'), findsOneWidget);
          await tester.tap(find.text('取消'));
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(const ValueKey('batch-select-all')));
          await tester.pumpAndSettle();
          expect(find.text('已选 3 首'), findsOneWidget);
          await tester.tap(find.byKey(const ValueKey('batch-download')));
          await tester.pumpAndSettle();
          expect(
            find.text('下载 2 首歌曲'),
            findsOneWidget,
            reason: 'local music is excluded from the download request',
          );
          await tester.tap(find.text('取消'));
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(const ValueKey('batch-select-all')));
          await tester.pumpAndSettle();
          expect(find.text('已选 0 首'), findsOneWidget);
          expect(
            tester
                .widget<IconButton>(
                  find.byKey(const ValueKey('batch-download')),
                )
                .onPressed,
            isNull,
          );
          await tester.tap(find.byKey(const ValueKey('batch-close')));
          await tester.pumpAndSettle();
          expect(find.byType(TrackBatchBar), findsNothing);
          await tester.tap(find.text('First song'));
          expect(state.played, hasLength(1));
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets(
    'holding remote Select enters management without playing and short Select toggles selection',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final state = _State(_Catalog());
      addTearDown(state.dispose);
      await tester.pumpWidget(
        _app(
          LargeScreenCollectionPage(state: state, playlist: _playlist),
          tv: true,
        ),
      );
      await tester.pumpAndSettle();
      final row = find.byType(LargeScreenTrackRow).first;
      final target = tester.widget<LargeScreenTapTarget>(
        find.descendant(of: row, matching: find.byType(LargeScreenTapTarget)),
      );
      target.focusNode!.requestFocus();
      await tester.pumpAndSettle();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.select);
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.text('已选 1 首'), findsOneWidget);
      expect(state.played, isEmpty);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      expect(state.played, isEmpty);
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      expect(find.text('已选 0 首'), findsOneWidget);
      expect(state.played, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  for (final tv in <bool>[false, true]) {
    testWidgets(
      '${tv ? 'large screen' : 'standard'} charts reuse collection headers and clear selection on a new chart',
      (tester) async {
        tester.view.physicalSize = const Size(1200, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final catalog = _Catalog();
        final state = _State(catalog);
        addTearDown(state.dispose);
        final chart = ValueNotifier<MusicChart>(_chart('old', matched: false));
        addTearDown(chart.dispose);
        await tester.pumpWidget(
          _app(
            ValueListenableBuilder<MusicChart>(
              valueListenable: chart,
              builder: (context, value, child) => tv
                  ? LargeScreenChartPage(state: state, chart: value)
                  : AppChartPage(state: state, chart: value),
            ),
            tv: tv,
          ),
        );
        await tester.pump();
        expect(find.text('Chart old'), findsOneWidget);
        expect(
          find.byType(tv ? LargeScreenCollectionHeader : AppPlaylistHeader),
          findsOneWidget,
        );
        expect(
          tester
              .widget<CoverTransitionTarget>(find.byType(CoverTransitionTarget))
              .identity,
          'chart:old',
        );
        chart.value = _chart('new');
        await tester.pumpAndSettle();
        expect(find.text('Chart new'), findsOneWidget);
        await tester.longPress(find.text('new song 0'));
        await tester.pumpAndSettle();
        expect(find.byType(TrackBatchBar), findsOneWidget);
        catalog.pendingCharts['old']!.complete(_chart('old'));
        await tester.pumpAndSettle();
        expect(
          find.text('Chart new'),
          findsOneWidget,
          reason:
              'late matching from a prior chart cannot replace the visible collection',
        );
        chart.value = _chart('third');
        await tester.pumpAndSettle();
        expect(find.text('Chart third'), findsOneWidget);
        expect(find.byType(TrackBatchBar), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
