import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/data/lyrics.dart';
import 'package:lazer_nextgen/gateway/gateway.dart';
import 'package:lazer_nextgen/gateway/transport.dart';

class _FailedLyricsTransport extends NeteaseTransport {
  @override
  Future<Map<String, dynamic>> request(
    String alias,
    Map<String, String> parameters,
  ) async {
    if (alias == '/lyric/new') return <String, dynamic>{'code': 200};
    throw GatewayHttpException(503, alias);
  }
}

void main() {
  test(
    'failed lyric fallback is reported instead of synthesized empty lyrics',
    () async {
      await expectLater(
        NeteaseGateway(
          transport: _FailedLyricsTransport(),
        ).preferredLyrics(2055244250),
        throwsA(isA<GatewayHttpException>()),
      );
    },
  );
  test('parses LRC timestamps', () {
    final lines = parseLyrics(
      const GatewayLyrics(lrc: '[00:01.25]第一句\n[00:03.000]第二句'),
    );
    expect(lines.map((line) => line.text), <String>['第一句', '第二句']);
    expect(lines.first.time, const Duration(milliseconds: 1250));
  });

  test('uses enhanced word timing when available', () {
    final lines = parseLyrics(
      const GatewayLyrics(
        lrc: '[00:01.00]普通歌词',
        yrc: '[1200,800](1200,400,0)逐(1600,400,0)字',
      ),
    );
    expect(lines.single.text, '逐字');
    expect(lines.single.time, const Duration(milliseconds: 1200));
    expect(lines.single.words.last.start, const Duration(milliseconds: 1600));
  });

  test(
    'accepts colon fractions and repeated timestamps, ignoring JSON credits',
    () {
      final lines = parseLyrics(
        const GatewayLyrics(
          lrc: '{"t":1000,"c":[{"tx":"作曲：署名"}]}\r\n[00:12:95][01:02.5]正文',
        ),
      );
      expect(lines.map((line) => line.text), ['正文', '正文']);
      expect(lines.map((line) => line.time.inMilliseconds), [12950, 62500]);
    },
  );
  test('accepts one-digit second fields like the official parser', () {
    final lines = parseLrc('[0:5]first\n[01:2.5]second\n[00:60.00]invalid');
    expect(lines.map((line) => line.text), <String>['first', 'second']);
    expect(lines.map((line) => line.time.inMilliseconds), <int>[5000, 62500]);
  });
  test('accepts full-width commas in YRC timing', () {
    final lines = parseYrc('[1200，800](1200，400，0)逐(1600，400，0)字');
    expect(lines.single.text, '逐字');
    expect(lines.single.time, const Duration(milliseconds: 1200));
    expect(lines.single.end, const Duration(milliseconds: 2000));
  });
  test('translation follows the nearest source line within one second', () {
    final lines = parseLyrics(
      const GatewayLyrics(
        lrc: '[00:05:00]original\n[00:08.00]next',
        tlyric: '[00:05.40]翻译\n[00:20.00]太远',
      ),
    );
    expect(lines.first.translation, '翻译');
    expect(lines.last.translation, isNull);
  });
  test('a blank translation row does not hide the real line', () {
    final lines = parseLyrics(
      const GatewayLyrics(
        lrc: '[00:05.00]original',
        tlyric: '[00:05.06]\n[00:05.18]翻译',
      ),
    );
    expect(lines.single.translation, '翻译');
  });
  test('line-aligned translations survive one slipped timestamp', () {
    final lines = parseLyrics(
      const GatewayLyrics(
        lrc: '[00:01.00]one\n[00:02.00]two\n[00:03.00]three\n[00:04.00]four',
        tlyric: '[00:01.10]一\n[00:02.10]二\n[00:03.10]三\n[00:06.00]四',
      ),
    );
    expect(lines.map((line) => line.translation), <String?>[
      '一',
      '二',
      '三',
      '四',
    ]);
  });
  test('blank source rows do not consume a line-aligned translation', () {
    final lines = parseLyrics(
      const GatewayLyrics(
        lrc: '[00:01.00]first\n[00:02.00]\n[00:03.00]third',
        tlyric: '[00:01.00]一\n[00:03.00]三',
      ),
    );
    expect(lines.map((line) => line.translation), <String?>['一', null, '三']);
  });
  test('a blank translation row keeps its own line untranslated', () {
    final lines = parseLyrics(
      const GatewayLyrics(
        lrc: '[00:01.00]one\n[00:02.00]instrumental\n[00:03.00]three',
        tlyric: '[00:01.00]一\n[00:02.00]\n[00:03.20]三',
      ),
    );
    expect(lines.map((line) => line.translation), <String?>['一', null, '三']);
  });
  test('equal-time credits do not block later translated lyrics', () {
    final lines = parseLyrics(
      const GatewayLyrics(
        lrc: '[00:04.00]first\n[00:08.00]second',
        tlyric: '[00:00.00]作词\n[00:00.00]作曲\n[00:04.10]第一句\n[00:07.90]第二句',
      ),
    );
    expect(lines.map((line) => line.translation), ['第一句', '第二句']);
  });
}
