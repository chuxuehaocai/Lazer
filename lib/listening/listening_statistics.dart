import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../data/models.dart';
import '../local/coalescing_writer.dart';
import '../storage/listening_statistics_store.dart';

enum ListeningRange { today, last7Days, last30Days, allTime }

class ListeningTrackStatistics {
  const ListeningTrackStatistics({
    required this.track,
    required this.duration,
    required this.playCount,
    required this.skipCount,
  });

  final Track track;
  final Duration duration;
  final int playCount;
  final int skipCount;
}

class ListeningStatisticsSnapshot {
  const ListeningStatisticsSnapshot({
    required this.totalDuration,
    required this.playCount,
    required this.skipCount,
    required this.hourlyDuration,
    required this.mostSkipped,
    required this.mostPlayed,
    required this.firstRecordedAt,
  });

  final Duration totalDuration;
  final int playCount;
  final int skipCount;
  final List<Duration> hourlyDuration;
  final List<ListeningTrackStatistics> mostSkipped;
  final List<ListeningTrackStatistics> mostPlayed;
  final DateTime? firstRecordedAt;

  int? get peakHour {
    var peak = -1;
    for (var hour = 0; hour < 24; hour++) {
      if (hourlyDuration[hour] > Duration.zero &&
          (peak < 0 || hourlyDuration[hour] > hourlyDuration[peak])) {
        peak = hour;
      }
    }
    return peak < 0 ? null : peak;
  }
}

/// Private, device-local history, independent of an online account's play log.
///
/// Only advancing engine positions accrue listening time. Explicit seeks suspend
/// sampling until their command settles; unexpected jumps beyond elapsed real
/// time are discarded. Pausing and changing quality preserve a play, whereas a
/// completed replay starts a new one. One second of heard audio qualifies a play.
class ListeningStatisticsController extends ChangeNotifier {
  ListeningStatisticsController({
    DateTime Function()? now,
    Future<String?> Function()? read,
    Future<void> Function(String)? write,
    ListeningStatisticsStore? store,
    this.persistenceInterval = const Duration(seconds: 10),
  }) : _now = now ?? DateTime.now {
    final diskStore = store ?? ListeningStatisticsStore();
    _read = read ?? diskStore.read;
    _write = write ?? diskStore.write;
    _writer = CoalescingWriter(_persist);
    ready = _restore();
  }

  final DateTime Function() _now;
  late final Future<String?> Function() _read;
  late final Future<void> Function(String) _write;
  final Duration persistenceInterval;
  late final CoalescingWriter _writer;
  late final Future<void> ready;
  final Map<String, _Day> _days = {};
  bool loaded = false;
  bool _disposed = false;
  bool _dirty = false;
  Timer? _saveTimer;
  DateTime? _lastNotified;
  DateTime? _firstRecordedAt;
  Track? _track;
  Duration _sessionHeard = Duration.zero;
  bool _sessionCounted = false;
  Duration? _lastPosition;
  DateTime? _lastSample;
  bool _suspended = true;

  /// Selects a fresh playback session; loading alone records nothing.
  void begin(Track track, Duration position) {
    if (_disposed) return;
    if (_track?.id != track.id) {
      end();
      _track = track;
    } else {
      _track = track;
    }
    rebase(position);
  }

  /// Stops counting progress during pause, source reload, or an in-flight seek.
  void suspend() {
    _suspended = true;
    _lastPosition = null;
    _lastSample = null;
  }

  /// Acknowledges a play/seek at the actual engine position, without crediting it.
  void rebase(Duration position) {
    _suspended = false;
    _lastPosition = position;
    _lastSample = _now();
  }

  void sample(Duration position) {
    if (_disposed || _suspended || _track == null) return;
    final now = _now();
    final before = _lastPosition;
    final sampledAt = _lastSample;
    _lastPosition = position;
    _lastSample = now;
    if (before == null || sampledAt == null) return;
    final delta = position - before;
    final elapsed = now.difference(sampledAt);
    // Backend clocks can report coarse position updates, hence the tolerance.
    // Large app-suspension gaps still count when the engine really advanced.
    if (delta <= Duration.zero ||
        elapsed.isNegative ||
        delta > elapsed + const Duration(milliseconds: 750)) {
      return;
    }
    _recordDuration(_track!, delta, now);
    _sessionHeard += delta;
    final countedNow =
        !_sessionCounted && _sessionHeard >= const Duration(seconds: 1);
    if (countedNow) {
      _sessionCounted = true;
      _day(now).track(_track!).plays++;
    }
    _changed(forceNotify: countedNow);
  }

