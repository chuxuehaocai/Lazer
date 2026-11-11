import 'dart:convert';

import '../lyrics/lyric_document.dart';

const String kLyricsOverlayKind = 'lazer-lyrics-overlay';
const String kLyricsOverlayReadyChannel = 'lazer.lyrics.overlay.ready';
const String kLyricsOverlayChannelPrefix = 'lazer.lyrics.overlay.';
const String kDesktopLyricsChannel = 'lazer/desktop_lyrics';

enum LyricsOverlayMode { floating, desktop }

class LyricsOverlayLaunch {
  const LyricsOverlayLaunch({required this.mode, required this.settings});

  final LyricsOverlayMode mode;
  final LyricsOverlaySettings settings;

  String encode() => jsonEncode(<String, Object?>{
    'kind': kLyricsOverlayKind,
    'mode': mode.name,
    ...settings.toMap(),
  });

  static LyricsOverlayLaunch? tryParse(String source) {
    if (source.isEmpty) return null;
    try {
      final Object? decoded = jsonDecode(source);
      if (decoded is! Map) return null;
      if (decoded['kind'] != kLyricsOverlayKind) return null;
      final LyricsOverlayMode? mode = LyricsOverlayMode.values
          .where((LyricsOverlayMode value) => value.name == decoded['mode'])
          .firstOrNull;
      if (mode == null) return null;
      return LyricsOverlayLaunch(
        mode: mode,
        settings: LyricsOverlaySettings.fromMap(decoded),
      );
    } on FormatException {
      return null;
    }
  }
}

class LyricsOverlaySettings {
  const LyricsOverlaySettings({
    required this.lineCount,
    required this.fontSize,
    required this.fontWeight,
    required this.fontFamily,
    required this.fontPath,
    required this.blurEnabled,
    required this.blurIntensity,
    required this.animationSpeed,
  });

  final int lineCount;
  final double fontSize;
  final int fontWeight;
  final String fontFamily;
  final String? fontPath;
  final bool blurEnabled;
  final double blurIntensity;
  final double animationSpeed;

  Map<String, Object?> toMap() => <String, Object?>{
    'lineCount': lineCount,
    'fontSize': fontSize,
    'fontWeight': fontWeight,
    'fontFamily': fontFamily,
    'fontPath': fontPath,
    'blurEnabled': blurEnabled,
    'blurIntensity': blurIntensity,
    'animationSpeed': animationSpeed,
  };

  factory LyricsOverlaySettings.fromMap(Map<dynamic, dynamic> map) {
    final num fontSize = map['fontSize'] is num ? map['fontSize'] as num : 22;
    final num blurIntensity = map['blurIntensity'] is num
        ? map['blurIntensity'] as num
        : 1;
    final num animationSpeed = map['animationSpeed'] is num
        ? map['animationSpeed'] as num
        : 1;
    return LyricsOverlaySettings(
      lineCount: (map['lineCount'] is num ? map['lineCount'] as num : 3)
          .toInt()
          .clamp(1, 5),
      fontSize: fontSize.toDouble().clamp(14, 40),
      fontWeight:
          (map['fontWeight'] is num ? (map['fontWeight'] as num).toInt() : 600)
              .clamp(400, 700),
      fontFamily: map['fontFamily'] is String
          ? map['fontFamily'] as String
          : 'MiSans',
      fontPath: map['fontPath'] is String ? map['fontPath'] as String : null,
      blurEnabled: map['blurEnabled'] is bool
          ? map['blurEnabled'] as bool
          : true,
      blurIntensity: blurIntensity.toDouble().clamp(0.0, 1.0),
      animationSpeed: animationSpeed.toDouble().clamp(0.5, 2.0),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is LyricsOverlaySettings &&
      lineCount == other.lineCount &&
      fontSize == other.fontSize &&
      fontWeight == other.fontWeight &&
      fontFamily == other.fontFamily &&
      fontPath == other.fontPath &&
      blurEnabled == other.blurEnabled &&
      blurIntensity == other.blurIntensity &&
      animationSpeed == other.animationSpeed;

  @override
  int get hashCode => Object.hash(
    lineCount,
    fontSize,
    fontWeight,
    fontFamily,
    fontPath,
    blurEnabled,
    blurIntensity,
    animationSpeed,
  );
}

class LyricsOverlayPayload {
  const LyricsOverlayPayload({
    required this.title,
    required this.artist,
    required this.notice,
    required this.lines,
    required this.settings,
    required this.position,
    required this.duration,
    required this.playing,
  });

  final String title;
  final String artist;
  final String? notice;
  final List<LyricLine> lines;
  final LyricsOverlaySettings settings;
  final Duration position;
  final Duration duration;
  final bool playing;

  Map<String, Object?> toMap() => <String, Object?>{
    'title': title,
    'artist': artist,
    'notice': notice,
    'lines': <Object?>[
      for (final LyricLine line in lines)
        <String, Object?>{
          'time': line.time.inMilliseconds,
          'end': line.end?.inMilliseconds,
          'text': line.text,
          'translation': line.translation,
          'words': [
            for (final word in line.words)
              {
                'start': word.start.inMicroseconds,
                'duration': word.duration.inMicroseconds,
                'text': word.text,
              },
          ],
        },
    ],
    'settings': settings.toMap(),
    'position': position.inMilliseconds,
    'duration': duration.inMilliseconds,
    'playing': playing,
  };

  factory LyricsOverlayPayload.fromMap(Map<dynamic, dynamic> map) {
    final Object? rawLines = map['lines'];
    final List<LyricLine> lines = <LyricLine>[];
    if (rawLines is List) {
      for (final Object? raw in rawLines) {
        if (raw is! Map) continue;
        final Object? time = raw['time'];
        final Object? text = raw['text'];
        if (time is! num || text is! String) continue;
        final Object? end = raw['end'];
        lines.add(
          LyricLine(
            Duration(milliseconds: time.toInt()),
            text,
            end: end is num ? Duration(milliseconds: end.toInt()) : null,
            translation: raw['translation'] as String?,
            words: [
              if (raw['words'] is List)
                for (final word in raw['words'] as List)
                  if (word is Map &&
                      word['start'] is num &&
                      word['duration'] is num &&
                      word['text'] is String)
                    LyricWord(
                      Duration(microseconds: (word['start'] as num).toInt()),
                      Duration(microseconds: (word['duration'] as num).toInt()),
                      word['text'] as String,
                    ),
            ],
          ),
        );
      }
    }
    final Object? rawSettings = map['settings'];
    return LyricsOverlayPayload(
      title: map['title'] is String ? map['title'] as String : '',
      artist: map['artist'] is String ? map['artist'] as String : '',
      notice: map['notice'] is String ? map['notice'] as String : null,
      lines: lines,
      settings: rawSettings is Map
          ? LyricsOverlaySettings.fromMap(rawSettings)
          : const LyricsOverlaySettings(
              lineCount: 3,
              fontSize: 22,
              fontWeight: 600,
              fontFamily: 'MiSans',
              fontPath: null,
              blurEnabled: true,
              blurIntensity: 1,
              animationSpeed: 1,
            ),
      position: Duration(
        milliseconds: map['position'] is num
            ? (map['position'] as num).toInt()
            : 0,
      ),
      duration: Duration(
        milliseconds: map['duration'] is num
            ? (map['duration'] as num).toInt()
            : 0,
      ),
      playing: map['playing'] is bool ? map['playing'] as bool : false,
    );
  }
}
