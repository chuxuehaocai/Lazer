import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/l10n/app_localizations.dart';
import 'package:lazer_nextgen/network/network_http.dart';
import 'package:lazer_nextgen/network/network_source.dart';
import 'package:lazer_nextgen/network/network_sources_controller.dart';
import 'package:lazer_nextgen/network/network_sources_page.dart';
import 'package:lazer_nextgen/network/network_browse_page.dart';
import 'package:lazer_nextgen/network/podcast_feed.dart';
import 'package:lazer_nextgen/network/podcast_pages.dart';
import 'package:lazer_nextgen/network/radio_station.dart';
import 'package:lazer_nextgen/network/remote_source.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/theme/apple_design.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _PageClient implements RemoteSourceClient {
  final Map<String, List<String>> folders = <String, List<String>>{
    '/': <String>['Music'],
    '/Music': <String>['Album', 'a.flac'],
    '/Music/Album': <String>['b.mp3'],
  };
  final Map<String, List<int>> files = <String, List<int>>{
    '/Music/a.flac': List<int>.generate(10, (int i) => i),
    '/Music/Album/b.mp3': <int>[1, 2, 3],
  };

  @override
  NetworkSourceKind get kind => NetworkSourceKind.webdav;

  List<RemoteEntry> _entries(String path) => <RemoteEntry>[
    for (final String name in folders[path] ?? const <String>[])
      RemoteEntry(
        name: name,
        path: path == '/' ? '/$name' : '$path/$name',
        isDirectory: folders.containsKey(path == '/' ? '/$name' : '$path/$name'),
        size: files[path == '/' ? '/$name' : '$path/$name']?.length,
      ),
  ];

  @override
  Future<RemoteListing> list(String path) async =>
      RemoteListing(path: path, entries: _entries(path));

  @override
  Future<RemoteEntry?> stat(String path) async {
    for (final RemoteEntry entry in _entries(remoteParent(path))) {
      if (entry.path == path) return entry;
    }
    return null;
  }

  @override
  Future<RemoteRead> open(String path, {int start = 0, int? end}) async {
    final List<int> data = files[path] ?? const <int>[];
    return RemoteRead.fromStream(
      Stream<List<int>>.value(data),
      totalBytes: data.length,
    );
  }

  @override
  Future<void> close() async {}
}

const String _feed = '''<rss version="2.0"><channel><title>Night Show</title>
<item><title>Episode One</title><guid>ep-1</guid>
<pubDate>Mon, 06 May 2024 07:00:00 GMT</pubDate>
<enclosure url="http://a.example/1.mp3" type="audio/mpeg"/></item>
<item><title>Episode Two</title><guid>ep-2</guid>
<pubDate>Tue, 07 May 2024 07:00:00 GMT</pubDate>
<enclosure url="http://a.example/2.mp3" type="audio/mpeg"/></item>
</channel></rss>''';