  /// Only a deliberate switch to a different recording is a skip. Selection
  /// changes before any audio, previous-to-restart, and natural ends are excluded.
  void recordSkipTo(Track? target) {
    final track = _track;
    if (_disposed ||
        track == null ||
        target?.id == track.id ||
        _sessionHeard <= Duration.zero) {
      return;
    }
    _day(_now()).track(track).skips++;
    _changed(forceNotify: true);
  }

  /// Ends a play, including a single-track loop. Pause must use [suspend].
  void end() {
    _track = null;
    _sessionHeard = Duration.zero;
    _sessionCounted = false;
    suspend();
    unawaited(flush());
  }

  ListeningStatisticsSnapshot snapshot(ListeningRange range) {
    final now = _now();
    final today = DateTime(now.year, now.month, now.day);
    final start = switch (range) {
      ListeningRange.today => today,
      ListeningRange.last7Days => DateTime(now.year, now.month, now.day - 6),
      ListeningRange.last30Days => DateTime(now.year, now.month, now.day - 29),
      ListeningRange.allTime => null,
    };
    final hours = List<int>.filled(24, 0);
    final tracks = <String, _TrackTotal>{};
    for (final entry in _days.entries) {
      final date = DateTime.tryParse(entry.key);
      if (date == null ||
          date.isAfter(today) ||
          (start != null && date.isBefore(start))) {
        continue;
      }
      for (var hour = 0; hour < 24; hour++) {
        hours[hour] += entry.value.hours[hour];
      }
      for (final total in entry.value.tracks.values) {
        (tracks[total.track.id] ??= _TrackTotal(total.track)).add(total);
      }
    }
    final statistics = tracks.values.map((total) => total.snapshot()).toList();
    final skipped = statistics.where((value) => value.skipCount > 0).toList()
      ..sort((a, b) {
        final count = b.skipCount.compareTo(a.skipCount);
        return count != 0 ? count : a.track.id.compareTo(b.track.id);
      });
    final played = statistics.where((value) => value.playCount > 0).toList()
      ..sort((a, b) {
        final count = b.playCount.compareTo(a.playCount);
        if (count != 0) return count;
        final duration = b.duration.compareTo(a.duration);
        return duration != 0 ? duration : a.track.id.compareTo(b.track.id);
      });
    return ListeningStatisticsSnapshot(
      totalDuration: Duration(milliseconds: hours.fold(0, (a, b) => a + b)),
      playCount: statistics.fold(0, (sum, item) => sum + item.playCount),
      skipCount: statistics.fold(0, (sum, item) => sum + item.skipCount),
      hourlyDuration: List.unmodifiable(
        hours.map((ms) => Duration(milliseconds: ms)),
      ),
      mostSkipped: List.unmodifiable(skipped),
      mostPlayed: List.unmodifiable(played),
      firstRecordedAt: _firstRecordedAt,
    );
  }

  void _recordDuration(Track track, Duration duration, DateTime end) {
    var cursor = end.subtract(duration);
    _firstRecordedAt =
        _firstRecordedAt == null || cursor.isBefore(_firstRecordedAt!)
        ? cursor
        : _firstRecordedAt;
    while (cursor.isBefore(end)) {
      final nextHour = DateTime(
        cursor.year,
        cursor.month,
        cursor.day,
        cursor.hour + 1,
      );
      final until = nextHour.isBefore(end) ? nextHour : end;
      final ms = until.difference(cursor).inMilliseconds;
      final day = _day(cursor);
      day.hours[cursor.hour] += ms;
      day.track(track).milliseconds += ms;
      cursor = until;
    }
  }

  _Day _day(DateTime date) {
    final key =
        '${date.year.toString().padLeft(4, '0')}-'
        '${date.month.toString().padLeft(2, '0')}-'
        '${date.day.toString().padLeft(2, '0')}';
    return _days[key] ??= _Day();
  }

