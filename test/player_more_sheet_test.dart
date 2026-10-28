import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lazer_nextgen/data/audio_quality.dart';
import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/gateway/gateway.dart';
import 'package:lazer_nextgen/legacy/legacy_theme.dart';
import 'package:lazer_nextgen/player/now_playing_page.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/widgets/playback_queue_view.dart';

const Track _track = Track(
  id: 'more-fixture',
  title: 'More fixture',
  artist: 'Test artist',
  album: 'Test album',
  duration: Duration(minutes: 3),
  coverSeed: 1,
);

class _Catalog extends Catalog {
  @override
  Future<String?> audioUrlFor(
    Track track, {
    AudioQuality quality = AudioQuality.exhigh,
  }) async => null;

  @override
  Future<GatewayLyrics?> lyricsFor(Track track) async => const GatewayLyrics(
    lrc: '[00:00.00]First lyric\n[00:05.00]Second lyric\n[00:10.00]Third lyric',
  );
}

Future<AppState> _pumpPlayer(WidgetTester tester) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final AppState state = AppState(catalog: _Catalog());
  addTearDown(state.dispose);
  state.playQueue(const <Track>[_track]);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildLegacyTheme(brightness: Brightness.dark),
      home: NowPlayingPage(state: state),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  return state;
}

/// Matches inside the sheet only: the page title, the composer line and the
/// transport repeat some of the same words.
Finder _inSheet(Finder matching) =>
    find.descendant(of: find.byType(BottomSheet), matching: matching);

Future<void> _openMore(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('now-playing-more')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('the phone header collapses its actions into one button', (
    tester,
  ) async {
    await _pumpPlayer(tester);

    expect(find.byKey(const ValueKey('now-playing-more')), findsOneWidget);
    expect(find.byTooltip('更多'), findsOneWidget);
    expect(find.byTooltip('返回'), findsOneWidget);
    for (final String gone in <String>[
      '歌词',
      '添加到歌单',
      '下载歌曲',
      '查看评论',
      '播放队列',
    ]) {
      expect(
        find.byTooltip(gone),
        findsNothing,
        reason: '$gone moved into the sheet',
      );
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('更多 opens the song sheet with details and every action', (
    tester,
  ) async {
    final AppState state = await _pumpPlayer(tester);
    await _openMore(tester);

    expect(_inSheet(find.text('歌曲详情')), findsOneWidget);
    expect(_inSheet(find.text('专辑')), findsOneWidget);
    expect(_inSheet(find.text('Test album')), findsOneWidget);
    expect(_inSheet(find.text('时长')), findsOneWidget);
    expect(_inSheet(find.text('3:00')), findsOneWidget);
    expect(_inSheet(find.text('音质')), findsOneWidget);
    expect(_inSheet(find.text(state.playbackQuality.label)), findsOneWidget);
    expect(_inSheet(find.text('来源')), findsOneWidget);
    expect(_inSheet(find.text('在线播放')), findsOneWidget);

    for (final String action in <String>[
      '歌词',
      '保存封面',
      '添加到歌单',
      '下载歌曲',
      '查看评论',
      '播放队列',
    ]) {
      expect(
        _inSheet(find.text(action)),
        findsOneWidget,
        reason: '$action is missing',
      );
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('the sheet opens the lyrics and the queue', (tester) async {
    await _pumpPlayer(tester);

    await _openMore(tester);
    await tester.tap(_inSheet(find.text('歌词')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byKey(const ValueKey('mobile-lyrics')), findsOneWidget);

    await _openMore(tester);
    await tester.tap(_inSheet(find.text('播放队列')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(PlaybackQueueView), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
