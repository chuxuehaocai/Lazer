import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/audio/native/engine_selection.dart';

/// 「已选择系统音频引擎，当前非 HiFi 路径」这条提示条不该再出现。
///
/// 它不是故障，只是把用户刚在设置里做过的选择复述一遍，还会盖住播放条。
/// 真正的降级（原生引擎起不来、运行中断开）仍然要提示，所以只看两个开关：
/// AppState 记下「这次是用户自选」，Shell 见到它就跳过提示。
void main() {
  test('自选系统引擎仍然带着诊断用的说明文字', () {
    const decision = AudioEnginePathDecision.fallback(
      AudioPathFallback.userSelectedSystemEngine,
    );
    // 日志与诊断导出还是要能看出这次走的不是 HiFi 路径。
    expect(decision.notice, isNotNull);
    expect(decision.isNative, isFalse);
  });

  test('真正的失败仍然保留提示', () {
    for (final fallback in <AudioPathFallback>[
      AudioPathFallback.unsupportedHost,
      AudioPathFallback.libraryUnavailable,
      AudioPathFallback.sessionStartupFailed,
    ]) {
      expect(
        AudioEnginePathDecision.fallback(fallback).notice,
        isNotNull,
        reason: '$fallback 是故障，必须提示',
      );
    }
  });

  test('main.dart 把「自选」这一事实交给 AppState', () {
    final String source = File('lib/main.dart').readAsStringSync();
    expect(source, contains('hifiFallbackIsUserChoice'));
    expect(
      source,
      contains('AudioPathFallback.userSelectedSystemEngine'),
      reason: '必须按 fallback 原因判断，而不是一律静音',
    );
  });

  test('Shell 在用户自选时不再弹提示条', () {
    final String source = File('lib/ui/shell.dart').readAsStringSync();
    final int announce = source.indexOf('void _announceHifiFallback()');
    expect(announce, isNonNegative);
    final String body = source.substring(announce, announce + 400);
    expect(body, contains('if (state.hifiFallbackIsUserChoice) return;'));
  });
}
