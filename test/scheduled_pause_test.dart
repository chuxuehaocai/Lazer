import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/audio/audio_engine.dart';
import 'package:lazer_nextgen/data/audio_quality.dart';
import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/gateway/gateway.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/state/scheduled_pause.dart';
import 'package:shared_preferences/shared_preferences.dart';

const track = Track(
  id: 'scheduled-pause-fixture',
  title: 'Song',
  artist: 'Artist',
  album: 'Album',
  duration: Duration(minutes: 4),
  coverSeed: 1,
);

class _Catalog extends Catalog {
  Completer<String?>? urlGate;
  @override
  Future<String?> audioUrlFor(
    Track track, {
    AudioQuality quality = AudioQuality.exhigh,
    bool Function()? isCancelled,
  }) => urlGate?.future ?? Future.value('fixture://schedule');
  @override
  Future<GatewayLyrics?> lyricsFor(Track track) async => null;
  @override
  Future<HomeFeed?> loadHome({int? userId}) async => null;
}

class _Engine implements AudioEngine {
  int pauses = 0, plays = 0;
  bool audible = false;
  Completer<void>? playGate;
  @override
  bool active = false;
  @override
  Duration position = Duration.zero;
  @override
  Duration? get duration => track.duration;
  @override
  Stream<void> get completed => const Stream.empty();
  @override
  Future<void> setUrl(String url) async => active = true;
  @override
  Future<void> play() async {
    plays++;
    await playGate?.future;
    audible = true;
  }

  @override
  Future<void> pause() async {
    pauses++;
    audible = false;
  }

  @override
  Future<void> seek(Duration value) async => position = value;
  @override
  Future<void> setVolume(double volume) async {}
  @override
  Future<void> stop() async => active = false;
  @override
  void dispose() {}
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('daily points fire once and decode old ranges as their start point', () {
    const point = PausePoint(id: 'night', minute: 23 * 60);
    final settings = ScheduledPauseSettings(enabled: true, points: [point]);
    final restored = ScheduledPauseSettings.decode(settings.encode());
    expect(restored.points.single.minute, 23 * 60);
    final migrated = ScheduledPauseSettings.decode(
      '{"enabled":true,"windows":[{"id":"old","start":720,"end":780}]}',
    );
    expect(migrated.points.single.minute, 720);
    expect(restored.points.single.id, point.id);
    expect(restored.points.single.enabled, isTrue);
  });

  testWidgets(
    'controller fires a configured point once and schedules tomorrow',
    (tester) async {
      var now = DateTime(2026, 10, 30, 22, 59, 59, 500);
      var checks = 0;
      final controller = ScheduledPauseController(
        onPause: () => checks++,
        now: () => now,
      );
      controller.update(
        ScheduledPauseSettings(
          enabled: true,
          points: [const PausePoint(id: 'night', minute: 23 * 60)],
        ),
      );
      expect(checks, 0);
      now = DateTime(2026, 10, 30, 23);
      await tester.pump(const Duration(milliseconds: 500));
      expect(checks, 1);
      controller.check();
      expect(checks, 1);
      controller.dispose();
    },
  );

  testWidgets('a point pauses playback but manual play remains available', (
    tester,
  ) async {
    var now = DateTime(2026, 10, 30, 22, 59, 59);
    final engine = _Engine();
    final state = AppState(
      catalog: _Catalog(),
      audioEngine: engine,
      scheduledPauseClock: () => now,
    );
    state.playQueue([track]);
    await tester.pump();
    expect(engine.plays, 1);
    state.seek(.25);
    await tester.pump();
    await state.setScheduledPause(
      ScheduledPauseSettings(
        enabled: true,
        points: [const PausePoint(id: 'night', minute: 23 * 60)],
      ),
    );
    now = DateTime(2026, 10, 30, 23);
    await tester.pump(const Duration(seconds: 1));
    expect(state.playing, isFalse);
    expect(engine.audible, isFalse);
    expect(state.current, track);
    expect(state.queue, [track]);
    expect(state.precisePosition, const Duration(minutes: 1));
    expect(engine.pauses, greaterThanOrEqualTo(1));
    state.play();
    await tester.pump();
    expect(engine.plays, 2);
    expect(engine.audible, isTrue);
    state.checkScheduledPause();
    await tester.pump();
    expect(state.playing, isTrue);
    state.pause();
    state.dispose();
  });

  testWidgets('pending play cannot restart after the point pauses it', (
    tester,
  ) async {
    var now = DateTime(2026, 10, 30, 22);
    final engine = _Engine()..playGate = Completer<void>();
    final state = AppState(
      catalog: _Catalog(),
      audioEngine: engine,
      scheduledPauseClock: () => now,
    );
    state.playQueue([track]);
    await tester.pump();
    now = DateTime(2026, 10, 30, 23);
    await state.setScheduledPause(
      ScheduledPauseSettings(
        enabled: true,
        points: [const PausePoint(id: 'night', minute: 23 * 60)],
      ),
    );
    engine.playGate!.complete();
    await tester.pump();
    expect(state.playing, isFalse);
    expect(engine.audible, isFalse);
    state.dispose();
  });

