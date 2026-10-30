import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/audio/audio_engine.dart';
import 'package:lazer_nextgen/data/audio_quality.dart';
import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/gateway/gateway.dart';
import 'package:lazer_nextgen/local/local_library.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/state/scheduled_pause.dart';
import 'package:shared_preferences/shared_preferences.dart';

const window = PauseWindow(
  id: 'night',
  startMinute: 23 * 60,
  endMinute: 7 * 60,
);
const track = Track(
  id: 'scheduled-pause-fixture',
  title: 'Song',
  artist: 'Artist',
  album: 'Album',
  duration: Duration(minutes: 4),
  coverSeed: 1,
);

class _Catalog extends Catalog {
  @override
  Future<String?> audioUrlFor(
    Track track, {
    AudioQuality quality = AudioQuality.exhigh,
  }) async => 'fixture://schedule';
  @override
  Future<GatewayLyrics?> lyricsFor(Track track) async => null;
  @override
  Future<HomeFeed?> loadHome({int? userId}) async => null;
}

class _Engine implements AudioEngine {
  int pauses = 0, plays = 0;
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
  }

  @override
  Future<void> pause() async {
    pauses++;
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

class _Library extends LocalLibrary {
  @override
  Future<void> load() async {}
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test('bootstrap restores saved ranges and active state', () async {
    SharedPreferences.setMockInitialValues({
      AppState.scheduledPauseKey: ScheduledPauseSettings(
        enabled: true,
        windows: [window],
      ).encode(),
    });
    final state = AppState(
      catalog: _Catalog(),
      localLibrary: _Library(),
      scheduledPauseClock: () => DateTime(2026, 10, 30, 23),
    );
    try {
      await state.bootstrap();
      expect(state.scheduledPause.enabled, isTrue);
      expect(state.scheduledPause.windows.single.id, 'night');
      expect(state.scheduledPauseActive, isTrue);
      expect(state.playing, isFalse);
    } finally {
      state.dispose();
    }
  });
  test(
    'ranges include start, exclude end, cross midnight and repeat daily',
    () {
      for (final day in [29, 30]) {
        expect(window.contains(DateTime(2026, 10, day, 23)), isTrue);
        expect(window.contains(DateTime(2026, 10, day, 6, 59, 59)), isTrue);
        expect(window.contains(DateTime(2026, 10, day, 7)), isFalse);
        expect(window.contains(DateTime(2026, 10, day, 22, 59, 59)), isFalse);
      }
      const daytime = PauseWindow(
        id: 'day',
        startMinute: 12 * 60,
        endMinute: 13 * 60,
      );
      expect(daytime.contains(DateTime(2026, 10, 30, 12)), isTrue);
      expect(daytime.contains(DateTime(2026, 10, 30, 13)), isFalse);
      expect(
        window.copyWith(enabled: false).contains(DateTime(2026, 10, 30, 23)),
        isFalse,
      );
    },
  );
  test('multiple overlapping ranges, global toggle and persistence', () {
    final settings = ScheduledPauseSettings(
      enabled: true,
      windows: [
        window,
        const PauseWindow(
          id: 'lunch',
          startMinute: 12 * 60,
          endMinute: 13 * 60,
        ),
        const PauseWindow(
          id: 'overlap',
          startMinute: 12 * 60 + 30,
          endMinute: 14 * 60,
        ),
      ],
    );
    final restored = ScheduledPauseSettings.decode(settings.encode());
    expect(restored.windows, hasLength(3));
    expect(restored.activeAt(DateTime(2026, 10, 30, 13, 30)), isTrue);
    expect(restored.activeAt(DateTime(2026, 10, 30, 14)), isFalse);
    expect(
      restored.copyWith(enabled: false).activeAt(DateTime(2026, 10, 30, 23)),
      isFalse,
    );
    expect(ScheduledPauseSettings.decode('invalid').enabled, isFalse);
    final invalid = ScheduledPauseSettings.decode(
      '{"enabled":true,"windows":[{"id":"bad","start":1440,"end":0},{"id":"same","start":0,"end":0},{"id":"ok","start":10,"end":20},{"id":"ok","start":30,"end":40}]}',
    );
    expect(invalid.windows.map((item) => item.id), ['ok']);
  });
  testWidgets(
    'timer fires at precise boundary and rechecks after clock changes',
    (tester) async {
      var now = DateTime(2026, 10, 30, 22, 59, 59, 500);
      final checks = <bool>[];
      final controller = ScheduledPauseController(
        onCheck: checks.add,
        now: () => now,
      );
      controller.update(
        ScheduledPauseSettings(enabled: true, windows: [window]),
      );
      expect(checks, [false]);
      now = now.add(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 500));
      expect(checks.last, isTrue);
      now = DateTime(2026, 10, 31, 8);
      controller.check();
      expect(checks.last, isFalse);
      now = DateTime(2026, 10, 31, 23);
      await tester.pump(const Duration(seconds: 30));
      expect(checks.last, isTrue);
      controller.dispose();
      final count = checks.length;
      await tester.pump(const Duration(minutes: 2));
      expect(checks, hasLength(count));
    },
  );
  testWidgets(
    'active range pauses playback, blocks play and never auto-resumes',
    (tester) async {
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
      await state.setScheduledPause(
        ScheduledPauseSettings(enabled: true, windows: [window]),
      );
      now = DateTime(2026, 10, 30, 23);
      await tester.pump(const Duration(seconds: 1));
      expect(state.playing, isFalse);
      expect(engine.pauses, 1);
      state.play();
      state.togglePlay();
      state.playTrackAt(0);
      state.playQueue([track]);
      await tester.pump();
      expect(engine.plays, 1);
      now = DateTime(2026, 10, 31, 7);
      state.checkScheduledPause();
      expect(state.playing, isFalse);
      expect(engine.plays, 1);
      state.play();
      await tester.pump();
      expect(engine.plays, 2);
      final saved = (await SharedPreferences.getInstance()).getString(
        AppState.scheduledPauseKey,
      );
      expect(ScheduledPauseSettings.decode(saved).windows.single.id, window.id);
      state.dispose();
    },
  );
  testWidgets('pending play cannot restart engine after schedule pauses', (
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
    expect(engine.plays, 1);
    now = DateTime(2026, 10, 30, 23);
    await state.setScheduledPause(
      ScheduledPauseSettings(enabled: true, windows: [window]),
    );
    engine.playGate!.complete();
    await tester.pump();
    expect(state.playing, isFalse);
    expect(engine.pauses, 2);
    state.dispose();
  });
}
