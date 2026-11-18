import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/data/catalog_details.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/diagnostics/console_session.dart';
import 'package:lazer_nextgen/diagnostics/developer_console.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/theme/apple_design.dart';
import 'package:lazer_nextgen/tv/large_screen_pages.dart';
import 'package:lazer_nextgen/ui/background.dart';
import 'package:lazer_nextgen/ui/developer_console_page.dart';
import 'package:lazer_nextgen/ui/font_settings_page.dart';
import 'package:lazer_nextgen/ui/pages.dart';
import 'package:lazer_nextgen/ui/plugin_manager_page.dart';
import 'package:lazer_nextgen/ui/scheduled_pause_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

Widget _host(Widget child, {double scale = 1}) => MaterialApp(
  theme: buildAppleTheme().copyWith(platform: TargetPlatform.windows),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(
      context,
    ).copyWith(textScaler: TextScaler.linear(scale), disableAnimations: true),
    child: child!,
  ),
  home: Scaffold(body: child),
);

class _Console extends ConsoleSession {
  _Console(this.label);
  final String label;
  final executed = <String>[];
  Completer<void>? pending;
  int listeners = 0;
  bool disposed = false;
  @override
  bool get enabled => true;
  @override
  bool get busy => false;
  @override
  List<ConsoleEntry> get entries => [ConsoleEntry(label)];
  @override
  List<String> get history => [label];
  @override
  String get logs => '';
  @override
  Future<void> execute(String input) async {
    executed.add(input);
    await pending?.future;
  }

  @override
  Future<void> clearLogs() async {}
  @override
  Future<String> report() async => label;
  @override
  void addListener(VoidCallback listener) {
    listeners++;
    super.addListener(listener);
  }

  @override
  void removeListener(VoidCallback listener) {
    listeners--;
    super.removeListener(listener);
  }

  @override
  void dispose() {
    disposed = true;
    super.dispose();
  }
}

class _SearchState extends AppState {
  String source = 'first';
  final requests = <String>[];
  Future<SearchResults> Function(String)? handler;
  @override
  bool get isLocalPlayback => false;
  @override
  String get activeContentKey => source;
  @override
  Future<SearchResults> search(String query) {
    requests.add(query);
    return handler?.call(query) ?? Future.value(SearchResults.empty);
  }

  void changeSource(String value) {
    source = value;
    notifyListeners();
  }
}

final _actions = LargeScreenActions(
  onOpenPlaylist: (_) {},
  onOpenAlbum: (_) {},
  onOpenArtist: (_) {},
  onOpenChart: (_) {},
  onOpenLikes: () {},
  onOpenLocalMusic: () {},
  onOpenSavedAlbums: () {},
  onPlayTracks: (_, _) {},
);

const _artist = ArtistRef(id: 1, name: 'A long artist name for narrow windows');
final _tracks = List.generate(
  12,
  (index) => Track(
    id: 'track-$index',
    title: 'Long song title $index',
    artist: _artist.name,
    album: 'Album',
    duration: const Duration(minutes: 3),
    coverSeed: index,
  ),
);
const _album = Album(
  id: '1',
  title: 'An album with a long name',
  artist: 'Artist',
  year: '2026',
  coverSeed: 1,
  note: 'Album notes',
);
const _playlist = Playlist(
  id: '1',
  name: 'A long playlist title for a narrow window',
  trackIds: [],
  coverSeed: 1,
  trackCount: 12,
  description: 'Description of the collection',
);

class _Catalog extends Catalog {
  @override
  Future<List<Track>?> cachedPlaylistTracks(String playlistId) async => _tracks;
  @override
  Stream<List<Track>> playlistTrackPages(String playlistId) =>
      Stream.value(_tracks);
  @override
  Future<ArtistDetails> artistDetails(
    ArtistRef artist, {
    bool force = false,
  }) async => ArtistDetails(
    artist: artist,
    tracks: _tracks,
    description: 'An artist biography',
    musicCount: 12,
    albumCount: 1,
  );
  @override
  Future<List<Track>> artistSongsFor(
    ArtistRef artist, {
    bool force = false,
  }) async => _tracks;
  @override
  Future<ArtistAlbumPage> artistAlbumPageFor(
    ArtistRef artist, {
    int offset = 0,
    bool force = false,
  }) async =>
      const ArtistAlbumPage(albums: [_album], more: false, receivedCount: 1);
}

