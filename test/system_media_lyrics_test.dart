import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lazer_nextgen/audio/audio_engine.dart';
import 'package:lazer_nextgen/audio/system_media_handler.dart';
import 'package:lazer_nextgen/data/audio_quality.dart';
import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/data/lyrics.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/gateway/gateway.dart';
import 'package:lazer_nextgen/state/app_state.dart';

const Track _track = Track(
  id: '1',
  title: 'First',
  artist: 'One',
  album: 'Album',
  duration: Duration(seconds: 30),
  coverSeed: 1,
);

class _Catalog extends Catalog {
  _Catalog({this.withLyrics = true});
  final bool withLyrics;
  @override
  Future<String?> audioUrlFor(
    Track track, {
    AudioQuality quality = AudioQuality.exhigh,
    bool Function()? isCancelled,
  }) async => track.id;
  @override
  Future<GatewayLyrics?> lyricsFor(Track track) async => withLyrics
      ? const GatewayLyrics(
          lrc:
              '[00:01.00]first line\n'
              '[00:03.00]second line\n'
              '[00:20.00]third line',
        )
      : null;
}

class _Engine implements AudioEngine {
  final StreamController<void> _completed = StreamController<void>.broadcast();
  @override
  Future<void> setUrl(String url) async => active = true;
  @override
  Future<void> play() async {}
  @override
  Future<void> pause() async {}
  @override
  Future<void> seek(Duration position) async => this.position = position;
  @override
  Future<void> setVolume(double volume) async {}
  @override
  Future<void> stop() async => active = false;
  @override
  bool active = false;
  @override
  Duration position = Duration.zero;
  @override
  Duration? duration = const Duration(seconds: 30);
  @override
  Stream<void> get completed => _completed.stream;
  @override
  void dispose() => _completed.close();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  /// One beat of the handler's own clock, which is what moves the line on.
  Future<void> beat(WidgetTester tester) =>
      tester.pump(const Duration(seconds: 1));

  Future<(AppState, _Engine, LazerMediaHandler)> playing(
    WidgetTester tester, {
    bool withLyrics = true,
    MediaArtworkResolver? artwork,
  }) async {
    final engine = _Engine();
    final state = AppState(
      catalog: _Catalog(withLyrics: withLyrics),
      audioEngine: engine,
    );
    final handler = LazerMediaHandler(
      state,
      artwork: artwork ?? (_) async => null,
    );
    state.playQueue(<Track>[_track]);
    await tester.pump();
    // The lyric request is a real future: let it land before the first beat.
    await tester.pump(const Duration(milliseconds: 30));
    return (state, engine, handler);
  }

  /// Tears the session down inside the test body: `addTearDown` runs after the
  /// framework has already rejected a pending timer, and both the handler's
  /// clock and the playback ticker are timers.
  void stop(AppState state, _Engine engine, LazerMediaHandler handler) {
    handler.close();
    state.dispose();
    engine.dispose();
  }

  testWidgets('the system control follows the line being sung', (tester) async {
    final (state, engine, handler) = await playing(tester);
    expect(state.lyrics, hasLength(3));

    // Nothing is sung yet: the control keeps the artist.
    expect(handler.mediaItem.value?.artist, 'One');
    expect(handler.mediaItem.value?.title, 'First');

    engine.position = const Duration(seconds: 4);
    await beat(tester);
    expect(handler.mediaItem.value?.artist, 'second line');
    expect(handler.mediaItem.value?.displaySubtitle, 'second line');
    expect(
      handler.mediaItem.value?.displayTitle,
      'First',
      reason: 'Android 12 and older only honour a subtitle beside a title',
    );
    expect(handler.mediaItem.value?.displayDescription, 'One');
    expect(state.audioReady, isTrue);

    // A seek backwards moves the line back with it.
    engine.position = const Duration(seconds: 2);
    await beat(tester);
    expect(handler.mediaItem.value?.artist, 'first line');

    stop(state, engine, handler);
  });

  testWidgets('late artwork keeps the lyric currently on the controls', (
    tester,
  ) async {
    final artwork = Completer<Uri?>();
    final (state, engine, handler) = await playing(
      tester,
      artwork: (_) => artwork.future,
    );
    engine.position = const Duration(seconds: 4);
    await beat(tester);
    expect(handler.mediaItem.value?.artist, 'second line');

    final uri = Uri.parse('file:///cover.png');
    artwork.complete(uri);
    await tester.pump();
    expect(handler.mediaItem.value?.artUri, uri);
    expect(handler.mediaItem.value?.artist, 'second line');
    expect(handler.mediaItem.value?.displaySubtitle, 'second line');

    stop(state, engine, handler);
  });

  testWidgets('the lyric line can be switched off, leaving the artist', (
    tester,
  ) async {
    final (state, engine, handler) = await playing(tester);
    engine.position = const Duration(seconds: 4);
    await beat(tester);
    expect(handler.mediaItem.value?.artist, 'second line');

    await state.setSystemMediaLyrics(false);
    await beat(tester);
    expect(handler.mediaItem.value?.artist, 'One');
    expect(handler.mediaItem.value?.displaySubtitle, isNull);
    expect(
      (await SharedPreferences.getInstance()).getBool(
        'lazer_system_media_lyrics',
      ),
      false,
    );

    stop(state, engine, handler);
  });

  testWidgets('queue entries keep the artist, never the lyric line', (
    tester,
  ) async {
    final (state, engine, handler) = await playing(tester);
    engine.position = const Duration(seconds: 4);
    await beat(tester);
    expect(handler.mediaItem.value?.artist, 'second line');
    expect(handler.queue.value.single.artist, 'One');

    stop(state, engine, handler);
  });

  testWidgets('the desktop controls keep the artist', (tester) async {
    // MPRIS and the Windows flyout are read by other applications as well, so
    // the line stays on the phone surfaces.
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    final (state, engine, handler) = await playing(tester);
    engine.position = const Duration(seconds: 4);
    await beat(tester);
    expect(handler.mediaItem.value?.artist, 'One');
    expect(handler.mediaItem.value?.displaySubtitle, isNull);

    stop(state, engine, handler);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('an instrumental line falls back to the last words sung', (
    tester,
  ) async {
    final (state, engine, handler) = await playing(tester, withLyrics: false);
    state.lyrics = const <LyricLine>[
      LyricLine(Duration(seconds: 1), 'first'),
      LyricLine(Duration(seconds: 2), '   '),
      LyricLine(Duration(seconds: 4), 'third'),
    ];
    expect(state.currentLyricLine, isNull);

    engine.position = const Duration(seconds: 3);
    expect(state.currentLyricLine?.text, 'first');

    engine.position = const Duration(seconds: 5);
    expect(state.currentLyricLine?.text, 'third');

    stop(state, engine, handler);
  });
}
