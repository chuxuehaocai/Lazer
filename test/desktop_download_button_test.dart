import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lazer_nextgen/data/audio_quality.dart';
import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/downloads/download_manager.dart';
import 'package:lazer_nextgen/theme/apple_design.dart';
import 'package:lazer_nextgen/player/desktop_now_playing.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/widgets/accessible_controls.dart';

const Track _onlineTrack = Track(
  id: '1',
  title: '在线歌曲',
  artist: '音乐人',
  album: '专辑',
  duration: Duration(minutes: 3),
  coverSeed: 1,
);

const Track _localTrack = Track(
  id: 'local:abc',
  title: '本地歌曲',
  artist: '音乐人',
  album: '专辑',
  duration: Duration(minutes: 3),
  coverSeed: 2,
);

class _Catalog extends Catalog {
  @override
  Future<String?> audioUrlFor(
    Track track, {
    AudioQuality quality = AudioQuality.exhigh,
  }) async => null;
}

/// Keeps a download task in the resolving state so the button can be checked
/// while work is in flight.
class _HangingCatalog extends Catalog {
  @override
  Future<AudioSource?> audioSourceFor(
    Track track, {
    AudioQuality quality = AudioQuality.exhigh,
    bool useCache = true,
  }) => Completer<AudioSource?>().future;
}

Widget _page(AppState state, Track track) => MaterialApp(
  theme: buildAppleTheme(),
  home: Scaffold(
    body: DesktopNowPlaying(
      state: state,
      track: track,
      artwork: const SizedBox.square(dimension: 120),
      lyrics: const SizedBox.shrink(),
      comments: const SizedBox.shrink(),
      queue: const SizedBox.shrink(),
      pane: DesktopNowPlayingPane.lyrics,
      onPaneChanged: (_) {},
      onBack: () {},
      onSaveArtwork: () {},
      onFullscreen: () {},
      controlsVisible: true,
      onActivity: () {},
    ),
  ),
);

void main() {
  late Directory directory;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    directory = await Directory.systemTemp.createTemp(
      'lazer-desktop-download-',
    );
  });

  tearDown(() async {
    await directory.delete(recursive: true);
  });

  testWidgets('the desktop header button opens the real download dialog', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final AppState state = AppState(catalog: _Catalog());
    addTearDown(state.dispose);
    await state.setDownloadDirectory(directory.path);
    await tester.pumpWidget(_page(state, _onlineTrack));

    await tester.tap(find.byKey(const ValueKey<String>('desktop-download')));
    await tester.pumpAndSettle();

    expect(find.text('下载歌曲'), findsOneWidget);
    expect(find.text(directory.path), findsOneWidget);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('下载歌曲'), findsNothing);
  });

  testWidgets('the button follows a running download and opens the queue', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final DownloadManager manager = DownloadManager(catalog: _HangingCatalog());
    addTearDown(manager.dispose);
    final AppState state = AppState(
      catalog: _Catalog(),
      downloadManager: manager,
    );
    addTearDown(state.dispose);
    await state.setDownloadDirectory(directory.path);
    manager.enqueue(
      <Track>[_onlineTrack],
      quality: AudioQuality.exhigh,
      directory: directory.path,
    );
    await tester.pumpWidget(_page(state, _onlineTrack));

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    final AccessibleIconButton button = tester.widget<AccessibleIconButton>(
      find.byKey(const ValueKey<String>('desktop-download')),
    );
    expect(button.tooltip, '下载任务');

    await tester.tap(find.byKey(const ValueKey<String>('desktop-download')));
    await tester.pump();
    expect(find.text('下载任务'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('local files keep the download action disabled', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final AppState state = AppState(catalog: _Catalog());
    addTearDown(state.dispose);
    await tester.pumpWidget(_page(state, _localTrack));

    final AccessibleIconButton button = tester.widget<AccessibleIconButton>(
      find.byKey(const ValueKey<String>('desktop-download')),
    );
    expect(button.onPressed, isNull);
    expect(button.tooltip, '本地歌曲无需下载');
  });
}