  void _changed({bool forceNotify = false}) {
    _dirty = true;
    _saveTimer ??= Timer(persistenceInterval, () {
      _saveTimer = null;
      unawaited(flush());
    });
    final now = _now();
    if (forceNotify ||
        _lastNotified == null ||
        now.difference(_lastNotified!) >= const Duration(seconds: 1)) {
      _lastNotified = now;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> _restore() async {
    try {
      final raw = await _read();
      if (raw != null) {
        final decoded = jsonDecode(raw);
        if (decoded is Map && decoded['version'] == 1) {
          final recorded = decoded['firstRecordedAt'];
          final first = recorded is String ? DateTime.tryParse(recorded) : null;
          if (first != null &&
              (_firstRecordedAt == null || first.isBefore(_firstRecordedAt!))) {
            _firstRecordedAt = first;
          }
          final days = decoded['days'];
          final metadata = <String, Track>{};
          final encodedTracks = decoded['tracks'];
          if (encodedTracks is Map) {
            for (final entry in encodedTracks.entries) {
              try {
                metadata[entry.key as String] = Track.fromJson(
                  Map<String, dynamic>.from(entry.value as Map),
                );
              } catch (_) {
                // Other recordings remain usable if one row is damaged.
              }
            }
          }
          if (days is Map) {
            for (final entry in days.entries) {
              if (entry.key is! String ||
                  DateTime.tryParse(entry.key) == null) {
                continue;
              }
              try {
                final restored = _Day.decode(entry.value, metadata);
                (_days[entry.key] ??= _Day()).add(restored);
              } catch (_) {
                // Preserve other days if just one stored row is damaged.
              }
            }
          }
        }
      }
    } catch (_) {
      // A corrupt or unavailable store never prevents audio playback.
    } finally {
      loaded = true;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> flush() async {
    _saveTimer?.cancel();
    _saveTimer = null;
    await ready;
    if (!_dirty) return;
    await _writer.request();
  }

  Future<void> _persist() async {
    try {
      final tracks = <String, Object?>{};
      for (final day in _days.values) {
        for (final total in day.tracks.values) {
          tracks.putIfAbsent(
            total.track.id,
            () => total.track.toJson()..remove('localPath'),
          );
        }
      }
      final payload = <String, Object?>{
        'version': 1,
        'firstRecordedAt': _firstRecordedAt?.toIso8601String(),
        'tracks': tracks,
        'days': _days.map((key, day) => MapEntry(key, day.encode())),
      };
      _dirty = false;
      final raw = _days.length > 30
          ? await compute(_encodeStatistics, payload)
          : _encodeStatistics(payload);
      await _write(raw);
    } catch (_) {
      _dirty = true;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _saveTimer?.cancel();
    unawaited(flush());
    super.dispose();
  }
}

class _Day {
  final List<int> hours = List.filled(24, 0);
  final Map<String, _TrackTotal> tracks = {};
  _TrackTotal track(Track track) => tracks[track.id] ??= _TrackTotal(track);

  void add(_Day other) {
    for (var hour = 0; hour < 24; hour++) {
      hours[hour] += other.hours[hour];
    }
    for (final total in other.tracks.values) {
      track(total.track).add(total);
    }
  }

  Map<String, Object> encode() => {
    'hours': hours,
    'tracks': tracks.map((key, total) => MapEntry(key, total.encode())),
  };

  static _Day decode(dynamic raw, Map<String, Track> metadata) {
    final result = _Day();
    final hours = raw['hours'] as List;
    if (hours.length != 24) throw const FormatException('Invalid hour bucket');
    for (var hour = 0; hour < 24; hour++) {
      result.hours[hour] = _count(hours[hour]);
    }
    for (final entry in (raw['tracks'] as Map).entries) {
      final track = metadata[entry.key];
      if (track == null) continue;
      final counts = entry.value as List;
      if (counts.length != 3) continue;
      result.tracks[track.id] = _TrackTotal(track)
        ..milliseconds = _count(counts[0])
        ..plays = _count(counts[1])
        ..skips = _count(counts[2]);
    }
    return result;
  }
}

class _TrackTotal {
  _TrackTotal(this.track);
  final Track track;
  int milliseconds = 0;
  int plays = 0;
  int skips = 0;

  void add(_TrackTotal other) {
    milliseconds += other.milliseconds;
    plays += other.plays;
    skips += other.skips;
  }

  ListeningTrackStatistics snapshot() => ListeningTrackStatistics(
    track: track,
    duration: Duration(milliseconds: milliseconds),
    playCount: plays,
    skipCount: skips,
  );

  List<int> encode() => [milliseconds, plays, skips];
}

int _count(dynamic value) => value is num && value >= 0 ? value.toInt() : 0;

String _encodeStatistics(Map<String, Object?> value) => jsonEncode(value);
