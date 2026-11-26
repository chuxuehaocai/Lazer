// The tray menu is built from the 0.5.x-compatible `Menu`/`MenuItem` that
// `AppSystemTray` itself uses; the migration is the library's, not this test's.
// ignore_for_file: deprecated_member_use, implementation_imports

import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/data/audio_quality.dart';
import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/gateway/gateway.dart';
import 'package:lazer_nextgen/l10n/app_language.dart';
import 'package:lazer_nextgen/listening/listening_statistics.dart';
import 'package:lazer_nextgen/local/local_library.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/state/playback_queue_store.dart';
import 'package:lazer_nextgen/widgets/app_system_tray.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tray_manager/src/menu.dart';

class _Catalog extends Catalog {
  @override
  Future<HomeFeed?> loadHome({int? userId}) async => null;
  @override
  Future<String?> audioUrlFor(
    Track track, {
    AudioQuality quality = AudioQuality.exhigh,
    bool Function()? isCancelled,
  }) async => null;
  @override
  Future<GatewayLyrics?> lyricsFor(Track track) async => const GatewayLyrics();
}

class _Library extends LocalLibrary {
  @override
  Future<void> load() async {}
}

Track _track(String id) => Track(
  id: id,
  title: 'Song $id',
  artist: 'Artist $id',
  album: 'Album',
  duration: const Duration(minutes: 3),
  coverSeed: 1,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  test('only what the tray shows changes its menu signature', () async {
    final _Library library = _Library();
    final AppState state = AppState(
      catalog: _Catalog(),
      localLibrary: library,
      skipUnavailableSongs: false,
      artworkSeedLoader: (_) async => null,
      listeningStatistics: ListeningStatisticsController(
        read: () async => null,
        write: (_) async {},
      ),
      queueStore: PlaybackQueueStore(
        write: (_) async {},
        read: () async => null,
      ),
    );
    addTearDown(() {
      state.dispose();
      library.dispose();
    });

    final Object idle = AppSystemTray.menuSignature(state);
    var reports = 0;
    state.addListener(() => reports++);

    await state.setHapticsEnabled(false);
    await state.setShowFrameStats(true);
    await state.setLyricFontSize(30);
    expect(reports, 3);
    expect(AppSystemTray.menuSignature(state), idle);

    state.playQueue(<Track>[_track('1'), _track('2')]);
    final Object playing = AppSystemTray.menuSignature(state);
    expect(playing, isNot(idle));

    state.pause();
    final Object paused = AppSystemTray.menuSignature(state);
    expect(paused, isNot(playing));

    state.playTrackAt(1);
    final Object next = AppSystemTray.menuSignature(state);
    expect(next, isNot(paused));
    expect(next, isNot(playing));

    await state.setLanguage(AppLanguage.english);
    expect(AppSystemTray.menuSignature(state), isNot(next));
  });

  test('the menu items carry no onClick of their own', () {
    // tray_manager runs `MenuItem.onClick` and then every `TrayListener`'s
    // `onTrayMenuItemClick` for one click. With both wired, 「暂停」 ran
    // `togglePlay()` twice — pause, immediately play again — so the song kept
    // playing, and 「下一首」 skipped two songs.
    final Menu menu = AppSystemTray.buildContextMenu(
      playPauseLabel: '暂停',
      previousLabel: '上一首',
      nextLabel: '下一首',
      showWindowLabel: '显示主界面',
      exitAppLabel: '退出 Lazer',
      trackLabel: 'Song · Artist',
    );
    final List<MenuItem> items = menu.items!;
    for (final MenuItem item in items) {
      if (item.type == 'separator') continue;
      expect(
        item.onClick,
        isNull,
        reason:
            '${item.key} must be dispatched only by '
            'onTrayMenuItemClick, or one click runs it twice',
      );
    }
    expect(
      items.map((MenuItem item) => item.key).whereType<String>(),
      containsAll(<String>[
        'track_info',
        'toggle_play',
        'previous',
        'next',
        'show_window',
        'exit_app',
      ]),
    );
  });

  test('a tray 暂停 click stops playback once', () async {
    final _Library library = _Library();
    final AppState state = AppState(
      catalog: _Catalog(),
      localLibrary: library,
      skipUnavailableSongs: false,
      artworkSeedLoader: (_) async => null,
      listeningStatistics: ListeningStatisticsController(
        read: () async => null,
        write: (_) async {},
      ),
      queueStore: PlaybackQueueStore(
        write: (_) async {},
        read: () async => null,
      ),
    );
    addTearDown(() {
      state.dispose();
      library.dispose();
    });

    state.playQueue(<Track>[_track('1'), _track('2'), _track('3')]);
    expect(state.playing, isTrue);

    // One click, dispatched the way the native callback does it.
    expect(AppSystemTray.dispatchMenuKey(state, 'toggle_play'), isTrue);
    expect(state.playing, isFalse, reason: '暂停 has to leave it paused');

    expect(AppSystemTray.dispatchMenuKey(state, 'toggle_play'), isTrue);
    expect(state.playing, isTrue);

    AppSystemTray.dispatchMenuKey(state, 'next');
    expect(state.queueIndex, 1, reason: '下一首 moves exactly one song');

    AppSystemTray.dispatchMenuKey(state, 'previous');
    expect(state.queueIndex, 0);

    // An unknown key (a separator, or a future item) is a no-op.
    expect(AppSystemTray.dispatchMenuKey(state, 'track_info'), isFalse);
  });
}
