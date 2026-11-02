import 'dart:async';
import 'dart:convert';

/// One repeating local wall-clock time at which playback should pause.
class PausePoint {
  const PausePoint({
    required this.id,
    required this.minute,
    this.enabled = true,
  });

  final String id;
  final int minute;
  final bool enabled;

  bool get valid => id.isNotEmpty && minute >= 0 && minute < 1440;

  PausePoint copyWith({int? minute, bool? enabled}) => PausePoint(
    id: id,
    minute: minute ?? this.minute,
    enabled: enabled ?? this.enabled,
  );

  Map<String, Object> toMap() => {'id': id, 'at': minute, 'enabled': enabled};
}

class ScheduledPauseSettings {
  ScheduledPauseSettings({
    this.enabled = false,
    List<PausePoint> points = const [],
  }) : points = List.unmodifiable(points);

  final bool enabled;
  final List<PausePoint> points;

  ScheduledPauseSettings copyWith({bool? enabled, List<PausePoint>? points}) =>
      ScheduledPauseSettings(
        enabled: enabled ?? this.enabled,
        points: points ?? this.points,
      );

  String encode() => jsonEncode({
    'enabled': enabled,
    'points': points.map((item) => item.toMap()).toList(),
  });

  static ScheduledPauseSettings decode(String? source) {
    try {
      final data = jsonDecode(source ?? '') as Map<String, dynamic>;
      final pointData = data['points'];
      // Older installations stored ranges. Only their start times migrate;
      // an end time never creates a period in which playback is blocked.
      final migratingRanges = pointData == null;
      final raw = migratingRanges ? data['windows'] : pointData;
      final points = <PausePoint>[];
      final ids = <String>{};
      for (final item in raw is List ? raw : const []) {
        if (item is! Map || item['id'] is! String) continue;
        final at = item[migratingRanges ? 'start' : 'at'];
        if (at is! int) continue;
        final point = PausePoint(
          id: item['id'] as String,
          minute: at,
          enabled: item['enabled'] != false,
        );
        if (point.valid && ids.add(point.id)) points.add(point);
      }
      return ScheduledPauseSettings(
        enabled: data['enabled'] == true,
        points: points,
      );
    } catch (_) {
      return ScheduledPauseSettings();
    }
  }
}

/// Delivers daily pause events without holding playback in a paused interval.
///
/// A foreground check also catches a point crossed while timers were suspended.
/// Coincident points coalesce, and clock rollback cannot repeat a delivered
/// local date/minute. The small date history is bounded for long-lived players.
class ScheduledPauseController {
  ScheduledPauseController({required this.onPause, DateTime Function()? now})
    : now = now ?? DateTime.now;

  final void Function() onPause;
  final DateTime Function() now;
  ScheduledPauseSettings _settings = ScheduledPauseSettings();
  final Map<int, Set<int>> _firedMinutes = {};
  DateTime? _lastCheck;
  Timer? _timer;
  bool _disposed = false;

  static const _clockCheckInterval = Duration(seconds: 30);
  static const _retainedDates = 32;

  void update(ScheduledPauseSettings value) {
    _settings = value;
    // Editing or enabling a schedule must not retroactively pause for an
    // earlier time. A point in the current minute still takes effect.
    _lastCheck = null;
    check();
  }

  void check() {
    if (_disposed) return;
    _timer?.cancel();
    final time = now();
    final previous = _lastCheck;
    _lastCheck = time;
    final minutes = {
      for (final point in _settings.points)
        if (point.enabled && point.valid) point.minute,
    };
    if (!_settings.enabled || minutes.isEmpty) return;

    var shouldPause = false;
    var delay = _clockCheckInterval;
    for (final minute in minutes) {
      var occurrence = _onDay(time, 0, minute);
      if (occurrence.isAfter(time)) {
        occurrence = _onDay(time, -1, minute);
      }
      final inCurrentMinute = time.hour * 60 + time.minute == minute;
      final crossed =
          previous != null &&
          time.isAfter(previous) &&
          occurrence.isAfter(previous);
      if (inCurrentMinute || crossed) {
        final day =
            occurrence.year * 10000 + occurrence.month * 100 + occurrence.day;
        if ((_firedMinutes[day] ??= {}).add(minute)) shouldPause = true;
      }

      var next = _onDay(time, 0, minute);
      if (!next.isAfter(time)) next = _onDay(time, 1, minute);
      final remaining = next.difference(time);
      if (remaining > Duration.zero && remaining < delay) delay = remaining;
    }
    while (_firedMinutes.length > _retainedDates) {
      _firedMinutes.remove(_firedMinutes.keys.first);
    }
    // A bounded clock check picks up manual clock/time-zone changes even if
    // the next configured point is hours away.
    _timer = Timer(delay, check);
    if (shouldPause) onPause();
  }

  static DateTime _onDay(DateTime time, int dayOffset, int minute) {
    // Construct calendar dates rather than adding 24h across DST boundaries.
    final constructor = time.isUtc ? DateTime.utc : DateTime.new;
    return constructor(
      time.year,
      time.month,
      time.day + dayOffset,
      minute ~/ 60,
      minute % 60,
    );
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
  }
}