  testWidgets('sleep timer stops playback and suppresses system resources', (
    tester,
  ) async {
    final engine = _Engine();
    final state = AppState(catalog: _Catalog(), audioEngine: engine);
    addTearDown(state.dispose);
    state.playQueue([track]);
    await tester.pump();
    expect(state.playing, isTrue);
    state.startSleepTimer(const Duration(minutes: 1));
    await tester.pump(const Duration(minutes: 1));
    expect(state.playing, isFalse);
    expect(state.audioResourcesSuppressed, isTrue);
    expect(engine.active, isFalse);
    state.play();
    await tester.pump();
    expect(state.audioResourcesSuppressed, isFalse);
    expect(state.playing, isTrue);
    state.pause();
  });

  testWidgets('foreground resume catches a point missed while suspended', (
    tester,
  ) async {
    var now = DateTime(2026, 10, 30, 22, 59);
    final engine = _Engine();
    final state = AppState(
      catalog: _Catalog(),
      audioEngine: engine,
      scheduledPauseClock: () => now,
    );
    await state.setScheduledPause(
      ScheduledPauseSettings(
        enabled: true,
        points: [const PausePoint(id: 'night', minute: 1380)],
      ),
    );
    state.playQueue([track]);
    await tester.pump();
    expect(engine.audible, isTrue);
    now = DateTime(2026, 10, 31, 0, 15);
    state.synchronizePlaybackAfterResume();
    await tester.pump();
    expect(state.playing, isFalse);
    expect(engine.audible, isFalse);
    final pauses = engine.pauses;
    state.play();
    await tester.pump();
    state.checkScheduledPause();
    expect(engine.pauses, pauses);
    expect(engine.audible, isTrue);
    state.pause();
    state.dispose();
  });

  testWidgets('a late source load cannot start across a pause point', (
    tester,
  ) async {
    var now = DateTime(2026, 10, 30, 22, 59);
    final catalog = _Catalog()..urlGate = Completer<String?>();
    final engine = _Engine();
    final state = AppState(
      catalog: catalog,
      audioEngine: engine,
      scheduledPauseClock: () => now,
    );
    await state.setScheduledPause(
      ScheduledPauseSettings(
        enabled: true,
        points: [const PausePoint(id: 'night', minute: 1380)],
      ),
    );
    state.playQueue([track]);
    await tester.pump();
    expect(engine.plays, 0);
    now = DateTime(2026, 10, 30, 23, 2);
    catalog.urlGate!.complete('fixture://schedule');
    await tester.pump();
    expect(state.playing, isFalse);
    expect(engine.plays, 0);
    expect(engine.audible, isFalse);
    state.play();
    await tester.pump();
    expect(engine.audible, isTrue);
    state.pause();
    state.dispose();
  });

  testWidgets('a late native play rechecks the clock before keeping audio on', (
    tester,
  ) async {
    var now = DateTime(2026, 10, 30, 22, 59);
    final engine = _Engine()..playGate = Completer<void>();
    final state = AppState(
      catalog: _Catalog(),
      audioEngine: engine,
      scheduledPauseClock: () => now,
    );
    await state.setScheduledPause(
      ScheduledPauseSettings(
        enabled: true,
        points: [const PausePoint(id: 'night', minute: 1380)],
      ),
    );
    state.playQueue([track]);
    await tester.pump();
    expect(engine.plays, 1);
    now = DateTime(2026, 10, 30, 23, 2);
    engine.playGate!.complete();
    await tester.pump();
    expect(state.playing, isFalse);
    expect(engine.audible, isFalse);
    engine.playGate = null;
    state.play();
    await tester.pump();
    expect(state.playing, isTrue);
    expect(engine.audible, isTrue);
    state.pause();
    state.dispose();
  });

  testWidgets('manual toggle at the boundary remains a playback request', (
    tester,
  ) async {
    var now = DateTime(2026, 10, 30, 22, 59);
    final engine = _Engine();
    final state = AppState(
      catalog: _Catalog(),
      audioEngine: engine,
      scheduledPauseClock: () => now,
    );
    state.playQueue([track]);
    await tester.pump();
    state.pause();
    await state.setScheduledPause(
      ScheduledPauseSettings(
        enabled: true,
        points: [const PausePoint(id: 'night', minute: 1380)],
      ),
    );
    now = DateTime(2026, 10, 30, 23);
    state.togglePlay();
    await tester.pump();
    expect(state.playing, isTrue);
    expect(engine.audible, isTrue);
    state.pause();
    state.dispose();
  });

  test('bootstrap migrates and persists only old range start points', () async {
    SharedPreferences.setMockInitialValues({
      AppState.scheduledPauseKey:
          '{"enabled":true,"windows":['
          '{"id":"night","start":1380,"end":420},'
          '{"id":"noon","start":720,"end":780,"enabled":false}'
          ']}',
    });
    final state = AppState(
      catalog: _Catalog(),
      scheduledPauseClock: () => DateTime(2026, 10, 30, 12, 30),
    );
    addTearDown(state.dispose);
    await state.bootstrap();
    expect(state.scheduledPause.enabled, isTrue);
    expect(state.scheduledPause.points.map((point) => point.minute), [
      1380,
      720,
    ]);
    expect(state.scheduledPause.points.last.enabled, isFalse);
    final stored = (await SharedPreferences.getInstance()).getString(
      AppState.scheduledPauseKey,
    );
    expect(stored, state.scheduledPause.encode());
    expect(stored, isNot(contains('windows')));
  });
}
