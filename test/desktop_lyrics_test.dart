import 'dart:ui' show Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/desktop_lyrics/lyrics_overlay.dart';
import 'package:lazer_nextgen/desktop_lyrics/overlay_protocol.dart';
import 'package:lazer_nextgen/lyrics/lyric_document.dart';

LyricsOverlaySettings settingsWithLines(int lines) =>
    LyricsOverlaySettings.fromMap(<String, Object?>{'lineCount': lines});

void main() {
  test('line count is clamped to the one-to-five range', () {
    expect(settingsWithLines(-4).lineCount, 1);
    expect(settingsWithLines(0).lineCount, 1);
    expect(settingsWithLines(1).lineCount, 1);
    expect(settingsWithLines(3).lineCount, 3);
    expect(settingsWithLines(5).lineCount, 5);
    expect(settingsWithLines(12).lineCount, 5);
  });

  test('default settings show three lines', () {
    final LyricsOverlaySettings settings = LyricsOverlaySettings.fromMap(
      const <String, Object?>{},
    );
    expect(settings.lineCount, 3);
    expect(settings.blurEnabled, isTrue);
    expect(settings.fontSize, 22);
  });

  test('animation speed is clamped to the app range', () {
    expect(
      LyricsOverlaySettings.fromMap(<String, Object?>{
        'animationSpeed': 3,
      }).animationSpeed,
      2,
    );
    expect(
      LyricsOverlaySettings.fromMap(<String, Object?>{
        'animationSpeed': .1,
      }).animationSpeed,
      .5,
    );
    expect(
      LyricsOverlaySettings.fromMap(<String, Object?>{
        'animationSpeed': 1.2,
      }).animationSpeed,
      1.2,
    );
  });

  test('launch payload round-trips mode and settings', () {
    final LyricsOverlayLaunch launch = LyricsOverlayLaunch(
      mode: LyricsOverlayMode.desktop,
      settings: settingsWithLines(5),
    );
    final LyricsOverlayLaunch? parsed = LyricsOverlayLaunch.tryParse(
      launch.encode(),
    );
    expect(parsed, isNotNull);
    expect(parsed!.mode, LyricsOverlayMode.desktop);
    expect(parsed.settings, launch.settings);
  });

  test('a normal multi-window argument is not treated as a lyrics overlay', () {
    expect(LyricsOverlayLaunch.tryParse(''), isNull);
    expect(LyricsOverlayLaunch.tryParse('{"kind":"other"}'), isNull);
    expect(LyricsOverlayLaunch.tryParse('not json'), isNull);
  });

  test('window height grows with the requested line count', () {
    final Size one = lyricsOverlayWindowSize(
      LyricsOverlayLaunch(
        mode: LyricsOverlayMode.desktop,
        settings: settingsWithLines(1),
      ),
    );
    final Size three = lyricsOverlayWindowSize(
      LyricsOverlayLaunch(
        mode: LyricsOverlayMode.desktop,
        settings: settingsWithLines(3),
      ),
    );
    final Size five = lyricsOverlayWindowSize(
      LyricsOverlayLaunch(
        mode: LyricsOverlayMode.desktop,
        settings: settingsWithLines(5),
      ),
    );
    expect(one.width, three.width);
    expect(three.height, greaterThan(one.height));
    expect(five.height, greaterThan(three.height));
  });

  test('slot height stays inside the legible range', () {
    expect(lyricsOverlaySlotHeight(1), 34);
    expect(lyricsOverlaySlotHeight(22), closeTo(41.8, 0.001));
    expect(lyricsOverlaySlotHeight(200), 96);
  });

  test('state payload round-trips lyric lines and position', () {
    final LyricsOverlayPayload payload = LyricsOverlayPayload(
      title: '标题',
      artist: '歌手',
      notice: null,
      lines: <LyricLine>[
        const LyricLine(Duration(milliseconds: 1200), '第一句'),
        LyricLine(
          const Duration(milliseconds: 4200),
          '第二句',
          end: const Duration(milliseconds: 6200),
        ),
      ],
      settings: settingsWithLines(3),
      position: const Duration(milliseconds: 2500),
      duration: const Duration(minutes: 4),
      playing: true,
    );
    final LyricsOverlayPayload parsed = LyricsOverlayPayload.fromMap(
      payload.toMap(),
    );
    expect(parsed.title, '标题');
    expect(parsed.artist, '歌手');
    expect(parsed.notice, isNull);
    expect(parsed.lines.map((LyricLine line) => line.text), <String>[
      '第一句',
      '第二句',
    ]);
    expect(parsed.lines.first.time, const Duration(milliseconds: 1200));
    expect(parsed.lines.last.end, const Duration(milliseconds: 6200));
    expect(parsed.position, const Duration(milliseconds: 2500));
    expect(parsed.duration, const Duration(minutes: 4));
    expect(parsed.playing, isTrue);
    expect(parsed.settings.lineCount, 3);
  });
}
