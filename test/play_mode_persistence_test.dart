import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/state/playback_queue_store.dart';
import 'package:lazer_nextgen/state/shuffle_order.dart';
import 'package:shared_preferences/shared_preferences.dart';

AppState _state() => AppState(
  queueStore: PlaybackQueueStore(read: () async => null, write: (_) async {}),
  artworkSeedLoader: (_) async => null,
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final (steps, shuffle, repeat, encoded) in [
    (1, false, LoopMode.all, 'all'),
    (2, false, LoopMode.one, 'one'),
    (3, true, LoopMode.off, 'shuffle'),
    (4, false, LoopMode.off, 'sequential'),
  ]) {
    test(
      'play mode $encoded survives restart and rapid consecutive changes',
      () async {
        final state = _state();
        for (var i = 0; i < steps; i++) {
          state.cyclePlayMode();
        }
        final prefs = await SharedPreferences.getInstance();
        for (
          var i = 0;
          i < 30 && prefs.getString('lazer_play_mode_v1') != encoded;
          i++
        ) {
          await Future<void>.delayed(Duration.zero);
        }
        expect(prefs.getString('lazer_play_mode_v1'), encoded);
        state.dispose();
        final restored = _state();
        try {
          await restored.bootstrap();
          expect(restored.shuffle, shuffle);
          expect(restored.repeat, repeat);
        } finally {
          restored.dispose();
        }
      },
    );
  }

  test(
    'a user mode change while bootstrapping wins over a stored mode',
    () async {
      SharedPreferences.setMockInitialValues({'lazer_play_mode_v1': 'one'});
      final state = _state();
      try {
        final boot = state.bootstrap();
        state.toggleShuffle();
        await boot;
        expect(state.shuffle, isTrue);
        expect(state.repeat, LoopMode.off);
      } finally {
        state.dispose();
      }
    },
  );

  test('independent shuffle and loop settings are restored together', () async {
    final state = _state();
    state.cycleRepeat();
    state.toggleShuffle();
    final prefs = await SharedPreferences.getInstance();
    for (
      var i = 0;
      i < 30 && prefs.getString('lazer_play_mode_v1') != 'shuffle:all';
      i++
    ) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(prefs.getString('lazer_play_mode_v1'), 'shuffle:all');
    state.dispose();
    final restored = _state();
    try {
      await restored.bootstrap();
      expect(restored.shuffle, isTrue);
      expect(restored.repeat, LoopMode.all);
    } finally {
      restored.dispose();
    }
  });

  test(
    'shuffled rounds visit every queue position and never repeat at a round boundary',
    () {
      final order = ShuffleOrder(random: Random(2026));
      var current = 0;
      final first = {current};
      for (var i = 0; i < 19; i++) {
        final next = order.peek(20, current);
        expect(next, isNot(current));
        expect(first.add(next), isTrue);
        order.visit(next);
        current = next;
      }
      expect(first, hasLength(20));
      for (var round = 0; round < 10; round++) {
        final visited = <int>{};
        for (var i = 0; i < 20; i++) {
          final next = order.peek(20, current);
          expect(next, isNot(current));
          expect(visited.add(next), isTrue);
          order.visit(next);
          current = next;
        }
        expect(visited, hasLength(20));
      }
    },
  );

  test('prefetch peeks remain stable until that song is visited', () {
    final order = ShuffleOrder(random: Random(17));
    final next = order.peek(10, 3);
    for (var i = 0; i < 30; i++) {
      expect(order.peek(10, 3), next);
    }
    order.visit(next);
    expect(order.peek(10, next), isNot(next));
    expect(order.peek(1, 0), 0);
    expect(order.peek(4, 2), inInclusiveRange(0, 3));
  });

  test(
    'going back across shuffled rounds does not consume an unheard song',
    () {
      final order = ShuffleOrder(random: Random(27));
      var current = 0;
      for (var i = 0; i < 7; i++) {
        current = order.peek(8, current);
        order.visit(current);
      }
      final previous = current;
      current = order.peek(8, current);
      order.visit(current);
      final firstOfRound = current;
      expect(order.previous(8, current), previous);
      order.visit(previous);
      expect(order.peek(8, previous), firstOfRound);
      order.visit(firstOfRound);
      final round = {firstOfRound};
      for (var i = 0; i < 7; i++) {
        current = order.peek(8, current);
        order.visit(current);
        expect(round.add(current), isTrue);
      }
      expect(round, hasLength(8));
    },
  );

  test('a cancelled shuffled overlap keeps one forward history entry', () {
    final order = ShuffleOrder(random: Random(17));
    final incoming = order.peek(8, 0);
    order.visit(incoming);
    order.revisitNext(incoming);
    expect(order.peek(8, 0), incoming);
    order.visit(incoming);
    expect(order.previous(8, incoming), 0);
    order.visit(0);
    expect(order.peek(8, 0), incoming);
  });

  test(
    'initial shuffle choices cover all eligible songs without modulo bias',
    () {
      final counts = List.filled(6, 0);
      final random = Random(31);
      for (var run = 0; run < 5000; run++) {
        final order = ShuffleOrder(random: random);
        counts[order.peek(6, 2)]++;
      }
      expect(counts[2], 0);
      for (var index = 0; index < counts.length; index++) {
        if (index != 2) expect(counts[index], inInclusiveRange(850, 1150));
      }
    },
  );
}
