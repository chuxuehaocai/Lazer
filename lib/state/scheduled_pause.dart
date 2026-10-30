import 'dart:async';
import 'dart:convert';

/// A repeating local wall-clock interval, including midnight-spanning ranges.
class PauseWindow {
  const PauseWindow({
    required this.id,
    required this.startMinute,
    required this.endMinute,
    this.enabled = true,
  });

  final String id;
  final int startMinute, endMinute;
  final bool enabled;

  bool get valid =>
      id.isNotEmpty &&
      startMinute >= 0 &&
      startMinute < 1440 &&
      endMinute >= 0 &&
      endMinute < 1440 &&
      startMinute != endMinute;

  bool contains(DateTime now) {
    if (!enabled || !valid) return false;
    final minute = now.hour * 60 + now.minute;
    return startMinute < endMinute
        ? minute >= startMinute && minute < endMinute
        : minute >= startMinute || minute < endMinute;
  }

  PauseWindow copyWith({int? startMinute, int? endMinute, bool? enabled}) =>
      PauseWindow(
        id: id,
        startMinute: startMinute ?? this.startMinute,
        endMinute: endMinute ?? this.endMinute,
        enabled: enabled ?? this.enabled,
      );

  Map<String, Object> toMap() => {
    'id': id,
    'start': startMinute,
    'end': endMinute,
    'enabled': enabled,
  };
}

class ScheduledPauseSettings {
  ScheduledPauseSettings({
    this.enabled = false,
    List<PauseWindow> windows = const [],
  }) : windows = List.unmodifiable(windows);

  final bool enabled;
  final List<PauseWindow> windows;

  bool activeAt(DateTime now) =>
      enabled && windows.any((item) => item.contains(now));

  ScheduledPauseSettings copyWith({
    bool? enabled,
    List<PauseWindow>? windows,
  }) => ScheduledPauseSettings(
    enabled: enabled ?? this.enabled,
    windows: windows ?? this.windows,
  );

  String encode() => jsonEncode({
    'enabled': enabled,
    'windows': windows.map((item) => item.toMap()).toList(),
  });

  static ScheduledPauseSettings decode(String? source) {
    try {
      final data = jsonDecode(source ?? '') as Map<String, dynamic>;
      final windows = <PauseWindow>[];
      final ids = <String>{};
      for (final item in data['windows'] as List? ?? []) {
        if (item is! Map ||
            item['id'] is! String ||
            item['start'] is! int ||
            item['end'] is! int) {
          continue;
        }
        final window = PauseWindow(
          id: item['id'] as String,
          startMinute: item['start'] as int,
          endMinute: item['end'] as int,
          enabled: item['enabled'] != false,
        );
        if (window.valid && ids.add(window.id)) windows.add(window);
      }
      return ScheduledPauseSettings(
        enabled: data['enabled'] == true,
        windows: windows,
      );
    } catch (_) {
      return ScheduledPauseSettings();
    }
  }
}

/// One boundary timer, with a 30s wall-clock recheck for clock/timezone changes.
class ScheduledPauseController {
  ScheduledPauseController({required this.onCheck, DateTime Function()? now})
    : now = now ?? DateTime.now;

  final void Function(bool active) onCheck;
  final DateTime Function() now;
  ScheduledPauseSettings settings = ScheduledPauseSettings();
  Timer? _timer;
  bool _disposed = false;

  bool get active => settings.activeAt(now());

  void update(ScheduledPauseSettings value) {
    settings = value;
    check();
  }

  void check() {
    if (_disposed) return;
    _timer?.cancel();
    final time = now();
    onCheck(settings.activeAt(time));
    if (_disposed) return;
    if (!settings.enabled ||
        !settings.windows.any((item) => item.enabled && item.valid)) {
      return;
    }
    var delay = const Duration(seconds: 30);
    for (final item in settings.windows.where(
      (item) => item.enabled && item.valid,
    )) {
      for (final minute in [item.startMinute, item.endMinute]) {
        // Construct local calendar dates rather than adding 24h across DST.
        var boundary = DateTime(
          time.year,
          time.month,
          time.day,
          minute ~/ 60,
          minute % 60,
        );
        if (!boundary.isAfter(time)) {
          boundary = DateTime(
            time.year,
            time.month,
            time.day + 1,
            minute ~/ 60,
            minute % 60,
          );
        }
        final until = boundary.difference(time);
        if (until > Duration.zero && until < delay) delay = until;
      }
    }
    _timer = Timer(delay, check);
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
  }
}
