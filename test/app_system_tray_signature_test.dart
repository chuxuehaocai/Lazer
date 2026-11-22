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
}
