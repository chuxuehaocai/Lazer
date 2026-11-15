import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/gateway/gateway.dart';
import 'package:lazer_nextgen/lyrics/lyric_document.dart';
import 'package:lazer_nextgen/lyrics/cached_lyrics_store.dart';
import 'package:lazer_nextgen/lyrics/imported_lyrics_store.dart';
import 'package:lazer_nextgen/lyrics/selection.dart';
import 'package:lazer_nextgen/lyrics/viewport.dart';
import 'package:lazer_nextgen/lyrics/line_content.dart';
import 'package:lazer_nextgen/lyrics/image_export.dart';
import 'package:lazer_nextgen/desktop_lyrics/overlay_protocol.dart';
import 'package:lazer_nextgen/plugins/lua_plugin_runtime.dart';
import 'package:lazer_nextgen/plugins/plugin_manifest.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/theme/apple_design.dart';

const _track = Track(
  id: 'fixture:fixture:song:1',
  title: 'Song',
  artist: 'Artist',
  album: 'Album',
  duration: Duration(minutes: 2),
  coverSeed: 1,
);
const _ttml = """
<tt xmlns="http://www.w3.org/ns/ttml" xmlns:ttm="http://www.w3.org/ns/ttml#metadata" xmlns:itunes="http://music.apple.com/lyric-ttml-internal">
<head><metadata><iTunesMetadata><translations><translation><text for="L2">第二句</text></translation></translations><transliterations><transliteration><text for="L2">tsugi</text></transliteration></transliterations></iTunesMetadata></metadata></head>
<body><div>
<p begin="1s" end="3s" itunes:key="L1">
<span begin="1s" end="2s">君</span><span begin="2s" end="3s">へ</span>
<span ttm:role="x-roman">kimi e</span><span ttm:role="x-translation">给你</span>
</p>
<p begin="00:05.000" end="00:07.000" itunes:key="L2">次</p>
</div></body></tt>
""";

