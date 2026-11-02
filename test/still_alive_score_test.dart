import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/easter_egg/still_alive_score.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final source =
      jsonDecode(
            File(
              'test/fixtures/still_alive_source_score.json',
            ).readAsStringSync(),
          )
          as Map<String, dynamic>;
  final events = (source['events'] as List).cast<List<dynamic>>();
  final artwork = (source['artwork'] as List)
      .map((rows) => (rows as List).join('\n'))
      .toList();
  final credits = source['credits'] as String;
  final score = StillAliveScore.original;

  test(
    'the corrected centisecond table, ten artworks and complete personnel text are preserved',
    () {
      expect(score.events, hasLength(121));
      for (var i = 0; i < events.length; i++) {
        final event = score.events[i];
        expect(
          [event.words, event.centiseconds, event.interval, event.mode],
          events[i],
          reason: 'source event $i',
        );
      }
      expect(score.artwork, artwork);
      expect(score.artwork, hasLength(10));
      expect(score.credits, credits);
      expect(credits.length, 2825);
      expect(credits.split('\n'), hasLength(198));
      expect(credits, contains('Gautam Babbar\nTed Backman\nKelly Bailey'));
      expect(credits, contains('Ellen McLain'));
      expect(credits, endsWith('ENRICHMENT CENTER ACTIVITY!!'));
      expect(score.musicStart, const Duration(milliseconds: 7100));
      expect(score.creditsStart, const Duration(milliseconds: 9300));
      expect(score.duration, const Duration(seconds: 185));
      expect(score.maxTextColumns, 34);
      expect(score.maxTextRows, 22);
      expect(score.maxArtColumns, 40);
      expect(score.maxArtRows, 20);
      expect(score.maxCreditsColumns, 33);
    },
  );

  test(
    'introduction precedes music and the first lyric without duration fitting',
    () {
      expect(score.frameAt(Duration.zero).text, 'F');
      expect(
        score.frameAt(const Duration(microseconds: 1999999)).text,
        'Forms FORM-29827281-12:',
      );
      expect(
        score.frameAt(const Duration(seconds: 2)).text,
        'Forms FORM-29827281-12:\nT',
      );
      const header = 'Forms FORM-29827281-12:\nTest Assessment Report\n';
      expect(score.frameAt(const Duration(seconds: 4)).text, header);
      expect(score.frameAt(const Duration(microseconds: 7099999)).text, header);
      expect(score.frameAt(score.musicStart).text, '$header\n');
      expect(
        score.frameAt(const Duration(microseconds: 7299999)).text,
        '$header\n',
      );
      expect(
        score.frameAt(const Duration(milliseconds: 7300)).text,
        '$header\nT',
      );
      expect(
        score.frameAt(const Duration(milliseconds: 9300)).text,
        '$header\nThis was a triumph.\n',
      );
      expect(score.frameAt(score.creditsStart).creditsText, '>L');
      expect(
        score.creditsAt(score.creditsStart - const Duration(microseconds: 1)),
        '',
      );
    },
  );

  test(
    'newline waits for completed typing, append joins fragments and NUL never paints',
    () {
      final mid = score.frameAt(const Duration(milliseconds: 63800));
      expect(mid.text, isNot(contains('\u0000')));
      final append = score.frameAt(const Duration(milliseconds: 64700));
      expect(append.text, endsWith("I'm being so s"));
      final full = score.frameAt(const Duration(milliseconds: 66600));
      expect(full.text, endsWith("I'm being so sincere right now.\n"));
      expect(
        score.frameAt(const Duration(milliseconds: 134970)).text,
        endsWith('THAT WAS A JOKE. FAT CHANCE.\n'),
      );
    },
  );

  test(
    'blocking lyric operations delay artwork and clears without accumulating invented gaps',
    () {
      expect(score.frameAt(const Duration(milliseconds: 23500)).asciiArt, '');
      expect(
        score.frameAt(const Duration(microseconds: 25299999)).asciiArt,
        '',
      );
      final firstArtFrame = score
          .frameAt(const Duration(milliseconds: 25300))
          .asciiArt
          .split('\n');
      expect(firstArtFrame.first, artwork[0].split('\n').first);
      expect(firstArtFrame.skip(1).every((row) => row.trim().isEmpty), isTrue);
      expect(
        score.frameAt(const Duration(milliseconds: 25500)).asciiArt,
        artwork[0],
      );
      expect(
        score.frameAt(const Duration(milliseconds: 27330)).text,
        endsWith('W'),
      );
      expect(
        score.frameAt(const Duration(milliseconds: 156970)).text,
        isNotEmpty,
        reason: 'still alive started at 155.53 s and blocks for 2 s',
      );
      expect(
        score.frameAt(const Duration(microseconds: 157529999)).text,
        isNotEmpty,
      );
      expect(score.frameAt(const Duration(milliseconds: 157530)).text, '');
      expect(
        score.frameAt(const Duration(milliseconds: 157570)).text,
        '\n\n\nP',
      );
      expect(
        score.frameAt(const Duration(milliseconds: 176630)).text,
        endsWith('still alive.\n\n\n'),
      );
    },
  );

  test(
    'independent credits type and scrollable prefixes finish by the real audio end',
    () {
      expect(
        score.creditsAt(const Duration(seconds: 50)),
        startsWith('>LIST PERSONNEL'),
      );
      expect(
        score.creditsAt(const Duration(seconds: 50)).length,
        greaterThan(600),
      );
      expect(
        score.creditsAt(score.creditsStart + StillAliveScore.creditsDuration),
        credits,
      );
      const audioEnd = Duration(microseconds: 7100000 + 176404875);
      final end = score.frameAt(audioEnd);
      expect(end.creditsText, credits);
      expect(end.text, '');
      expect(
        end.finished,
        isFalse,
        reason: 'the original END command remains at 185 s',
      );
      expect(score.frameAt(const Duration(seconds: 185)).finished, isTrue);
      expect(score.frameAt(const Duration(seconds: 185)).text, '');
      expect(
        score.frameAt(const Duration(seconds: 185)).text,
        isNot(contains('ENDEND')),
      );
    },
  );

  test(
    'all event boundaries and random reverse seeks match a serial source interpreter',
    () {
      final samples = <int>[0, -1, 185000000, 200000000];
      var previousEnd = 0;
      for (var i = 0; i < events.length; i++) {
        final event = events[i];
        final start = math.max((event[1] as int) * 10000, previousEnd);
        final blocking = _blocking(events, i);
        samples.addAll([
          start - 1,
          start,
          start + 1,
          start + blocking ~/ 2,
          start + blocking - 1,
          start + blocking,
        ]);
        previousEnd = start + blocking;
      }
      final random = math.Random(54);
      samples.addAll([
        for (var i = 0; i < 1800; i++) random.nextInt(190000000),
      ]);
      samples.shuffle(random);
      for (final position in samples) {
        final expected = _reference(events, artwork, position);
        final frame = score.frameAt(Duration(microseconds: position));
        expect(frame.text, expected.$1, reason: '$position us text');
        expect(frame.asciiArt, expected.$2, reason: '$position us art');
        expect(frame.pageIndex, expected.$3, reason: '$position us page');
        expect(frame.text, isNot(contains('\u0000')));
        expect(
          score.frameAt(Duration(microseconds: position)).creditsText,
          frame.creditsText,
          reason: 'paused playhead is deterministic',
        );
      }
      expect(score.frameAt(const Duration(seconds: 185)).finished, isTrue);
      final replay = score.frameAt(Duration.zero);
      expect(replay.text, 'F');
      expect(replay.creditsText, '');
      expect(replay.finished, isFalse);
    },
  );

  test(
    'bundled reference source, GPL and supplied MP3 are present and byte exact',
    () async {
      final mp3 = await rootBundle.load(StillAliveScore.audioAsset);
      expect(mp3.lengthInBytes, 4233749);
      expect(
        sha256.convert(mp3.buffer.asUint8List()).toString(),
        'c0298d1f5e9430c6dabbff30295e21930ea7799fbeb427f67b2cbcc06f31af8b',
      );
      final script = await rootBundle.loadString(
        'assets/easter_eggs/still_alive/source.py',
      );
      expect(script, contains('PORTAL--STILL ALIVE demo by LHF (BD4SUP)'));
      expect(script, contains('September 2021'));
      expect(script, contains('either version 3 of the License'));
      final readme = await rootBundle.loadString(
        'assets/easter_eggs/still_alive/SOURCE_README.md',
      );
      expect(readme, contains('still_alive_credit.py'));
      final license = await rootBundle.loadString(
        'assets/easter_eggs/still_alive/GPL-3.0.txt',
      );
      expect(
        license,
        startsWith('GNU GENERAL PUBLIC LICENSE'),
      );
      expect(license.length, greaterThan(30000));
    },
  );
}

