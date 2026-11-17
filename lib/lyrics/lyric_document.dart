import '../gateway/gateway.dart';
import 'ttml_parser.dart';

class LyricWord {
  const LyricWord(this.start, this.duration, this.text);
  final Duration start;
  final Duration duration;
  final String text;
}

class LyricLine {
  const LyricLine(
    this.time,
    this.text, {
    this.translation,
    this.romanization,
    this.words = const [],
    this.end,
  });
  final Duration time;
  final String text;
  final String? translation;
  final String? romanization;
  final List<LyricWord> words;
  final Duration? end;
}

/// Port of LrcRow.kt and LyricTimeline.kt: both fractional separators and
/// multiple timestamps are supported; untimed JSON credits are ignored.
///
/// The official parser (`word-lyric`) accepts one
/// or two digits for the minute and second fields, scales a one-to-three digit
/// fraction by its length (`.5` is 500 ms, `.05` is 50 ms) and drops rows
/// whose seconds field is 60 or more.
///
/// `[offset:±N]` is applied to every timestamp: a positive offset moves the
/// lyrics later, which is the direction the tag is defined in. Lines that would
/// land before zero are clamped to the start of the song. Without this, a file
/// that ships an offset highlights and seeks one offset away from the words.
final RegExp _lrcStamp = RegExp(r'\[(\d{1,2}):(\d{1,2})(?:[.:](\d{1,3}))?\]');
final RegExp _lrcWordStamp = RegExp(r'<(\d{1,2}):(\d{1,2})(?:[.:](\d{1,3}))?>');
final RegExp _lrcOffsetTag = RegExp(
  r'\[offset:\s*([+-]?\d+)\s*\]',
  caseSensitive: false,
);

List<LyricLine> parseLrc(String? source) {
  if (source == null || source.trim().isEmpty) return const [];
  final rows = source.split(RegExp(r'[\r\n]+'));
  final offset = _lrcOffset(rows);
  if (rows.any((row) => _lrcWordStamp.hasMatch(row))) {
    final enhanced = _parseEnhancedLrc(rows, offset);
    if (enhanced.isNotEmpty) return enhanced;
  }
  return _parsePlainLrc(rows, offset);
}

Duration _lrcOffset(List<String> rows) {
  var offset = Duration.zero;
  for (final row in rows) {
    final match = _lrcOffsetTag.firstMatch(row);
    final milliseconds = match == null ? null : int.tryParse(match.group(1)!);
    if (milliseconds != null) offset = Duration(milliseconds: milliseconds);
  }
  return offset;
}

Duration _lrcTime(Match match) {
  final fraction = (match.group(3) ?? '').padRight(3, '0');
  return Duration(
    minutes: int.parse(match.group(1)!),
    seconds: int.parse(match.group(2)!),
    milliseconds: int.parse(fraction),
  );
}

Duration _shiftLrcTime(Duration value, Duration offset) {
  final shifted = value + offset;
  return shifted.isNegative ? Duration.zero : shifted;
}

List<LyricLine> _parsePlainLrc(List<String> rows, Duration offset) {
  final lines = <LyricLine>[];
  for (final row in rows) {
    final matches = _lrcStamp.allMatches(row).toList();
    if (matches.isEmpty) continue;
    final text = row.substring(matches.last.end).trim();
    for (final match in matches) {
      final seconds = int.parse(match.group(2)!);
      if (seconds >= 60) continue;
      lines.add(LyricLine(_shiftLrcTime(_lrcTime(match), offset), text));
    }
  }
  lines.sort((a, b) => a.time.compareTo(b.time));
  return lines;
}

