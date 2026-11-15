import 'package:xml/xml.dart';

import 'lyric_document.dart';

/// AMLL TTML: x-roman/x-translation spans and Apple metadata sidecars are
/// independent sub-lines. Never include them in the sung text or word timings.
List<LyricLine> parseTtml(String? source) {
  if (source == null || source.trim().isEmpty) return const [];
  try {
    final document = XmlDocument.parse(source);
    final translations = <String, String>{};
    final romanizations = <String, String>{};
    for (final element in document.descendants.whereType<XmlElement>()) {
      if (element.name.local != 'text') continue;
      final key = element.getAttribute('for');
      if (key == null) continue;
      final parents = element.ancestors.whereType<XmlElement>();
      if (parents.any((node) => node.name.local == 'transliteration')) {
        romanizations.putIfAbsent(key, () => element.innerText.trim());
      } else if (parents.any((node) => node.name.local == 'translation')) {
        translations.putIfAbsent(key, () => element.innerText.trim());
      }
    }
    final lines = <LyricLine>[];
    for (final row in document.descendants.whereType<XmlElement>().where(
      (e) => e.name.local == 'p',
    )) {
      final time = _time(row.getAttribute('begin'));
      if (time == null) continue;
      final end = _time(row.getAttribute('end'));
      final words = <LyricWord>[];
      final original = StringBuffer();
      final translated = <String>[];
      final romanized = <String>[];
      void visit(XmlNode node) {
        if (node is XmlText) {
          if (node.value.trim().isEmpty &&
              (node.value.contains('\n') || node.value.contains('\r'))) {
            return;
          }
          original.write(node.value);
          return;
        }
        if (node is! XmlElement) return;
        final role = _attribute(node, 'role');
        if (role == 'x-roman' || role == 'x-translation') {
          final text = node.innerText.trim();
          if (text.isNotEmpty) {
            (role == 'x-roman' ? romanized : translated).add(text);
          }
          return;
        }
        if (node.name.local == 'br') {
          original.write(' ');
          return;
        }
        final start = _time(node.getAttribute('begin'));
        final stop = _time(node.getAttribute('end'));
        if (start != null &&
            stop != null &&
            stop > start &&
            !node.childElements.any(
              (child) => child.getAttribute('begin') != null,
            )) {
          final text = StringBuffer();
          for (final child in node.children) {
            if (child is XmlElement &&
                (_attribute(child, 'role') == 'x-roman' ||
                    _attribute(child, 'role') == 'x-translation')) {
              visit(child);
            } else {
              text.write(child is XmlText ? child.value : child.innerText);
            }
          }
          if (text.isNotEmpty) {
            words.add(LyricWord(start, stop - start, text.toString()));
            original.write(text);
          }
          return;
        }
        for (final child in node.children) {
          visit(child);
        }
      }

      for (final child in row.children) {
        visit(child);
      }
      final key = _attribute(row, 'key');
      String? secondary(List<String> spans, String? sidecar) {
        final text = spans.isEmpty ? sidecar?.trim() : spans.join(' ').trim();
        return text == null || text.isEmpty ? null : text;
      }

      final text = original.toString().trim();
      if (text.isEmpty) continue;
      lines.add(
        LyricLine(
          time,
          text,
          end: end,
          words: words.map((word) => word.text).join().trim() == text
              ? words
              : const [],
          translation: secondary(translated, translations[key]),
          romanization: secondary(romanized, romanizations[key]),
        ),
      );
    }
    lines.sort((a, b) => a.time.compareTo(b.time));
    return lines;
  } on XmlException {
    return const [];
  }
}

String? _attribute(XmlElement element, String local) => element.attributes
    .where((attribute) => attribute.name.local == local)
    .firstOrNull
    ?.value;

Duration? _time(String? value) {
  if (value == null) return null;
  final text = value.trim();
  final metric = RegExp(r'^(\d+(?:\.\d+)?)(ms|s|m|h)$').firstMatch(text);
  double? seconds;
  if (metric != null) {
    final multiplier = switch (metric.group(2)) {
      'ms' => .001,
      'm' => 60.0,
      'h' => 3600.0,
      _ => 1.0,
    };
    seconds = double.parse(metric.group(1)!) * multiplier;
  } else {
    final parts = text.split(':');
    if (parts.length <= 3 &&
        parts.every((part) => double.tryParse(part) != null)) {
      seconds = parts.fold(
        0.0,
        (total, part) => total! * 60 + double.parse(part),
      );
    }
  }
  return seconds == null || !seconds.isFinite || seconds < 0
      ? null
      : Duration(microseconds: (seconds * 1000000).round());
}
