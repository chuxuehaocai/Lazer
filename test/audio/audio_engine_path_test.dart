// Phase 1: the launch must be able to say which playback path it is on, and why.
//
// The decision is a pure function so it can be asserted here; the rest of the
// file wires that decision through the engine contract, `AppState` and the badge
// the player renders.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart' as audio;
import 'package:lazer_nextgen/audio/audio_engine.dart';
import 'package:lazer_nextgen/audio/native/engine_selection.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/widgets/audio_path_badge.dart';

/// A player that answers only what [JustAudioEngine] touches on construction.
class _IdlePlayer implements audio.AudioPlayer {
  final StreamController<audio.ProcessingState> _states =
      StreamController<audio.ProcessingState>.broadcast();
  final StreamController<int?> _indexes =
      StreamController<int?>.broadcast();

  @override
  Stream<audio.ProcessingState> get processingStateStream => _states.stream;

  @override
  Stream<int?> get currentIndexStream => _indexes.stream;

  @override
  Future<void> dispose() async {
    await _states.close();
    await _indexes.close();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

void main() {
  group('planAudioEnginePath', () {
    test('native when the host supports it and the library loaded', () {
      final AudioEnginePathDecision decision = planAudioEnginePath(
        preferNative: true,
        hostSupported: true,
      );

      expect(decision.isNative, isTrue);
      expect(decision.fallback, isNull);
      expect(decision.notice, isNull);
      expect(decision.description, 'native (lazer-audio)');
    });

    test('the user\'s engine choice is its own reason, not a failure', () {
      final AudioEnginePathDecision decision = planAudioEnginePath(
        preferNative: false,
        hostSupported: true,
      );

      expect(decision.fallback, AudioPathFallback.userSelectedSystemEngine);
      expect(decision.notice, contains('非 HiFi'));
      expect(decision.description, 'just_audio');
    });

    test('a missing library keeps the loader\'s reason', () {
      final AudioEnginePathDecision decision = planAudioEnginePath(
        preferNative: true,
        hostSupported: true,
        libraryUnavailableReason: 'lazer-audio.dll was not found',
      );

      expect(decision.fallback, AudioPathFallback.libraryUnavailable);
      expect(decision.detail, 'lazer-audio.dll was not found');
      expect(decision.notice, contains('lazer-audio.dll was not found'));
      expect(decision.description, contains('lazer-audio.dll was not found'));
    });

    test('an unsupported host is distinguishable from a broken build', () {
      final AudioEnginePathDecision decision = planAudioEnginePath(
        preferNative: true,
        hostSupported: false,
        libraryUnavailableReason: 'this platform has no native audio backend',
      );

      expect(decision.fallback, AudioPathFallback.unsupportedHost);
      expect(decision.notice, contains('当前平台没有原生 HiFi 引擎'));
    });
  });

  group('formatAudioPathRecord', () {
    test('emits greppable key=value pairs, "-" for absent values', () {
      final String record = formatAudioPathRecord('format', <String, Object?>{
        'exclusive': 1,
        'detail': null,
        'kind': 'windows endpoints',
      });

      expect(record, 'audio.path event=format exclusive=1 detail=- kind="windows endpoints"');
    });

    test('an event with no fields is still one line', () {
      expect(formatAudioPathRecord('select'), 'audio.path event=select');
    });
  });

  group('the fallback engine reports why it is the fallback', () {
    test('pendingFailure carries the launch-time reason', () {
      final JustAudioEngine engine = JustAudioEngine(
        player: _IdlePlayer(),
        fallbackNotice: '原生 HiFi 引擎初始化失败：no audio device',
      );
      addTearDown(engine.dispose);

      expect(
        engine.pendingFailure,
        '原生 HiFi 引擎初始化失败：no audio device',
      );
    });

    test('a native session has no pending failure to report', () {
      final JustAudioEngine engine = JustAudioEngine(player: _IdlePlayer());
      addTearDown(engine.dispose);

      expect(engine.pendingFailure, isNull);
      expect(engine, isA<FailureReportingAudioEngine>());
    });

    test('reportFailure reaches subscribers, and stops after dispose', () async {
      final JustAudioEngine engine = JustAudioEngine(player: _IdlePlayer());
      final List<String> reported = <String>[];
      final StreamSubscription<String> subscription = engine.failures.listen(
        reported.add,
      );
      addTearDown(subscription.cancel);

      expect(engine.reportFailure('device lost'), isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(reported, <String>['device lost']);

      engine.dispose();
      expect(engine.reportFailure('too late'), isFalse);
    });
  });

  group('AppState surfaces the path', () {
    test('a launch-time fallback becomes the standing notice', () {
      final JustAudioEngine engine = JustAudioEngine(
        player: _IdlePlayer(),
        fallbackNotice: '原生 HiFi 引擎不可用：lazer-audio.dll was not found',
      );
      final AppState state = AppState(
        audioEngine: engine,
        hifiPathNotice: 'shall be replaced by the engine\'s own report',
      );

      expect(state.hifiPathIsNative, isFalse);
      expect(state.hifiPathNotice, contains('lazer-audio.dll was not found'));

      state.dispose();
      engine.dispose();
    });

    test('the native path has no notice', () {
      final AppState state = AppState(
        audioEngine: JustAudioEngine(player: _IdlePlayer()),
      );

      expect(state.hifiPathIsNative, isTrue);
      expect(state.hifiPathNotice, isNull);

      state.dispose();
    });
  });

  group('AudioPathBadge', () {
    Future<void> pump(WidgetTester tester, String? notice) async {
      final AppState state = AppState(
        audioEngine: JustAudioEngine(player: _IdlePlayer()),
        hifiPathNotice: notice,
      );
      addTearDown(state.dispose);
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: AudioPathBadge(state: state))),
      );
    }

    testWidgets('renders nothing on the native path', (tester) async {
      await pump(tester, null);

      expect(find.byKey(const ValueKey('hifi-path-native')), findsOneWidget);
      expect(find.textContaining('非 HiFi 路径'), findsNothing);
    });

    testWidgets('names the path and the reason on a fallback', (tester) async {
      await pump(tester, '原生 HiFi 引擎不可用：lazer-audio.dll was not found');

      expect(find.byKey(const ValueKey('hifi-path-fallback')), findsOneWidget);
      expect(find.textContaining('非 HiFi 路径'), findsOneWidget);
      expect(find.textContaining('lazer-audio.dll was not found'), findsOneWidget);
    });
  });
}