/// Parses enhanced LRC/ELRC rows such as:
///
/// `[00:00.000]<00:00.000>春<00:00.242>归<00:00.484>处`
///
/// Word timestamps are absolute song positions. The duration of a word is
/// the distance to the next word; the last word uses the next line's start
/// when available. A one millisecond minimum keeps malformed or repeated
/// timestamps renderable without creating a negative duration.
List<LyricLine> _parseEnhancedLrc(List<String> rows, Duration offset) {
  final parsed = <_EnhancedLrcLine>[];
  for (final row in rows) {
    final wordMatches = _lrcWordStamp.allMatches(row).toList();
    if (wordMatches.isEmpty) continue;
    final lineMatches = _lrcStamp.allMatches(row).toList();
    final timedWords = <_EnhancedLrcWord>[];
    for (var i = 0; i < wordMatches.length; i++) {
      final match = wordMatches[i];
      final end = i + 1 < wordMatches.length
          ? wordMatches[i + 1].start
          : row.length;
      final text = row.substring(match.end, end);
      if (text.isEmpty) continue;
      final seconds = int.parse(match.group(2)!);
      if (seconds >= 60) continue;
      timedWords.add(
        _EnhancedLrcWord(_shiftLrcTime(_lrcTime(match), offset), text),
      );
    }
    if (timedWords.isEmpty) continue;
    final lineTimes = lineMatches.isEmpty
        ? <Duration>[timedWords.first.start]
        : [
            for (final match in lineMatches)
              if (int.parse(match.group(2)!) < 60)
                _shiftLrcTime(_lrcTime(match), offset),
          ];
    for (final time in lineTimes) {
      parsed.add(_EnhancedLrcLine(time, timedWords));
    }
  }
  if (parsed.isEmpty) return const [];
  parsed.sort((a, b) => a.time.compareTo(b.time));
  final lines = <LyricLine>[];
  for (var i = 0; i < parsed.length; i++) {
    final line = parsed[i];
    final nextLineTime = i + 1 < parsed.length ? parsed[i + 1].time : null;
    final words = <LyricWord>[];
    for (var wordIndex = 0; wordIndex < line.words.length; wordIndex++) {
      final word = line.words[wordIndex];
      final nextWord = wordIndex + 1 < line.words.length
          ? line.words[wordIndex + 1].start
          : nextLineTime;
      final end = nextWord == null || nextWord <= word.start
          ? word.start + const Duration(milliseconds: 1)
          : nextWord;
      words.add(LyricWord(word.start, end - word.start, word.text));
    }
    lines.add(
      LyricLine(
        line.time,
        line.words.map((word) => word.text).join(),
        words: words,
        end: words.last.start + words.last.duration,
      ),
    );
  }
  return lines;
}

class _EnhancedLrcLine {
  const _EnhancedLrcLine(this.time, this.words);
  final Duration time;
  final List<_EnhancedLrcWord> words;
}

class _EnhancedLrcWord {
  const _EnhancedLrcWord(this.start, this.text);
  final Duration start;
  final String text;
}

/// Port of WordLyrics.kt; word offsets are absolute song positions. The
/// official parser also accepts full-width commas between the timing fields,
/// which some YRC tracks ship with.
List<LyricLine> parseYrc(String? source) {
  if (source == null || source.trim().isEmpty) return const [];
  final linePattern = RegExp(r'^\[(-?\d+)[,，](-?\d+)\](.*)$');
  final wordPattern = RegExp(
    r'\((\d+)[,，](\d+)[,，](\d+)\)(.*?)(?=\(\d+[,，]\d+[,，]\d+\)|$)',
  );
  final lines = <LyricLine>[];
  for (final raw in source.split(RegExp(r'[\r\n]+'))) {
    final line = linePattern.firstMatch(raw.trim());
    if (line == null) continue;
    final words = <LyricWord>[
      for (final word in wordPattern.allMatches(line.group(3)!))
        if (word.group(4)!.isNotEmpty)
          LyricWord(
            Duration(milliseconds: int.parse(word.group(1)!)),
            Duration(
              milliseconds: int.parse(
                word.group(2)!,
              ).clamp(1, 0x1FFFFFFFFFFFFF),
            ),
            word.group(4)!,
          ),
    ];
    if (words.isEmpty) continue;
    final time = Duration(milliseconds: int.parse(line.group(1)!));
    lines.add(
      LyricLine(
        time,
        words.map((word) => word.text).join(),
        words: words,
        end: time + Duration(milliseconds: int.parse(line.group(2)!)),
      ),
    );
  }
  lines.sort((a, b) => a.time.compareTo(b.time));
  return lines;
}

const Duration _translationWindow = Duration(milliseconds: 1200);
const Duration _translationAlignmentWindow = Duration(milliseconds: 1000);
const double _translationAlignmentRatio = .7;

List<LyricLine> parseLyrics(GatewayLyrics payload) {
  final ttml = parseTtml(payload.ttml);
  final words = parseYrc(payload.yrc);
  final original = ttml.isNotEmpty
      ? ttml
      : words.isNotEmpty
      ? words
      : parseLyricFile(payload.lrc);
  final translated = _attachSecondary(original, [
    payload.tlyric,
    payload.ytlrc,
  ]);
  return _attachSecondary(translated, [
    payload.rlyric,
    payload.yromalrc,
  ], romanization: true);
}

/// TTML carries explicit translation/romanization roles; plain LRC is never
/// guessed to be romanized text merely because it shares a timestamp.
List<LyricLine> parseLyricFile(String? source) =>
    source?.trimLeft().startsWith('<') == true
    ? parseTtml(source)
    : parseLrc(source);

