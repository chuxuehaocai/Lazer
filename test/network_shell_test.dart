import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/data/audio_quality.dart';
import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/network/network_source.dart';
import 'package:lazer_nextgen/network/network_sources_controller.dart';
import 'package:lazer_nextgen/network/remote_source.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/theme/apple_design.dart';
import 'package:lazer_nextgen/ui/player_bar.dart';
import 'package:lazer_nextgen/ui/shell.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/music_gateway.dart';

class _Gateway extends TestMusicGateway {}

class _Catalog extends Catalog {
  _Catalog() : super(gateway: _Gateway());

  @override
  HomeFeed? get home => const HomeFeed(
    recommended: <Playlist>[],
    featuredTracks: <Track>[],
    quick: <Track>[],
    playlists: <Playlist>[],
    albums: <Album>[],
  );

  @override
  Future<HomeFeed?> loadHome({int? userId}) async => home;

  @override
  Future<String?> audioUrlFor(
    Track track, {
    AudioQuality quality = AudioQuality.exhigh,
  }) async => null;
}

class _Client implements RemoteSourceClient {
  @override
  NetworkSourceKind get kind => NetworkSourceKind.webdav;

  @override
  Future<RemoteListing> list(String path) async => RemoteListing(
    path: path,
    entries: <RemoteEntry>[
      RemoteEntry(
        name: 'Album',
        path: '/Album',
        isDirectory: true,
      ),
      RemoteEntry(
        name: 'song.flac',
        path: '/song.flac',
        isDirectory: false,
        size: 4,
      ),
    ],
  );

  @override
  Future<RemoteEntry?> stat(String path) async => null;

  @override
  Future<RemoteRead> open(String path, {int start = 0, int? end}) async =>
      RemoteRead.fromStream(
        Stream<List<int>>.value(<int>[1, 2, 3, 4]),
        totalBytes: 4,
      );

  @override
  Future<void> close() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late NetworkSourcesController controller;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    directory = Directory.systemTemp.createTempSync('lazer-shell-network');
    controller = NetworkSourcesController(
      supportDirectory: () async => directory,
      clientFactory: (RemoteSourceConnection connection) async => _Client(),
      persist: false,
    );
  });

  tearDown(() {
    controller.dispose();
    try {
      directory.deleteSync(recursive: true);
    } catch (_) {}
  });

  testWidgets('网络源 opens inside the shell content pane', (tester) async {
    late final String sourceId;
    await tester.runAsync(() async {
      final NetworkSource source = await controller.addSource(
        NetworkSourceDraft(
          kind: NetworkSourceKind.webdav,
          name: 'Living Room',
          host: 'nas.local',
          path: '/',
        ),
      );
      sourceId = source.id;
    });
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final AppState state = AppState(
      catalog: _Catalog(),
      networkSources: controller,
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppleTheme(brightness: Brightness.dark),
        builder: (BuildContext context, Widget? child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: child!,
        ),
        home: AppShell(state: state),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('音乐库').first);
    await tester.pumpAndSettle();
    final Finder card = find.byKey(
      const ValueKey<String>('open-network-sources'),
    );
    await tester.scrollUntilVisible(
      card,
      300,
      scrollable: find
          .descendant(
            of: find.byType(CustomScrollView),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.pumpAndSettle();
    await tester.tap(card);
    await tester.pumpAndSettle();

    // The shell's player bar is still on stage: the page swapped inside the
    // content pane instead of covering a pushed route.
    expect(find.byType(AppPlayerBar), findsOneWidget);
    expect(find.byKey(const ValueKey('network-tab-storage')), findsOneWidget);
    expect(find.byTooltip('返回'), findsOneWidget);

    await tester.tap(
      find.byKey(ValueKey<String>('network-source-row-$sourceId')),
    );
    await tester.pumpAndSettle();
    expect(find.text('Album'), findsOneWidget);
    expect(find.byType(AppPlayerBar), findsOneWidget);

    await tester.tap(find.byTooltip('返回'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('network-tab-storage')), findsOneWidget);
    await tester.tap(find.byTooltip('返回'));
    await tester.pumpAndSettle();
    expect(card, findsOneWidget);
    // Dispose inside the test body: the controller's idle reaper and the
    // shell's ticker must stop before the binding checks for pending timers.
    state.dispose();
  });
}
