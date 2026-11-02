// SPDX-License-Identifier: GPL-3.0-or-later
// Adapted from LHF (BD4SUP), September 2021. See SOURCE.md and source.py.
import 'dart:math' as math;

import 'still_alive_data.dart';

/// One command from still_alive_credit.py's centisecond table.
/// Modes: 0 newline text, 1 append text, 2 artwork, 3 clear text,
/// 4 start music, 5 start personnel credits, 9 end.
class StillAliveEvent {
  const StillAliveEvent(
    this.words,
    this.centiseconds,
    this.interval,
    this.mode,
  );

  final Object words;
  final int centiseconds;
  final double interval;
  final int mode;
  Duration get scheduledTime => Duration(milliseconds: centiseconds * 10);
}

class StillAliveFrame {
  const StillAliveFrame({
    required this.text,
    required this.asciiArt,
    required this.creditsText,
    required this.cueIndex,
    required this.pageIndex,
    required this.typedCharacters,
    required this.cursorVisible,
    required this.finished,
  });

  final String text;
  final String asciiArt;

  /// Complete revealed prefix. The view can show its last N rows to reproduce
  /// the terminal's independently scrolling personnel panel.
  final String creditsText;
  final int cueIndex;
  final int pageIndex;
  final int typedCharacters;
  final bool cursorVisible;
  final bool finished;
}

/// Absolute terminal timing, without fitting or stretching it to audio length.
/// The page runs the introduction before [musicStart], then reads this score
/// at musicStart + the decoder playhead. Blocking source operations serialize:
/// an overdue command starts only when the previous command has completed.
class StillAliveScore {
  StillAliveScore({
    required Iterable<StillAliveEvent> events,
    required Iterable<String> artwork,
    required this.credits,
  }) : events = List<StillAliveEvent>.unmodifiable(events),
       artwork = List<String>.unmodifiable(artwork) {
    var end = Duration.zero;
    var text = '';
    var art = '';
    var page = 0;
    var music = Duration.zero;
    var credit = Duration.zero;
    var textColumns = 0;
    var textRows = 1;
    for (var i = 0; i < this.events.length; i++) {
      final event = this.events[i];
      final start = event.scheduledTime > end ? event.scheduledTime : end;
      var blocking = Duration.zero;
      if (event.mode <= 1) {
        final words = event.words as String;
        if (words.isNotEmpty) {
          blocking = event.interval < 0
              ? (i + 1 < this.events.length
                    ? this.events[i + 1].scheduledTime - event.scheduledTime
                    : Duration.zero)
              : Duration(microseconds: (event.interval * 1000000).round());
        }
      } else if (event.mode == 2) {
        // drawAA writes 20 rows and sleeps 10 ms after each row. The source
        // table already leaves a 700 ms gap where appropriate; do not add it.
        blocking = const Duration(milliseconds: 200);
      }
      if (blocking.isNegative) {
        throw ArgumentError.value(event, 'events', 'Negative blocking time');
      }
      final entry = _ScoreEntry(i, page, start, blocking, text, art, event);
      _entries.add(entry);
      if (event.mode <= 1) {
        // NULs flush the source serial buffer. They consume typing time and
        // retain the resulting empty row, but must never become visible text.
        text += (event.words as String).replaceAll('\u0000', '');
        if (event.mode == 0) text += '\n';
      } else if (event.mode == 2) {
        art = this.artwork[event.words as int];
      } else if (event.mode == 3) {
        text = '';
        page++;
      } else if (event.mode == 4) {
        music = start;
      } else if (event.mode == 5) {
        credit = start;
      }
      final rows = text.split('\n');
      textRows = math.max(textRows, rows.length);
      for (final row in rows) {
        textColumns = math.max(textColumns, row.length);
      }
      end = start + blocking;
      if (event.mode == 9) break;
    }
    musicStart = music;
    creditsStart = credit;
    duration = end;
    maxTextColumns = textColumns;
    maxTextRows = textRows;
    maxArtColumns = this.artwork.fold<int>(
      0,
      (width, art) => art
          .split('\n')
          .fold<int>(width, (width, row) => math.max(width, row.length)),
    );
    maxArtRows = this.artwork.fold<int>(
      0,
      (height, art) => math.max(height, art.split('\n').length),
    );
    maxCreditsColumns = credits
        .split('\n')
        .fold<int>(0, (width, row) => math.max(width, row.length));
  }

