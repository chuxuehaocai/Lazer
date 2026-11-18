import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/gateway/music_models.dart';
import 'package:lazer_nextgen/lyrics/lyric_document.dart';
import 'package:lazer_nextgen/player/artwork_lyrics_layout.dart';
import 'package:lazer_nextgen/player/now_playing_page.dart';
import 'package:lazer_nextgen/plugins/plugin_extensions.dart';
import 'package:lazer_nextgen/plugins/plugin_manager.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/state/sleep_timer.dart';
import 'package:lazer_nextgen/state/ui_preferences.dart';
import 'package:lazer_nextgen/theme/apple_design.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _DialogState extends AppState {
  _DialogState({PluginManager? plugins}) : super(pluginManager: plugins) {
    layoutStyle = AppLayoutStyle.phone;
    playerBackground = AppBackgroundMode.off;
    lyricControlsSeconds = 1;
    lyrics = const [
      LyricLine(Duration.zero, 'The first lyric'),
      LyricLine(Duration(seconds: 10), 'The second lyric'),
    ];
  }

  final sleepDurations = <Duration>[];

  @override
  bool get playing => true;
  @override
  Track get current => const Track(
    id: 'dialog-lifecycle',
    title: 'Dialog lifecycle',
    artist: 'Artist',
    album: 'Album',
    duration: Duration(minutes: 3),
    coverSeed: 1,
  );
  @override
  Future<void> ensureCurrentLyrics({bool force = false}) async {}
  @override
  void playerPresentationChanged(bool visible) {}
  @override
  bool supportsCurrentMusic(MusicCapability capability) =>
      capability == MusicCapability.comments;
  @override
  void startSleepTimer(
    Duration duration, {
    SleepTimerAction action = SleepTimerAction.releaseAudio,
  }) {
    sleepDurations.add(duration);
  }

  void reportPlayback() => notifyListeners();
}

class _PendingPlugin extends PluginManager {
  final completion = Completer<void>();
  final tracks = <Map<String, dynamic>>[];

  @override
  List<LuaPlayerMenuItem> get playerMenuItems => const [
    LuaPlayerMenuItem(
      pluginId: 'pending-plugin',
      pluginName: '',
      id: 'action',
      label: 'Pending plugin action',
    ),
  ];

  @override
  Future<void> invokePlayerMenu(
    LuaPlayerMenuItem item,
    Map<String, dynamic> track,
  ) {
    tracks.add(track);
    return completion.future;
  }
}

Future<_DialogState> _mount(
  WidgetTester tester, {
  PluginManager? plugins,
  bool reduceMotion = true,
}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final state = _DialogState(plugins: plugins);
  addTearDown(state.dispose);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppleTheme(brightness: Brightness.dark, compact: true),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: reduceMotion),
        child: child!,
      ),
      home: NowPlayingPage(state: state),
    ),
  );
  await tester.pump();
  await tester.tap(find.byKey(const ValueKey('now-playing-cover')));
  await tester.pump();
  return state;
}

bool _controlsVisible(WidgetTester tester) => tester
    .widget<ArtworkLyricsLayout>(find.byType(ArtworkLyricsLayout))
    .controlsVisible;

Future<void> _openAction(WidgetTester tester, String label) async {
  await tester.tap(find.byKey(const ValueKey('now-playing-more')));
  await tester.pumpAndSettle();
  await tester.ensureVisible(find.text(label).last);
  await tester.pumpAndSettle();
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}