class _State extends AppState {
  @override
  Track? get current => _track;
  @override
  Duration get precisePosition => const Duration(seconds: 1);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'romanization matches separately without consuming translations or filling absent lines',
    () {
      final lines = parseLyrics(
        const GatewayLyrics(
          lrc: '[00:01]君へ\n[00:05]次\n[00:10]終わり',
          tlyric: '[00:01]给你\n[00:05]下一句',
          rlyric: '[00:01]kimi e',
          yromalrc: '[5000,1000](5000,1000,0)tsugi',
        ),
      );
      expect(lines.map((line) => line.romanization), ['kimi e', 'tsugi', null]);
      expect(lines.map((line) => line.translation), ['给你', '下一句', null]);
      final selected = const LyricSelection().begin(lines, 0);
      expect(selected.text(lines), '君へ\nkimi e\n给你');
      expect(selected.text(lines, showRomanization: false), '君へ\n给你');
    },
  );

  test('AMLL TTML inline and sidecar romanization do not enter sung words', () {
    final lines = parseLyricFile(_ttml);
    expect(lines, hasLength(2));
    expect(lines.first.text, '君へ');
    expect(lines.first.romanization, 'kimi e');
    expect(lines.first.translation, '给你');
    expect(lines.first.words.map((word) => word.text), ['君', 'へ']);
    expect(lines.first.words.last.start, const Duration(seconds: 2));
    expect(lines.last.text, '次');
    expect(lines.last.romanization, 'tsugi');
    expect(lines.last.translation, '第二句');
    expect(parseLyricFile('<broken'), isEmpty);
  });

  test('TTML imports and offline cache retain romanization', () async {
    final root = await Directory.systemTemp.createTemp('romanized-lyrics-');
    addTearDown(() => root.delete(recursive: true));
    final imported = ImportedLyricsStore(supportDirectory: () async => root);
    expect(await imported.save(_track, _ttml), isTrue);
    expect(
      parseLyricFile(await imported.read(_track)).first.romanization,
      'kimi e',
    );
    final audio = await File('${root.path}/song.flac').writeAsBytes([0]);
    await File('${root.path}/song.ttml').writeAsString(_ttml);
    expect(
      parseLyricFile(
        await ImportedLyricsStore.sidecarFor(audio.path),
      ).last.romanization,
      'tsugi',
    );
    final cache = CachedLyricsStore(supportDirectory: () async => root);
    await cache.save(
      _track,
      const GatewayLyrics(
        ttml: _ttml,
        rlyric: '[00:01]kimi e',
        yromalrc: '[00:05]tsugi',
      ),
    );
    final restored = await CachedLyricsStore(
      supportDirectory: () async => root,
    ).read(_track);
    expect(restored!.rlyric, '[00:01]kimi e');
    expect(restored.yromalrc, '[00:05]tsugi');
    expect(parseLyrics(restored).first.romanization, 'kimi e');
  });

  test(
    'Lua lyric contracts accept standard and NetEase romanization fields',
    () async {
      final runtime = LuaPluginRuntime(
        manifest: PluginManifest.fromJson(const {
          'id': 'fixture.lyrics',
          'name': 'Lyrics',
          'version': '1.0.0',
          'provider': 'fixture',
          'apiVersion': 1,
        }),
        sources: const {
          'main.lua': """
return {call=function(op,args) return {
 {synced=true,lrc="[00:01]君へ",rlyric="[00:01]kimi e",yromalrc="[00:01]kimi e",lines={{text="君へ",startMs=1000,romanLyric="kimi e",translatedLyric="给你"}}},
 {lines={},romanization="[00:01]kimi e",wordRomanization="[00:01]kimi e"}
} end}
""",
        },
        dataDirectory: '',
      );
      addTearDown(runtime.close);
      final gateway = LuaMusicGateway(
        runtime: runtime,
        provider: const MusicProvider(id: 'fixture', name: 'Fixture'),
        connectionId: 'fixture',
      );
      final values = await gateway.lyrics(
        gateway.id(MusicEntityKind.song, '1'),
      );
      for (final value in values) {
        expect(value.romanization, '[00:01]kimi e');
        expect(value.wordRomanization, '[00:01]kimi e');
      }
      expect(values.first.lines.single.romanization, 'kimi e');
      expect(values.first.lines.single.translation, '给你');
    },
  );

  testWidgets(
    'romanization toggles immediately and preserves translation and row geometry',
    (tester) async {
      final state = _State()..lyrics = parseLyricFile(_ttml);
      addTearDown(state.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppleTheme(),
          home: Scaffold(body: LyricViewport(state: state)),
        ),
      );
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('kimi e'), findsOneWidget);
      expect(find.text('给你'), findsOneWidget);
      final originalRect = tester.getRect(find.byType(LyricLineContent).first);
      final romanRect = tester.getRect(find.text('kimi e'));
      final translationRect = tester.getRect(find.text('给你'));
      expect(romanRect.top, greaterThanOrEqualTo(originalRect.bottom));
      expect(translationRect.top, greaterThanOrEqualTo(romanRect.bottom));
      await state.setShowLyricRomanization(false);
      await tester.pump();
      expect(find.text('kimi e'), findsNothing);
      expect(find.text('给你'), findsOneWidget);
      expect(
        (await SharedPreferences.getInstance()).getBool(
          AppState.lyricRomanizationKey,
        ),
        isFalse,
      );
      await state.setShowLyricRomanization(true);
      await tester.pump();
      expect(find.text('kimi e'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'export respects romanization switch and overlay protocol preserves it',
    (tester) async {
      final lines = parseLyricFile(_ttml);
      final settings = LyricsOverlaySettings.fromMap({
        'showRomanization': false,
      });
      final payload = LyricsOverlayPayload(
        title: '',
        artist: '',
        notice: null,
        lines: lines,
        settings: settings,
        position: Duration.zero,
        duration: const Duration(minutes: 2),
        playing: false,
      );
      final restored = LyricsOverlayPayload.fromMap(payload.toMap());
      expect(restored.lines.first.romanization, 'kimi e');
      expect(restored.settings.showRomanization, isFalse);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppleTheme(),
          home: SingleChildScrollView(
            child: LyricImageCard(
              track: _track,
              lines: lines,
              showRomanization: false,
            ),
          ),
        ),
      );
      expect(find.text('kimi e'), findsNothing);
      expect(find.text('给你'), findsOneWidget);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppleTheme(),
          home: SingleChildScrollView(
            child: LyricImageCard(track: _track, lines: lines),
          ),
        ),
      );
      expect(find.text('kimi e'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
