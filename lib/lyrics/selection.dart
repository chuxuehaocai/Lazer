import 'lyric_document.dart';

/// Stable identities keep selections attached to their lines during updates.
String? lyricSelectionKey(LyricLine line) => line.text.trim().isEmpty
    ? null
    : '${line.time.inMilliseconds}|${line.text.trim()}';

class LyricSelection {
  const LyricSelection({this.anchor, this.keys = const {}});
  final String? anchor;
  final Set<String> keys;
  bool get active => anchor != null;

  LyricSelection begin(List<LyricLine> lines, int index) {
    final key = lyricSelectionKey(lines[index]);
    return key == null ? this : LyricSelection(anchor: key, keys: {key});
  }

  LyricSelection toggle(List<LyricLine> lines, int index) {
    final key = lyricSelectionKey(lines[index]);
    if (key == null) return this;
    if (!active) return begin(lines, index);
    final next = {...keys};
    if (!next.add(key)) next.remove(key);
    if (next.isEmpty) return const LyricSelection();
    var nextAnchor = anchor;
    if (anchor == key) {
      final surviving = [
        for (var i = 0; i < lines.length; i++)
          if (next.contains(lyricSelectionKey(lines[i]))) i,
      ];
      surviving.sort((a, b) => (a - index).abs().compareTo((b - index).abs()));
      nextAnchor = lyricSelectionKey(lines[surviving.first]);
    }
    return LyricSelection(anchor: nextAnchor, keys: next);
  }

  LyricSelection extend(List<LyricLine> lines, int index) {
    if (!active) return begin(lines, index);
    final from = lines.indexWhere((line) => lyricSelectionKey(line) == anchor);
    if (from < 0) return begin(lines, index);
    final start = from < index ? from : index;
    final end = from > index ? from : index;
    return LyricSelection(
      anchor: anchor,
      keys: {for (var i = start; i <= end; i++) ?lyricSelectionKey(lines[i])},
    );
  }

  LyricSelection all(List<LyricLine> lines) {
    final available = {for (final line in lines) ?lyricSelectionKey(line)};
    return available.isEmpty
        ? this
        : LyricSelection(anchor: anchor ?? available.first, keys: available);
  }

  String text(List<LyricLine> lines, {bool showRomanization = true}) => [
    for (final line in lines)
      if (keys.contains(lyricSelectionKey(line))) ...[
        line.text.trim(),
        if (showRomanization && (line.romanization?.trim().isNotEmpty ?? false))
          line.romanization!.trim(),
        if (line.translation?.trim().isNotEmpty ?? false)
          line.translation!.trim(),
      ],
  ].join('\n');
}