Future<void> _idle(WidgetTester tester, _DialogState state) async {
  for (var tick = 0; tick < 20; tick++) {
    state.reportPlayback();
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final action in ['睡眠定时', '保存封面', '添加到歌单', '播放队列', '查看评论']) {
    testWidgets('$action suspends idle hiding and cancellation restores it', (
      tester,
    ) async {
      final state = await _mount(tester);
      await _openAction(tester, action);
      await _idle(tester, state);
      expect(_controlsVisible(tester), isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(_controlsVisible(tester), isTrue);
      expect(state.sleepDurations, isEmpty);
      await _idle(tester, state);
      expect(_controlsVisible(tester), isFalse);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('sleep timer selection applies once then resumes idle hiding', (
    tester,
  ) async {
    final state = await _mount(tester);
    await _openAction(tester, '睡眠定时');
    await tester.tap(find.byType(ListTile).first);
    await tester.pumpAndSettle();
    expect(state.sleepDurations, [const Duration(minutes: 15)]);
    expect(_controlsVisible(tester), isTrue);
    await _idle(tester, state);
    expect(_controlsVisible(tester), isFalse);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('disposing the player while a child sheet is open is safe', (
    tester,
  ) async {
    await _mount(tester);
    await _openAction(tester, '睡眠定时');
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 3));
    expect(tester.takeException(), isNull);
  });

  testWidgets('long-press artwork owns its confirmation until cancellation', (
    tester,
  ) async {
    final state = await _mount(tester);
    await tester.longPress(find.byKey(const ValueKey('now-playing-cover')));
    await tester.pumpAndSettle();
    expect(find.text('保存封面图片？'), findsOneWidget);
    await _idle(tester, state);
    expect(_controlsVisible(tester), isTrue);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(_controlsVisible(tester), isTrue);
    await _idle(tester, state);
    expect(_controlsVisible(tester), isFalse);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final failure in [false, true]) {
    testWidgets('plugin completion restores controls after failure=$failure', (
      tester,
    ) async {
      final plugin = _PendingPlugin();
      final state = await _mount(tester, plugins: plugin);
      await _openAction(tester, 'Pending plugin action');
      expect(plugin.tracks.single['id'], state.current.id);
      await _idle(tester, state);
      expect(_controlsVisible(tester), isTrue);
      if (failure) {
        plugin.completion.completeError(StateError('Plugin failed'));
      } else {
        plugin.completion.complete();
      }
      await tester.pump();
      await tester.pump();
      expect(_controlsVisible(tester), isTrue);
      expect(
        find.text('Bad state: Plugin failed'),
        failure ? findsOneWidget : findsNothing,
      );
      await _idle(tester, state);
      expect(_controlsVisible(tester), isFalse);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('late plugin failure after player disposal is ignored safely', (
    tester,
  ) async {
    final plugin = _PendingPlugin();
    await _mount(tester, plugins: plugin);
    await _openAction(tester, 'Pending plugin action');
    await tester.pumpWidget(const SizedBox.shrink());
    plugin.completion.completeError(StateError('Late plugin failure'));
    await tester.pump(const Duration(seconds: 3));
    expect(tester.takeException(), isNull);
  });

  for (final action in ['睡眠定时', '保存封面']) {
    testWidgets('$action ignores repeated taps while More is exiting', (
      tester,
    ) async {
      final state = await _mount(tester, reduceMotion: false);
      await tester.tap(find.byKey(const ValueKey('now-playing-more')));
      await tester.pumpAndSettle();
      final label = find.text(action).last;
      await tester.ensureVisible(label);
      await tester.pumpAndSettle();
      final staleAction = tester
          .widget<InkWell>(
            find.ancestor(of: label, matching: find.byType(InkWell)).first,
          )
          .onTap!;
      final staleClose = tester
          .widget<IconButton>(
            find.descendant(
              of: find.byKey(const ValueKey('now-playing-more-close')),
              matching: find.byType(IconButton),
            ),
          )
          .onPressed!;
      await tester.tap(label);
      // The old More route remains mounted for its reverse animation; two
      // queued taps must not pop the child route it just opened.
      staleAction();
      staleClose();
      await tester.pumpAndSettle();
      expect(find.text(action == '睡眠定时' ? '睡眠定时' : '保存封面图片？'), findsOneWidget);
      expect(state.sleepDurations, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