List<LyricLine> _attachSecondary(
  List<LyricLine> original,
  List<String?> sources, {
  bool romanization = false,
}) {
  // Some platform responses put the translated lines that have no word
  // timing in `tlyric`, while the remaining lines only exist in `ytlrc`.
  // Treating tlyric as an exclusive fallback drops those lines (notably in
  // long soundtrack lyrics). Parse both formats and merge duplicate rows.
  final allTranslations = _mergeTranslations(<LyricLine>[
    for (final source in sources) ...[...parseLrc(source), ...parseYrc(source)],
  ]);
  final translations = allTranslations
      .where((line) => line.text.trim().isNotEmpty)
      .toList(growable: false);
  if (translations.isEmpty) return original;
  final sourceIndexes = <int>[
    for (var i = 0; i < original.length; i++)
      if (original[i].text.trim().isNotEmpty) i,
  ];
  if (sourceIndexes.isEmpty) return original;

  // A translation track that mirrors the original line for line is the most
  // reliable mapping. Match the full track first: blank rows are meaningful
  // placeholders for untranslated lines. If the counts only line up after
  // dropping blank rows, use that list instead. The timestamp check keeps a
  // shifted or unrelated track from being force-paired.
  final List<String?>? paired =
      _pairByLine(original, sourceIndexes, allTranslations) ??
      _pairByLine(original, sourceIndexes, translations);
  final matched = <int, String>{};
  if (paired != null) {
    for (var i = 0; i < sourceIndexes.length; i++) {
      final String? text = paired[i];
      if (text != null) matched[sourceIndexes[i]] = text;
    }
  } else {
    matched.addAll(_matchTranslations(original, sourceIndexes, translations));
  }
  return <LyricLine>[
    for (var i = 0; i < original.length; i++)
      _withTranslation(original[i], matched[i], romanization: romanization),
  ];
}

/// Matches a sparse translation track one-to-one with the nearest source
/// lines.  A translation row must not be reused for two neighbouring source
/// lines: doing so makes a missing translation appear on the preceding line
/// whenever the next translated row is within the tolerance window.
Map<int, String> _matchTranslations(
  List<LyricLine> original,
  List<int> sourceIndexes,
  List<LyricLine> translations,
) {
  final pairs = <({int source, int translation, int distance})>[];
  for (final source in sourceIndexes) {
    final sourceTime = original[source].time.inMilliseconds;
    for (
      var translation = 0;
      translation < translations.length;
      translation++
    ) {
      final distance =
          (translations[translation].time.inMilliseconds - sourceTime).abs();
      if (distance <= _translationWindow.inMilliseconds) {
        pairs.add((
          source: source,
          translation: translation,
          distance: distance,
        ));
      }
    }
  }
  pairs.sort((left, right) {
    final byDistance = left.distance.compareTo(right.distance);
    if (byDistance != 0) return byDistance;
    final bySource = left.source.compareTo(right.source);
    if (bySource != 0) return bySource;
    return left.translation.compareTo(right.translation);
  });

  final usedSources = <int>{};
  final usedTranslations = <int>{};
  final result = <int, String>{};
  for (final pair in pairs) {
    if (!usedSources.add(pair.source) ||
        !usedTranslations.add(pair.translation)) {
      continue;
    }
    final text = translations[pair.translation].text.trim();
    if (text.isNotEmpty) result[pair.source] = text;
  }
  return result;
}

List<LyricLine> _mergeTranslations(List<LyricLine> values) {
  final seen = <String>{};
  final result = <LyricLine>[];
  for (final line in values) {
    final key = '${line.time.inMicroseconds}\u0000${line.text.trim()}';
    if (seen.add(key)) result.add(line);
  }
  result.sort((left, right) => left.time.compareTo(right.time));
  return result;
}

List<String?>? _pairByLine(
  List<LyricLine> original,
  List<int> sourceIndexes,
  List<LyricLine> translations,
) {
  if (sourceIndexes.length != translations.length) return null;
  var aligned = 0;
  for (var i = 0; i < sourceIndexes.length; i++) {
    final int delta = (original[sourceIndexes[i]].time - translations[i].time)
        .inMilliseconds
        .abs();
    if (delta <= _translationAlignmentWindow.inMilliseconds) aligned++;
  }
  if (aligned / sourceIndexes.length < _translationAlignmentRatio) return null;
  return <String?>[for (final LyricLine line in translations) line.text.trim()];
}

LyricLine _withTranslation(
  LyricLine line,
  String? translation, {
  bool romanization = false,
}) {
  final String text = translation?.trim() ?? '';
  return LyricLine(
    line.time,
    line.text,
    words: line.words,
    end: line.end,
    translation: romanization
        ? line.translation
        : (text.isEmpty || text == line.text.trim() ? line.translation : text),
    romanization: romanization && text.isNotEmpty && text != line.text.trim()
        ? text
        : line.romanization,
  );
}