void main() {
  late Directory directory;
  late NetworkSourcesController controller;
  late AppState state;
  bool disposed = false;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    directory = Directory.systemTemp.createTempSync('lazer-network-page');
    controller = NetworkSourcesController(
      persist: false,
      supportDirectory: () async => directory,
      clientFactory: (RemoteSourceConnection connection) async => _PageClient(),
      textFetcher: (Uri uri, {Duration timeout = const Duration(seconds: 20)}) async =>
          NetworkText(body: _feed, uri: uri),
    );
    state = AppState(networkSources: controller);
    await controller.load();
    // The gate binds a real loopback socket, which the fake-async test body
    // cannot do itself.
    await controller.startStreamGate();
  });

  tearDown(() {
    if (!disposed) state.dispose();
    try {
      directory.deleteSync(recursive: true);
    } catch (_) {}
  });

  /// Disposes inside the test body, before the framework checks for pending
  /// timers (the client pool keeps an idle reaper alive while it holds one).
  Future<void> disposeInline(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
    disposed = true;
  }

  /// Widget tests run in a fake-async zone; file and socket work only advances
  /// while a real event loop turn runs. Poll for the outcome instead of
  /// sleeping a fixed time, so a loaded CI machine cannot make this flake.
  Future<void> waitForIo(
    WidgetTester tester,
    bool Function() condition,
  ) async {
    for (var attempt = 0; attempt < 200; attempt++) {
      if (condition()) break;
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump();
    }
    await tester.pump(const Duration(milliseconds: 50));
  }

  Future<void> pumpPage(WidgetTester tester, Widget page) async {
    tester.view.physicalSize = const Size(1100, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppleTheme(brightness: Brightness.dark),
        home: Scaffold(body: page),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('the hub shows the three network sections', (tester) async {
    await pumpPage(tester, NetworkSourcesPage(state: state, controller: controller));
    expect(find.byKey(const ValueKey('network-tab-storage')), findsOneWidget);
    expect(find.byKey(const ValueKey('network-tab-radio')), findsOneWidget);
    expect(find.byKey(const ValueKey('network-tab-podcast')), findsOneWidget);
    expect(find.text('还没有网络存储。添加一个 NAS 地址后，就能直接播放里面的音乐。'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('network-tab-radio')));
    await tester.pumpAndSettle();
    expect(find.text('还没有电台。添加一个流地址，或导入 M3U / PLS 列表。'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('network-tab-podcast')));
    await tester.pumpAndSettle();
    expect(find.text('还没有播客订阅。粘贴一个 RSS 地址就能开始。'), findsOneWidget);
  });

  testWidgets('a saved source, station and podcast render as rows', (tester) async {
    late final NetworkSource source;
    late final RadioStation station;
    late final PodcastSubscription podcast;
    await tester.runAsync(() async {
      source = await controller.addSource(
        NetworkSourceDraft(
          kind: NetworkSourceKind.smb,
          name: 'Living Room',
          host: 'nas.local',
          path: 'Music',
        ),
      );
      station = await controller.addStation(
        name: 'Jazz FM',
        url: 'http://jazz.example/live',
        genre: 'Jazz',
      );
      podcast = await controller.subscribe(
        'https://podcast.example/feed.xml',
      );
    });
    await pumpPage(tester, NetworkSourcesPage(state: state, controller: controller));
    expect(find.byKey(ValueKey<String>('network-source-row-${source.id}')), findsOneWidget);
    expect(find.text('Living Room'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('network-tab-radio')));
    await tester.pumpAndSettle();
    expect(find.text('Jazz FM'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('network-tab-podcast')));
    await tester.pumpAndSettle();
    expect(find.text('Night Show'), findsOneWidget);
    expect(find.byKey(ValueKey<String>('network-podcast-row-${podcast.id}')), findsOneWidget);
    expect(find.textContaining('2 集未听'), findsOneWidget);
    expect(station.id, isNotEmpty);
  });

  testWidgets('tapping a station row starts that station', (tester) async {
    late final RadioStation station;
    await tester.runAsync(() async {
      station = await controller.addStation(
        name: 'Jazz FM',
        url: 'http://jazz.example/live',
      );
    });
    await pumpPage(
      tester,
      NetworkSourcesPage(state: state, controller: controller),
    );
    await tester.tap(find.byKey(const ValueKey('network-tab-radio')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(ValueKey<String>('network-radio-row-${station.id}')),
    );
    await waitForIo(tester, () => state.current != null);
    expect(state.current?.id, 'radio:${station.id}');
    expect(state.current?.title, 'Jazz FM');
  });

  testWidgets('the add-source dialog collects a WebDAV address', (tester) async {
    await pumpPage(tester, NetworkSourcesPage(state: state, controller: controller));
    await tester.tap(find.byKey(const ValueKey('network-add-source')));
    await tester.pumpAndSettle();
    expect(find.text('添加网络源'), findsOneWidget);
    expect(find.byKey(const ValueKey('network-field-host')), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('network-field-host')),
      'nas.local',
    );
    await tester.enterText(
      find.byKey(const ValueKey('network-field-path')),
      '/music',
    );
    await tester.tap(find.byKey(const ValueKey('network-source-save')));
    await waitForIo(tester, () => controller.sources.isNotEmpty);
    expect(controller.sources.length, 1);
    expect(controller.sources.single.host, 'nas.local');
    expect(controller.sources.single.path, '/music');
  });

  testWidgets('the browser walks folders and queues the folder', (tester) async {
    late final NetworkSource source;
    await tester.runAsync(() async {
      source = await controller.addSource(
        NetworkSourceDraft(
          kind: NetworkSourceKind.webdav,
          name: 'NAS',
          host: 'nas.local',
          path: '/',
        ),
      );
    });
    await pumpPage(
      tester,
      NetworkBrowsePage(
        state: state,
        controller: controller,
        sourceId: source.id,
      ),
    );
    expect(find.text('Music'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('network-folder-/Music')));
    await waitForIo(
      tester,
      () => find
          .byKey(const ValueKey('network-file-/Music/a.flac'))
          .evaluate()
          .isNotEmpty,
    );
    expect(
      find.byKey(const ValueKey('network-file-/Music/a.flac')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('network-browse-play-all')));
    await waitForIo(tester, () => state.current != null);
    expect(state.current?.id.startsWith('network:'), isTrue);
    expect(state.queueLength, 1);
    expect(controller.entries.length, 1);
    await disposeInline(tester);
  });

  testWidgets('the podcast page lists episodes and starts playback', (tester) async {
    late final PodcastSubscription podcast;
    await tester.runAsync(() async {
      podcast = await controller.subscribe('https://podcast.example/feed.xml');
    });
    await pumpPage(
      tester,
      PodcastEpisodesPage(
        state: state,
        controller: controller,
        podcastId: podcast.id,
      ),
    );
    expect(find.text('Night Show'), findsOneWidget);
    expect(find.text('Episode One'), findsWidgets);
    expect(find.byKey(const ValueKey('podcast-continue')), findsNothing);
    await tester.tap(find.text('Episode Two').first);
    await waitForIo(tester, () => state.current != null);
    expect(state.current?.id, podcastTrackIdOf(podcast.episodes.first.id));
    expect(state.queueLength, 2);
    expect(
      controller.progressForTrackId(state.current!.id).position,
      Duration.zero,
    );
  });

  testWidgets('the indexed tab lists scanned tracks and plays them', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final NetworkSource source = await controller.addSource(
        NetworkSourceDraft(
          kind: NetworkSourceKind.webdav,
          name: 'NAS',
          host: 'nas.local',
          path: '/',
        ),
      );
      await controller.scan(source.id, '/Music');
    });
    expect(controller.libraryTracks.length, 2);
    await pumpPage(
      tester,
      NetworkSourcesPage(state: state, controller: controller),
    );
    await tester.tap(find.byKey(const ValueKey('network-tab-indexed')));
    await tester.pumpAndSettle();
    expect(find.text('已索引的歌曲'), findsOneWidget);
    expect(find.byKey(const ValueKey('network-indexed-row-0')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('network-indexed-row-0')));
    await waitForIo(tester, () => state.current != null);
    expect(state.current?.id.startsWith('network:'), isTrue);
    expect(state.queueLength, 2);
  });

  testWidgets('the hub fits a phone with large text', (tester) async {
    // 390 × 844 dp on a 3× screen: physicalSize is in physical pixels.
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppleTheme(brightness: Brightness.dark),
        builder: (BuildContext context, Widget? child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(1.8)),
          child: child!,
        ),
        home: Scaffold(
          body: NetworkSourcesPage(state: state, controller: controller),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('network-tab-radio')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    // Two labelled actions fold into one menu at this width.
    expect(find.byKey(const ValueKey('network-radio-actions')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('network-radio-actions')));
    await tester.pumpAndSettle();
    expect(find.text('导入列表'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the page speaks English through the locale tables', (
    tester,
  ) async {
    // The asset bundle is only reachable from a real event loop turn.
    await tester.runAsync(
      () => AppLocalizations.delegate.load(const Locale('en')),
    );
    await tester.runAsync(() async {
      await controller.addSource(
        NetworkSourceDraft(
          kind: NetworkSourceKind.webdav,
          name: 'NAS',
          host: 'nas.local',
        ),
      );
    });
    tester.view.physicalSize = const Size(1100, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppleTheme(brightness: Brightness.dark),
        locale: const Locale('en'),
        localizationsDelegates: const <LocalizationsDelegate<Object>>[
          AppLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: NetworkSourcesPage(state: state, controller: controller),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Network sources'), findsOneWidget);
    // The tab and the section heading share the label.
    expect(find.text('Network storage'), findsWidgets);
    expect(find.text('Add'), findsOneWidget);
    expect(find.text('Internet radio'), findsOneWidget);
    expect(find.text('Podcasts'), findsOneWidget);
  });

  testWidgets('the library card reports what is configured', (tester) async {
    await tester.runAsync(() async {
      await controller.addSource(
        NetworkSourceDraft(
          kind: NetworkSourceKind.webdav,
          name: 'NAS',
          host: 'nas.local',
        ),
      );
      await controller.addStation(
        name: 'Jazz',
        url: 'http://jazz.example/live',
      );
    });
    await pumpPage(
      tester,
      Scaffold(
        body: NetworkSourcesCard(state: state, onOpen: () {}),
      ),
    );
    expect(find.text('网络源'), findsOneWidget);
    expect(find.text('1 个存储 · 1 个电台'), findsOneWidget);
  });
}
