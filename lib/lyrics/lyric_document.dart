import '../gateway/gateway.dart';

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
    this.words = const [],
    this.end,
  });
  final Duration time;
  final String text;
  final String? translation;
  final List<LyricWord> words;
  final Duration? end;
}

/// Port of LrcRow.kt and LyricTimeline.kt: both fractional separators and
/// multiple timestamps are supported; untimed JSON credits are ignored.
List<LyricLine> parseLrc(String? source) {
  if (source == null || source.trim().isEmpty) return const [];
  final stamp = RegExp(r'\[(\d{1,2}):(\d{2})(?:[.:](\d{1,3}))?\]');
  final lines = <LyricLine>[];
  for (final row in source.split(RegExp(r'[\r\n]+'))) {
    final matches = stamp.allMatches(row).toList();
    if (matches.isEmpty) continue;
    final text = row.substring(matches.last.end).trim();
    for (final match in matches) {
      final fraction = (match.group(3) ?? '').padRight(3, '0');
      lines.add(
        LyricLine(
          Duration(
            minutes: int.parse(match.group(1)!),
            seconds: int.parse(match.group(2)!),
            milliseconds: int.parse(fraction),
          ),
          text,
        ),
      );
    }
  }
  lines.sort((a, b) => a.time.compareTo(b.time));
  return lines;
}

/// Port of WordLyrics.kt; word offsets are absolute song positions.
List<LyricLine> parseYrc(String? source) {
  if (source == null || source.trim().isEmpty) return const [];
  final linePattern = RegExp(r'^\[(\d+),(\d+)\](.*)$');
  final wordPattern = RegExp(
    r'\((\d+),(\d+),(\d+)\)(.*?)(?=\(\d+,\d+,\d+\)|$)',
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
            Duration(milliseconds: int.parse(word.group(2)!).clamp(1, 1 << 62)),
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
  final words = parseYrc(payload.yrc);
  final original = words.isNotEmpty ? words : parseLrc(payload.lrc);
  final regularTranslations = parseLrc(payload.tlyric);
  final allTranslations = regularTranslations.isNotEmpty
      ? regularTranslations
      : parseLrc(payload.ytlrc);
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
    for (final int index in sourceIndexes) {
      final String? text = _nearestTranslation(original[index], translations);
      if (text != null) matched[index] = text;
    }
  }
  return <LyricLine>[
    for (var i = 0; i < original.length; i++)
      _withTranslation(original[i], matched[i]),
  ];
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

String? _nearestTranslation(LyricLine line, List<LyricLine> translations) {
  final int target = line.time.inMilliseconds;
  int low = 0;
  int high = translations.length;
  while (low < high) {
    final int middle = (low + high) ~/ 2;
    if (translations[middle].time.inMilliseconds < target) {
      low = middle + 1;
    } else {
      high = middle;
    }
  }
  // Equal-time credits must not block all later translations by making a
  // forward-only nearest search stop at a tie.
  int cursor = (low - 1).clamp(0, translations.length - 1);
  int delta(int index) =>
      (translations[index].time.inMilliseconds - target).abs();
  if (low < translations.length && delta(low) < delta(cursor)) cursor = low;
  return delta(cursor) <= _translationWindow.inMilliseconds
      ? translations[cursor].text.trim()
      : null;
}

LyricLine _withTranslation(LyricLine line, String? translation) {
  final String text = translation?.trim() ?? '';
  return LyricLine(
    line.time,
    line.text,
    words: line.words,
    end: line.end,
    translation: text.isEmpty || text == line.text.trim() ? null : text,
  );
}
