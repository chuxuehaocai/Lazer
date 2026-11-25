// 悬浮/桌面歌词跑起来时，Windows 辅助功能桥会一直刷：
//
//   [ERROR:flutter/shell/platform/common/accessibility_bridge.cc(114)]
//   Failed to update ui::AXTree, error: Nodes left pending by the update: 259
//
//   ... error: 4425 will not be in the tree and is not the new root
//
// 每一条都是一次语义节点增删。歌词行每一帧都在动（弹簧 y、缩放、透明度），
// 以前每一行都是一个 `Semantics` 节点，于是每个 vsync 都要重建这些节点，桥来
// 不及收敛，节点 id 就漂成上面那样。
//
// 这个测试把「歌词播放时语义树必须稳定」钉住：动画跑起来之后，语义节点集合不许
// 变化，节点的 rect 也不许跟着弹簧移动。它读的是真引擎编译出来的语义树。
import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderView, SemanticsNode;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lazer_nextgen/data/lyrics.dart';
import 'package:lazer_nextgen/desktop_lyrics/lyrics_overlay.dart';
import 'package:lazer_nextgen/desktop_lyrics/overlay_protocol.dart';
import 'package:lazer_nextgen/lyrics/lyric_document.dart';
import 'package:lazer_nextgen/theme/lazer_theme.dart';

const _settings = LyricsOverlaySettings(
  lineCount: 3,
  fontSize: 22,
  fontWeight: 600,
  fontFamily: 'MiSans',
  fontPath: null,
  blurEnabled: true,
  blurIntensity: 1,
  animationSpeed: 1,
  lineSpacing: 16,
);

Future<OverlayBridge> _mount(WidgetTester tester) async {
  final bridge = OverlayBridge();
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(extensions: const [LazerThemeTokens.apple]),
      home: MediaQuery(
        data: const MediaQueryData(size: Size(420, 320)),
        child: LyricsOverlayApp(
          controller: WindowController.fromWindowId('fixture'),
          launch: const LyricsOverlayLaunch(
            mode: LyricsOverlayMode.floating,
            settings: _settings,
          ),
          channel: const WindowMethodChannel('fixture'),
          bridge: bridge,
        ),
      ),
    ),
  );
  return bridge;
}

Future<void> _play(OverlayBridge bridge) => bridge.handler!(
  MethodCall(
    'state',
    const LyricsOverlayPayload(
      title: 'Track',
      artist: 'Artist',
      notice: null,
      lines: [
        LyricLine(Duration.zero, 'First line'),
        LyricLine(Duration(seconds: 4), 'Second line'),
        LyricLine(Duration(seconds: 8), 'Third line'),
      ],
      settings: _settings,
      position: Duration(milliseconds: 3500),
      duration: Duration(minutes: 4),
      playing: true,
    ).toMap(),
  ),
);

/// The semantics root of the view the overlay lives in.
///
/// Read through [RendererBinding.renderViews] rather than the deprecated
/// `pipelineOwner`: the binding can own several views, and only the one this
/// widget was pumped into carries the tree under test.
SemanticsNode _root(WidgetTester tester) {
  final root = tester.binding.renderViews
      .map((RenderView view) => view.owner?.semanticsOwner?.rootSemanticsNode)
      .whereType<SemanticsNode>()
      .firstOrNull;
  expect(root, isNotNull, reason: 'the overlay must keep a semantics root');
  return root!;
}

/// Every node in the tree, by id, with the rect it occupies on screen.
Map<int, Rect> _nodes(WidgetTester tester) {
  final nodes = <int, Rect>{};
  void visit(SemanticsNode node) {
    nodes[node.id] = node.rect;
    node.visitChildren((SemanticsNode child) {
      visit(child);
      return true;
    });
  }

  visit(_root(tester));
  return nodes;
}

List<String> _labels(WidgetTester tester) {
  final labels = <String>[];
  void visit(SemanticsNode node) {
    if (node.label.isNotEmpty) labels.add(node.label);
    node.visitChildren((SemanticsNode child) {
      visit(child);
      return true;
    });
  }

  visit(_root(tester));
  return labels;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final channel in <String>[
      'mixin.one/desktop_multi_window/channels',
      'window_manager',
      kDesktopLyricsChannel,
    ]) {
      messenger.setMockMethodCallHandler(MethodChannel(channel), (call) async {
        return call.method == 'getBounds'
            ? {'x': 0.0, 'y': 0.0, 'width': 420.0, 'height': 320.0}
            : null;
      });
    }
  });

  testWidgets(
    'lyrics motion keeps the semantics tree still instead of rebuilding nodes',
    (tester) async {
      // Real accessibility has to be on: without a semantics handle the binding
      // never compiles a tree and this whole failure mode stays invisible.
      final semantics = tester.ensureSemantics();
      final bridge = await _mount(tester);
      await tester.pump();
      await _play(bridge);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));

      final before = _nodes(tester);
      expect(
        before,
        isNotEmpty,
        reason: 'the panel still has to be readable to a screen reader',
      );

      // Walk the playhead across every line, the way a real track does. Each
      // handoff used to mount a fresh row (and unmount the one that scrolled
      // out), so the tree kept gaining and dropping nodes — which is exactly
      // what the bridge choked on. The panel's semantics must not notice.
      for (final int ms in <int>[1000, 4500, 6000, 8500, 12000]) {
        await bridge.handler!(
          MethodCall('position', {'position': ms, 'playing': true}),
        );
        for (var frame = 0; frame < 20; frame++) {
          await tester.pump(const Duration(milliseconds: 16));
        }
        final now = _nodes(tester);
        expect(
          now.keys,
          unorderedEquals(before.keys),
          reason: 'line handoff at ${ms}ms changed the semantics node set',
        );
        // A node that moves with the lyric motion forces the bridge to re-send
        // this subtree forever; its geometry has to stay put while paint does not.
        for (final entry in before.entries) {
          expect(
            now[entry.key],
            entry.value,
            reason: 'semantics node ${entry.key} moved with the lyric motion',
          );
        }
      }

      await tester.pumpWidget(const SizedBox.shrink());
      semantics.dispose();
    },
  );

  testWidgets('the focused lyric is the one a screen reader reads', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final bridge = await _mount(tester);
    await tester.pump();
    await _play(bridge);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));

    final labels = _labels(tester).join('\n');
    expect(
      labels,
      contains('First line'),
      reason: 'the panel mirrors the lyric the listener is on',
    );
    // Every visible row used to publish its own label; only the focus line is
    // meant to reach the tree.
    expect(labels, isNot(contains('Third line')));

    await tester.pumpWidget(const SizedBox.shrink());
    semantics.dispose();
  });
}