  static const audioAsset = 'assets/easter_eggs/still_alive/sa1.mp3';
  static final original = StillAliveScore(
    events: stillAliveOriginalEvents,
    artwork: stillAliveOriginalArtwork,
    credits: stillAliveOriginalCredits,
  );

  final List<StillAliveEvent> events;
  final List<String> artwork;
  final String credits;
  final List<_ScoreEntry> _entries = [];
  late final Duration musicStart;
  late final Duration creditsStart;
  static const creditsDuration = Duration(seconds: 174);
  late final Duration duration;
  late final int maxTextColumns, maxTextRows, maxArtColumns, maxArtRows;
  late final int maxCreditsColumns;

  /// Personnel credits use their independent 174-second source thread.
  /// The source prints a character before waiting for its scheduled time, so
  /// its first two characters appear immediately, then one per interval.
  String creditsAt(Duration position) {
    if (position < creditsStart || credits.isEmpty) return '';
    final elapsed = position - creditsStart;
    final characters =
        (elapsed.inMicroseconds *
                    credits.length ~/
                    creditsDuration.inMicroseconds +
                2)
            .clamp(0, credits.length);
    return credits.substring(0, characters);
  }

  StillAliveFrame frameAt(Duration position) {
    final now = position.isNegative ? Duration.zero : position;
    if (_entries.isEmpty) {
      return const StillAliveFrame(
        text: '',
        asciiArt: '',
        creditsText: '',
        cueIndex: -1,
        pageIndex: 0,
        typedCharacters: 0,
        cursorVisible: false,
        finished: true,
      );
    }
    var low = 0;
    var high = _entries.length;
    while (low < high) {
      final middle = (low + high) ~/ 2;
      if (_entries[middle].start <= now) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    final entry = _entries[(low - 1).clamp(0, _entries.length - 1)];
    final event = entry.event;
    final elapsed = (now - entry.start).inMicroseconds;
    var text = entry.prefix;
    var art = entry.art;
    var page = entry.page;
    var characters = 0;
    if (event.mode <= 1) {
      final words = event.words as String;
      characters = entry.blocking == Duration.zero
          ? words.length
          : (elapsed * words.length ~/ entry.blocking.inMicroseconds + 1).clamp(
              0,
              words.length,
            );
      text += words.substring(0, characters).replaceAll('\u0000', '');
      if (event.mode == 0 && elapsed >= entry.blocking.inMicroseconds) {
        text += '\n';
      }
    } else if (event.mode == 2) {
      final target = artwork[event.words as int].split('\n');
      final previous = art.isEmpty ? <String>[] : art.split('\n');
      final rows = (elapsed ~/ 10000 + 1).clamp(0, target.length);
      art = [
        for (var row = 0; row < target.length; row++)
          row < rows
              ? target[row]
              : row < previous.length
              ? previous[row]
              : ' ' * maxArtColumns,
      ].join('\n');
    } else if (event.mode == 3) {
      text = '';
      page++;
    }
    final finished = now >= duration;
    return StillAliveFrame(
      text: text,
      asciiArt: art,
      creditsText: creditsAt(now),
      cueIndex: entry.index,
      pageIndex: page,
      typedCharacters: characters,
      cursorVisible: !finished && (now.inMilliseconds ~/ 300).isEven,
      finished: finished,
    );
  }
}

class _ScoreEntry {
  const _ScoreEntry(
    this.index,
    this.page,
    this.start,
    this.blocking,
    this.prefix,
    this.art,
    this.event,
  );
  final int index, page;
  final Duration start, blocking;
  final String prefix, art;
  final StillAliveEvent event;
}