class _BrowseState extends AppState {
  _BrowseState() : super(catalog: _Catalog()) {
    collections = const UserCollections(created: [_playlist]);
  }
  @override
  HomeFeed get home => HomeFeed(
    featuredTracks: _tracks,
    quick: _tracks,
    daily: _tracks,
    playlists: [_playlist],
    albums: [_album],
    recommended: [_playlist],
  );
  @override
  bool get isLocalPlayback => false;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
    'console replacement detaches old session and executes in new one',
    (tester) async {
      final first = _Console('First session')..pending = Completer<void>();
      final second = _Console('Second session');
      addTearDown(first.dispose);
      addTearDown(second.dispose);
      await tester.pumpWidget(
        _host(DeveloperConsoleView.remote(session: first)),
      );
      await tester.enterText(
        find.byKey(const ValueKey('developer-console-input')),
        'old command',
      );
      await tester.tap(find.byKey(const ValueKey('developer-console-run')));
      await tester.pumpWidget(
        _host(DeveloperConsoleView.remote(session: second)),
      );
      expect(first.listeners, 0);
      expect(first.disposed, isFalse);
      expect(second.listeners, 1);
      expect(find.text('Second session'), findsOneWidget);
      expect(find.text('First session'), findsNothing);
      first.pending!.complete();
      await tester.pump();
      await tester.enterText(
        find.byKey(const ValueKey('developer-console-input')),
        'new command',
      );
      await tester.tap(find.byKey(const ValueKey('developer-console-run')));
      await tester.pump();
      expect(first.executed, ['old command']);
      expect(second.executed, ['new command']);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(second.listeners, 0);
      expect(second.disposed, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'switching remote and local consoles preserves borrowed sessions',
    (tester) async {
      final remote = _Console('Borrowed session');
      final local = AppState();
      addTearDown(remote.dispose);
      addTearDown(local.dispose);
      await tester.pumpWidget(
        _host(DeveloperConsoleView.remote(session: remote)),
      );
      await tester.pumpWidget(_host(DeveloperConsoleView(state: local)));
      expect(remote.disposed, isFalse);
      expect(remote.listeners, 0);
      await tester.pumpWidget(
        _host(DeveloperConsoleView.remote(session: remote)),
      );
      expect(remote.listeners, 1);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(remote.disposed, isFalse);
      expect(remote.listeners, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('TV search rejects results from a replaced provider', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final pending = Completer<SearchResults>();
    final state = _SearchState()..handler = (_) => pending.future;
    addTearDown(state.dispose);
    await tester.pumpWidget(
      _host(LargeScreenSearchPage(state: state, actions: _actions)),
    );
    await tester.enterText(find.byType(TextField), 'query');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();
    state.handler = (_) async => const SearchResults(
      artists: [ArtistRef(id: 2, name: 'Current artist')],
    );
    state.changeSource('second');
    await tester.pumpAndSettle();
    pending.complete(
      const SearchResults(artists: [ArtistRef(id: 1, name: 'Stale artist')]),
    );
    await tester.pumpAndSettle();
    expect(state.requests, ['query', 'query']);
    expect(find.text('Current artist'), findsOneWidget);
    expect(find.text('Stale artist'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  for (final frameRate in <double?>[null, 0]) {
    testWidgets(
      'unlimited background $frameRate paints every 120 Hz frame and stops hidden',
      (tester) async {
        tester.view.display.refreshRate = 120;
        addTearDown(tester.view.display.resetRefreshRate);
        Widget background({bool enabled = true}) => Directionality(
          textDirection: TextDirection.ltr,
          child: MediaQuery(
            data: const MediaQueryData(),
            child: TickerMode(
              enabled: enabled,
              child: AlbumFlowBackground(
                colors: const [Colors.blue, Colors.orange],
                quality: .1,
                frameRate: frameRate,
              ),
            ),
          ),
        );
        await tester.pumpWidget(background());
        final initial = albumFlowRenderer.debugFrameBuilds;
        for (var frame = 0; frame < 12; frame++) {
          await tester.pump(const Duration(microseconds: 8333));
        }
        expect(albumFlowRenderer.debugFrameBuilds - initial, 12);
        await tester.pumpWidget(background(enabled: false));
        final stopped = albumFlowRenderer.debugFrameBuilds;
        await tester.pump(const Duration(seconds: 1));
        expect(albumFlowRenderer.debugFrameBuilds, stopped);
        expect(tester.binding.transientCallbackCount, 0);
        await tester.pumpWidget(const SizedBox.shrink());
        expect(albumFlowRenderer.debugCachedFrames, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'manual background cap can switch immediately to display cadence',
    (tester) async {
      tester.view.display.refreshRate = 120;
      addTearDown(tester.view.display.resetRefreshRate);
      Widget background(double fps) => Directionality(
        textDirection: TextDirection.ltr,
        child: MediaQuery(
          data: const MediaQueryData(),
          child: AlbumFlowBackground(
            colors: const [Colors.blue, Colors.orange],
            quality: .1,
            frameRate: fps,
          ),
        ),
      );
      await tester.pumpWidget(background(30));
      final initial = albumFlowRenderer.debugFrameBuilds;
      for (var frame = 0; frame < 120; frame++) {
        await tester.pump(const Duration(microseconds: 8333));
      }
      expect(
        albumFlowRenderer.debugFrameBuilds - initial,
        inInclusiveRange(28, 31),
      );
      await tester.pumpWidget(background(0));
      final unlimited = albumFlowRenderer.debugFrameBuilds;
      for (var frame = 0; frame < 12; frame++) {
        await tester.pump(const Duration(microseconds: 8333));
      }
      expect(albumFlowRenderer.debugFrameBuilds - unlimited, 12);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
  );

  for (final width in <double>[320, 720, 1280]) {
    testWidgets(
      'browse and settings pages fit ${width.round()} pixels with large type',
      (tester) async {
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final state = _BrowseState();
        addTearDown(state.dispose);
        final pages = <Widget>[
          AppHomePage(
            state: state,
            onOpenPlaylist: (_) {},
            onPlayTrack: (_, _) {},
            onOpenChart: (_) {},
          ),
          AppLibraryPage(
            state: state,
            onOpenPlaylist: (_) {},
            onOpenLocalMusic: () {},
            onOpenSavedAlbums: () {},
          ),
          AppLikesPage(state: state),
          AppSavedAlbumsPage(state: state),
          AppSettingsPage(state: state, categorized: true),
          AppSettingsPage(state: state),
          FontSettingsPage(state: state),
          PluginManagerPage(state: state),
          ScheduledPauseSettingsPage(state: state),
          AppPlaylistPage(state: state, playlist: _playlist),
          AppArtistPage(
            state: state,
            artist: _artist,
            onOpenAllSongs: () {},
            onOpenAlbums: () {},
            onOpenSingles: () {},
          ),
          AppArtistSongsPage(state: state, artist: _artist),
          AppArtistReleasesPage(
            state: state,
            artist: _artist,
            group: AlbumReleaseGroup.album,
          ),
          AppChartPage(
            state: state,
            chart: const MusicChart(
              id: 'test',
              title: 'A long chart title for a small window',
              source: 'Test chart source',
              issueLabel: '',
              entries: [],
            ),
          ),
        ];
        for (final page in pages) {
          await tester.pumpWidget(_host(page, scale: 1.6));
          await tester.pump();
          expect(
            tester.takeException(),
            isNull,
            reason: '${page.runtimeType} at $width',
          );
          for (var step = 0; step < 30; step++) {
            final scrollables = find.byType(Scrollable);
            if (scrollables.evaluate().isEmpty) break;
            final position = tester
                .state<ScrollableState>(scrollables.first)
                .position;
            if (position.extentAfter <= 0) break;
            await tester.drag(scrollables.first, const Offset(0, -550));
            await tester.pump(const Duration(milliseconds: 350));
            expect(
              tester.takeException(),
              isNull,
              reason: '${page.runtimeType} at $width after scroll $step',
            );
          }
          await tester.pumpWidget(const SizedBox.shrink());
        }
      },
    );
  }
}
