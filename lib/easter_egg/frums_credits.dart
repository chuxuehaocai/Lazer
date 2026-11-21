import 'dart:math' as math;

import 'package:flutter/services.dart';

const _frumsAssetPrefix = 'assets/easter_eggs/frums_credits';
const _frumsScoreFiles = <String>[
  'credits.part',
  'face.part',
  'lycles_mask.part',
  'lycles.part',
  'op.part',
  'semicircle.part',
];
const _frumsDataFiles = <String>[
  'authors_credits',
  'face',
  'face_alt',
  'circle/bg',
  'circle/bg_small',
  'circle/bg_small2',
  'circle/kick',
  'circle/ride',
  'circle/shot',
  'op/info1',
  'op/info2',
  'op/info3',
  'op/info4',
  'op/zeros',
  'sabi/box',
  'sabi/human_stand',
  'sabi/human_walk',
  'sabi/kick',
  'sabi/ride',
  'sabi/shot',
  'sabi2/box',
  'sabi2/box_flipped',
  'sabi2/human',
  'sabi2/human_flipped',
  'sabi2/kick',
  'sabi2/none',
  'sabi2/ride',
  'sabi2/shot',
  'semicircle/1',
  'semicircle/2',
  'semicircle/3',
];

/// A parsed frame from the CSF score shipped by the Frums credits project.
class FrumsCreditsScore {
  FrumsCreditsScore._(this._parts, this.width, this.height, this.totalBars);

  static const double _beatsPerBar = 4;
  static const double _bpm = 179;

  final List<_FrumsPart> _parts;
  final int width;
  final int height;
  final int totalBars;

  Duration get duration =>
      Duration(microseconds: (totalBars * _barDuration.inMicroseconds).round());

  static Duration get _barDuration =>
      Duration(microseconds: (60 * 1000000 * _beatsPerBar / _bpm).round());

  static Future<FrumsCreditsScore> load({AssetBundle? bundle}) async {
    final assets = bundle ?? rootBundle;
    final dataEntries = await Future.wait(
      _frumsDataFiles.map(
        (path) async => MapEntry(
          path,
          (await assets.loadString(
            '$_frumsAssetPrefix/data/$path.txt',
          )).replaceAll('\r\n', '\n'),
        ),
      ),
    );
    final contents = <String, String>{
      for (final entry in dataEntries) entry.key: entry.value,
    };
    final partEntries = await Future.wait(
      _frumsScoreFiles.map(
        (path) async => MapEntry(
          path,
          (await assets.loadString(
            '$_frumsAssetPrefix/scores/$path.txt',
          )).replaceAll('\r\n', '\n'),
        ),
      ),
    );
    final parts = [
      for (final entry in partEntries) _parsePart(entry.value, contents),
    ]..sort((a, b) => a.zIndex.compareTo(b.zIndex));

    var width = 1;
    var height = 1;
    var totalBars = 1;
    for (final part in parts) {
      totalBars = math.max(totalBars, part.bars.length);
      for (final bar in part.bars) {
        for (final item in bar.items) {
          width = math.max(width, item.x + item.width);
          height = math.max(height, item.y + item.height);
        }
      }
    }
    return FrumsCreditsScore._(parts, width, height, totalBars);
  }

  String frameAt(Duration elapsed) {
    if (_parts.isEmpty) return '';
    final scoreDuration = duration;
    final elapsedMicros = scoreDuration.inMicroseconds == 0
        ? 0
        : elapsed.inMicroseconds % scoreDuration.inMicroseconds;
    final playedBars = elapsedMicros / _barDuration.inMicroseconds;
    final barIndex = playedBars.floor();
    final fraction = playedBars - barIndex;
    final canvas = List<int>.filled(width * height, 0x20);

    for (final part in _parts) {
      if (barIndex >= part.bars.length) continue;
      final items = part.bars[barIndex].items;
      if (items.isEmpty) continue;
      final itemIndex = math.min(
        items.length - 1,
        (items.length * fraction).floor(),
      );
      final item = items[itemIndex];
      for (final glyph in item.glyphs) {
        if (glyph.rune == 0x20) continue;
        final x = item.x + glyph.x;
        final y = item.y + glyph.y;
        if (x < 0 || x >= width || y < 0 || y >= height) continue;
        canvas[y * width + x] = glyph.rune;
      }
    }

    final rows = <String>[];
    for (var y = 0; y < height; y++) {
      rows.add(String.fromCharCodes(canvas, y * width, (y + 1) * width));
    }
    return rows.join('\n');
  }
}

class _FrumsPart {
  const _FrumsPart(this.zIndex, this.bars);

  final int zIndex;
  final List<_FrumsBar> bars;
}

class _FrumsBar {
  const _FrumsBar(this.items);

  final List<_FrumsItem> items;
}

class _FrumsItem {
  _FrumsItem({required this.x, required this.y, required String content})
    : glyphs = _parseGlyphs(content),
      width = _contentWidth(content),
      height = content.split('\n').length;

  final int x;
  final int y;
  final List<_FrumsGlyph> glyphs;
  final int width;
  final int height;
}

class _FrumsGlyph {
  const _FrumsGlyph(this.x, this.y, this.rune);

  final int x;
  final int y;
  final int rune;
}

_FrumsPart _parsePart(String source, Map<String, String> contents) {
  var x = 0;
  var y = 0;
  var flipVertical = false;
  var zIndex = 0;
  final bars = <_FrumsBar>[];

  for (final rawBar in source.split('---')) {
    final items = <_FrumsItem>[];
    for (final rawLine in rawBar.split('\n')) {
      final line = rawLine.trimRight();
      if (line.isEmpty) continue;
      if (line.startsWith('#')) {
        final args = line.length > 2
            ? line.substring(2).trim().split(RegExp(r'\s+'))
            : const <String>[];
        if (args.isNotEmpty && args[0] == 'MOVETO' && args.length >= 3) {
          x = int.tryParse(args[1]) ?? x;
          y = int.tryParse(args[2]) ?? y;
        } else if (args.isNotEmpty && args[0] == 'ZINDEX' && args.length >= 2) {
          zIndex = int.tryParse(args[1]) ?? zIndex;
        } else if (args.length >= 3 && args[0] == 'FLIP') {
          flipVertical = args[1] == 'vertical' && args[2] == 'on';
        }
        continue;
      }
      if (line.startsWith('/')) continue;

      final key = line.startsWith('"') && line.endsWith('"')
          ? line.substring(1, line.length - 1)
          : line;
      var content = contents[key] ?? key;
      if (flipVertical) content = _flipVertical(content);
      items.add(_FrumsItem(x: x, y: y, content: content));
    }
    bars.add(_FrumsBar(items));
  }
  return _FrumsPart(zIndex, bars);
}

List<_FrumsGlyph> _parseGlyphs(String content) {
  final glyphs = <_FrumsGlyph>[];
  var x = 0;
  var y = 0;
  for (final rune in content.runes) {
    if (rune == 0x0a) {
      y++;
      x = 0;
    } else {
      glyphs.add(_FrumsGlyph(x, y, rune));
      x++;
    }
  }
  return glyphs;
}

int _contentWidth(String content) {
  var width = 0;
  for (final line in content.split('\n')) {
    width = math.max(width, line.runes.length);
  }
  return width;
}

String _flipVertical(String content) => content
    .split('\n')
    .map((line) => String.fromCharCodes(line.runes.toList().reversed))
    .join('\n');
