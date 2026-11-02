import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/state/scheduled_pause.dart';

ScheduledPauseSettings _settings(
  List<PausePoint> points, {
  bool enabled = true,
}) => ScheduledPauseSettings(enabled: enabled, points: points);

void main() {
  test('point settings reject invalid data without reviving old ranges', () {
    final settings = ScheduledPauseSettings.decode(
      jsonEncode({
        'enabled': true,
        'points': [
          {'id': 'noon', 'at': 720},
          {'id': 'disabled', 'at': 780, 'enabled': false},
          {'id': 'noon', 'at': 800},
          {'id': '', 'at': 10},
          {'id': 'negative', 'at': -1},
          {'id': 'tomorrow', 'at': 1440},
          {'id': 'fraction', 'at': 1.5},
          {'id': 'range-in-points', 'start': 100},
          {'at': 600},
          'invalid',
        ],
      }),
    );
    expect(settings.enabled, isTrue);
    expect(settings.points.map((point) => point.id), ['noon', 'disabled']);
    expect(settings.points.last.enabled, isFalse);
    expect(jsonDecode(settings.encode()), {
      'enabled': true,
      'points': [
        {'id': 'noon', 'at': 720, 'enabled': true},
        {'id': 'disabled', 'at': 780, 'enabled': false},
      ],
    });
    final empty = ScheduledPauseSettings.decode(
      '{"enabled":true,"points":[],"windows":[{"id":"old","start":600,"end":700}]}',
    );
    expect(empty.points, isEmpty);
    for (final value in [null, '', '[]', 'false', '{"points":"bad"}']) {
      expect(ScheduledPauseSettings.decode(value).points, isEmpty);
    }
  });

  test('old ranges migrate their starts and preserve enabled switches', () {
    final migrated = ScheduledPauseSettings.decode(
      '{"enabled":true,"windows":['
      '{"id":"night","start":1380,"end":420},'
      '{"id":"noon","start":720,"end":780,"enabled":false},'
      '{"id":"bad","start":1440,"end":60}'
      ']}',
    );
    expect(migrated.enabled, isTrue);
    expect(migrated.points.map((point) => point.minute), [1380, 720]);
    expect(migrated.points.last.enabled, isFalse);
    final encoded = migrated.encode();
    expect(encoded, isNot(contains('windows')));
    expect(encoded, isNot(contains('"end"')));
    expect(encoded, isNot(contains('"start"')));
  });

  test('settings own their list and copy point fields independently', () {
    final input = [const PausePoint(id: 'noon', minute: 720)];
    final settings = _settings(input);
    input.clear();
    expect(settings.points, hasLength(1));
    expect(() => settings.points.clear(), throwsUnsupportedError);
    final edited = settings.points.single.copyWith(minute: 721, enabled: false);
    expect(edited.id, 'noon');
    expect(edited.minute, 721);
    expect(edited.enabled, isFalse);
    expect(settings.points.single.minute, 720);
  });

  testWidgets(
    'duplicate points coalesce throughout their minute and next day',
    (tester) async {
      var now = DateTime(2026, 10, 30, 23);
      var pauses = 0;
      final controller = ScheduledPauseController(
        now: () => now,
        onPause: () => pauses++,
      );
      addTearDown(controller.dispose);
      final settings = _settings([
        const PausePoint(id: 'one', minute: 1380),
        const PausePoint(id: 'two', minute: 1380),
      ]);
      controller.update(settings);
      expect(pauses, 1);
      for (var second = 1; second < 60; second++) {
        now = DateTime(2026, 10, 30, 23, 0, second);
        controller.check();
      }
      controller.update(settings);
      expect(pauses, 1);
      now = DateTime(2026, 10, 31, 23);
      controller.check();
      controller.check();
      expect(pauses, 2);
      controller.dispose();
    },
  );

  testWidgets('resuming after several missed points pauses once', (
    tester,
  ) async {
    var now = DateTime(2026, 10, 30, 22, 55);
    var pauses = 0;
    final controller = ScheduledPauseController(
      now: () => now,
      onPause: () => pauses++,
    );
    addTearDown(controller.dispose);
    controller.update(
      _settings([
        const PausePoint(id: 'night', minute: 1380),
        const PausePoint(id: 'late', minute: 1390),
      ]),
    );
    now = DateTime(2026, 10, 31, 1);
    controller.check();
    expect(pauses, 1);
    controller.check();
    expect(pauses, 1);
    now = DateTime(2026, 10, 31, 23);
    controller.check();
    expect(pauses, 2);
    now = DateTime(2026, 10, 31, 23, 10);
    controller.check();
    expect(pauses, 3);
    controller.dispose();
  });

  testWidgets('heartbeat detects a forward clock jump past a pause point', (
    tester,
  ) async {
    var now = DateTime(2026, 10, 30, 12);
    var pauses = 0;
    final controller = ScheduledPauseController(
      now: () => now,
      onPause: () => pauses++,
    );
    addTearDown(controller.dispose);
    controller.update(_settings([const PausePoint(id: 'night', minute: 1380)]));
    now = DateTime(2026, 10, 30, 23, 20);
    await tester.pump(const Duration(seconds: 30));
    expect(pauses, 1);
    now = DateTime(2026, 10, 30, 23, 21);
    await tester.pump(const Duration(seconds: 30));
    expect(pauses, 1);
    controller.dispose();
  });

  testWidgets('clock rollback does not repeat a delivered local point', (
    tester,
  ) async {
    var now = DateTime(2026, 10, 30, 22, 59);
    var pauses = 0;
    final controller = ScheduledPauseController(
      now: () => now,
      onPause: () => pauses++,
    );
    addTearDown(controller.dispose);
    controller.update(_settings([const PausePoint(id: 'night', minute: 1380)]));
    now = DateTime(2026, 10, 30, 23);
    controller.check();
    now = DateTime(2026, 10, 30, 22);
    controller.check();
    now = DateTime(2026, 10, 30, 23, 2);
    controller.check();
    expect(pauses, 1);
    now = DateTime(2026, 10, 31, 23);
    controller.check();
    expect(pauses, 2);
    controller.dispose();
  });

  testWidgets('enabling or editing does not catch earlier disabled times', (
    tester,
  ) async {
    var now = DateTime(2026, 10, 30, 22, 59);
    var pauses = 0;
    final controller = ScheduledPauseController(
      now: () => now,
      onPause: () => pauses++,
    );
    addTearDown(controller.dispose);
    final point = const PausePoint(id: 'night', minute: 1380);
    controller.update(_settings([point], enabled: false));
    now = DateTime(2026, 10, 30, 23, 1);
    controller.update(_settings([point]));
    expect(pauses, 0);
    controller.update(_settings([point.copyWith(minute: 1382)]));
    now = DateTime(2026, 10, 30, 23, 2);
    controller.check();
    expect(pauses, 1);
    controller.dispose();
  });

  testWidgets('individual switches and invalid points never deliver a pause', (
    tester,
  ) async {
    var now = DateTime(2026, 10, 30, 22);
    var pauses = 0;
    final controller = ScheduledPauseController(
      now: () => now,
      onPause: () => pauses++,
    );
    addTearDown(controller.dispose);
    controller.update(
      _settings([
        const PausePoint(id: 'disabled', minute: 1380, enabled: false),
        const PausePoint(id: 'invalid', minute: 2000),
      ]),
    );
    now = DateTime(2026, 10, 31);
    await tester.pump(const Duration(days: 1));
    controller.check();
    expect(pauses, 0);
    controller.dispose();
  });

  testWidgets('calendar dates repeat across leap-day and year boundaries', (
    tester,
  ) async {
    var now = DateTime.utc(2028, 2, 28, 23, 59, 59);
    var pauses = 0;
    final controller = ScheduledPauseController(
      now: () => now,
      onPause: () => pauses++,
    );
    addTearDown(controller.dispose);
    controller.update(_settings([const PausePoint(id: 'midnight', minute: 0)]));
    now = DateTime.utc(2028, 2, 29);
    await tester.pump(const Duration(seconds: 1));
    expect(pauses, 1);
    now = DateTime.utc(2029, 1, 1, 0, 5);
    controller.check();
    expect(pauses, 2);
    controller.dispose();
  });

  testWidgets('disposal cancels timers and later checks', (tester) async {
    var now = DateTime(2026, 10, 30, 22, 59, 59);
    var pauses = 0;
    final controller = ScheduledPauseController(
      now: () => now,
      onPause: () => pauses++,
    );
    controller.update(_settings([const PausePoint(id: 'night', minute: 1380)]));
    controller.dispose();
    now = DateTime(2026, 10, 30, 23);
    await tester.pump(const Duration(seconds: 1));
    controller.check();
    expect(pauses, 0);
  });
}