int _blocking(List<List<dynamic>> events, int index) {
  final row = events[index];
  final mode = row[3] as int;
  if (mode == 2) return 200000;
  if (mode > 1 || (row[0] as String).isEmpty) return 0;
  final interval = (row[2] as num).toDouble();
  return interval >= 0
      ? (interval * 1000000).round()
      : index + 1 < events.length
      ? ((events[index + 1][1] as int) - (row[1] as int)) * 10000
      : 0;
}

(String, String, int) _reference(
  List<List<dynamic>> events,
  List<String> artwork,
  int position,
) {
  final now = math.max(0, position);
  var text = '';
  var art = '';
  var page = 0;
  var previousEnd = 0;
  for (var i = 0; i < events.length; i++) {
    final event = events[i];
    final start = math.max((event[1] as int) * 10000, previousEnd);
    if (now < start) break;
    final blocking = _blocking(events, i);
    final elapsed = now - start;
    final mode = event[3] as int;
    if (mode <= 1) {
      final words = event[0] as String;
      // Source drawLyrics prints before sleep; simulate each character's
      // timestamp directly rather than using the score's binary-search path.
      for (var character = 0; character < words.length; character++) {
        if (character * blocking > elapsed * words.length) break;
        if (words[character] != '\u0000') text += words[character];
      }
      if (elapsed >= blocking && mode == 0) text += '\n';
    } else if (mode == 2) {
      final next = artwork[event[0] as int].split('\n');
      final rows = art.isEmpty ? List.filled(20, ' ' * 40) : art.split('\n');
      for (var row = 0; row < next.length; row++) {
        if (row * 10000 <= elapsed) rows[row] = next[row];
      }
      art = rows.join('\n');
    } else if (mode == 3) {
      text = '';
      page++;
    }
    previousEnd = start + blocking;
    if (now < previousEnd || mode == 9) break;
  }
  return (text, art, page);
}
