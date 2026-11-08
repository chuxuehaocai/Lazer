import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/local/local_library.dart';
import 'package:lazer_nextgen/plugins/plugin_manager.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/state/playback_queue_store.dart';
import 'package:lazer_nextgen/theme/apple_design.dart';
import 'package:lazer_nextgen/ui/home_pages.dart';

class _Catalog extends Catalog {
  int searches = 0;
  @override
  Future<SearchResults> search(String query) async {
    searches++;
    throw StateError('No network search in local mode');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late LocalLibrary library;
  late _Catalog catalog;
  late AppState state;
  const local = Track(
    id: 'local:test',
    title: 'Local song',
    artist: 'Singer',
    album: 'Record',
    duration: Duration(minutes: 3),
    coverSeed: 1,
  );
  const cached = Track(
    id: 'fixture:connection:song:cloud',
    title: 'Cached song',
    artist: 'Other singer',
    album: 'Record',
    duration: Duration(minutes: 3),
    coverSeed: 2,
  );
  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'lazer_recent_tracks_v1': jsonEncode([cached.toJson(), local.toJson()]),
    });
    root = await Directory.systemTemp.createTemp('lazer-local-mode-');
    library = LocalLibrary(
      supportDirectory: () async => root,
      documentsDirectory: () async => root,
    );
    await library.load();
    for (final track in [local, cached]) {
      final file = await File(
        '${root.path}/${track.title}.mp3',
      ).writeAsBytes([1]);
      await library.addTracks([
        LocalTrack(
          track: track,
          path: file.path,
          source: track == cached
              ? LocalTrackSource.cache
              : LocalTrackSource.scan,
          modifiedAt: DateTime.now(),
          addedAt: DateTime.now(),
        ),
      ]);
    }
    catalog = _Catalog();
    state = AppState(
      catalog: catalog,
      localLibrary: library,
      pluginManager: PluginManager(
        rootDirectory: Directory('${root.path}/plugins'),
      ),
      queueStore: PlaybackQueueStore(
        read: () async => null,
        write: (_) async {},
      ),
    );
    await state.bootstrap();
  });
  tearDown(() async {
    state.dispose();
    library.dispose();
    await root.delete(recursive: true);
  });

  test(
    'local search covers song metadata and caches without calling the cloud',
    () async {
      expect((await state.search('OTHER Record')).tracks.single.id, cached.id);
      expect((await state.search('local')).tracks.single.localPath, isNotNull);
      expect((await state.search('missing')).tracks, isEmpty);
      expect(catalog.searches, 0);
      expect(state.recentTracks.map((track) => track.id), [
        cached.id,
        local.id,
      ]);
      expect(
        state.recentTracks.every((track) => track.localPath != null),
        isTrue,
      );
    },
  );

  testWidgets('local Home renders Recent with no remote feed', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppleTheme(),
        home: Scaffold(
          body: AppHomePage(
            state: state,
            onOpenPlaylist: (_) {},
            onPlayTrack: (_, _) {},
            onOpenChart: (_) {},
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('最近播放'), findsOneWidget);
    expect(find.text(local.title), findsOneWidget);
    expect(find.text(cached.title), findsOneWidget);
    expect(find.text('每日推荐'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
