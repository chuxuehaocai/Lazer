import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/widgets/window_chrome.dart';

const _belowKey = ValueKey('below-window-chrome');
const _contentKey = ValueKey('window-chrome-content');
const _sizeKey = ValueKey('window-chrome-size');
const _slideKey = ValueKey('window-chrome-slide');
const _fadeKey = ValueKey('window-chrome-fade');

Widget _chrome({
  required bool visible,
  bool reduceMotion = false,
  Widget? content,
}) => Directionality(
  textDirection: TextDirection.ltr,
  child: MediaQuery(
    data: MediaQueryData(disableAnimations: reduceMotion),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        WindowChromeTransition(
          visible: visible,
          child: SizedBox(
            key: _contentKey,
            width: double.infinity,
            height: 40,
            child: content ?? const ColoredBox(color: Colors.blue),
          ),
        ),
        const SizedBox(key: _belowKey, height: 40),
      ],
    ),
  ),
);

double _opacity(WidgetTester tester) =>
    tester.widget<FadeTransition>(find.byKey(_fadeKey)).opacity.value;

double _progress(WidgetTester tester) =>
    tester.widget<Align>(find.byKey(_sizeKey)).heightFactor!;

void main() {
  group('WindowChromeController', () {
    test('the last source wins and detach restores the preceding source', () {
      final controller = WindowChromeController();
      final first = _TestSource(true);
      final second = _TestSource(false);
      addTearDown(controller.dispose);
      addTearDown(first.dispose);
      addTearDown(second.dispose);

      expect(controller.value, isTrue);
      controller.attach(first);
      controller.attach(second);
      expect(controller.value, isFalse);

      first.value = false;
      first.value = true;
      expect(controller.value, isFalse);
      second.value = true;
      expect(controller.value, isTrue);
      first.value = false;
      controller.detach(second);
      expect(controller.value, isFalse);
      second.value = false;
      second.value = true;
      expect(controller.value, isFalse);
      controller.detach(first);
      expect(controller.value, isTrue);
      expect(first.listening, isFalse);
      expect(second.listening, isFalse);
    });

    test('reattach updates ownership and pointer callbacks stay ordered', () {
      final controller = WindowChromeController();
      final first = _TestSource(true);
      final second = _TestSource(false);
      final events = <String>[];
      addTearDown(controller.dispose);
      addTearDown(first.dispose);
      addTearDown(second.dispose);

      controller.attach(first, onActivity: () => events.add('old activity'));
      controller.attach(
        second,
        onActivity: () => events.add('second activity'),
        onPointerStart: (pointer) => events.add('second start $pointer'),
        onPointerEnd: (pointer) => events.add('second end $pointer'),
      );
      controller.pointerDown(7);
      controller.pointerUp(7);
      controller.attach(
        first,
        onActivity: () => events.add('first activity'),
        onPointerStart: (pointer) => events.add('first start $pointer'),
        onPointerEnd: (pointer) => events.add('first end $pointer'),
      );
      expect(controller.value, isTrue);
      controller.pointerDown(8);
      controller.pointerUp(8);
      expect(events, [
        'second start 7',
        'second activity',
        'second end 7',
        'first start 8',
        'first activity',
        'first end 8',
      ]);
      controller.detach(first);
      expect(controller.value, isFalse);
    });

    test('disposing releases every source listener', () {
      final controller = WindowChromeController();
      final first = _TestSource(true);
      final second = _TestSource(false);
      addTearDown(first.dispose);
      addTearDown(second.dispose);
      controller.attach(first);
      controller.attach(second);
      expect(first.listening, isTrue);
      expect(second.listening, isTrue);
      controller.dispose();
      expect(first.listening, isFalse);
      expect(second.listening, isFalse);
      first.value = false;
      second.value = true;
      controller.detach(second);
    });

    test('retiring an older action owner preserves the current extension', () {
      final controller = WindowChromeController();
      final previousPage = Object();
      final currentPage = Object();
      addTearDown(controller.dispose);
      controller.updateActions(previousPage, width: 138, active: true);
      controller.updateActions(currentPage, width: 184, active: true);
      // Without a ticker nothing can animate, so the newest set owns the
      // extension at once and the older one contributes nothing.
      expect(controller.actionsWidth, 184);
      expect(controller.actionsActive, isTrue);
      expect(controller.paintedActionsWidth, 184);
      controller.removeActions(previousPage);
      expect(controller.actionsWidth, 184);
      expect(controller.actionsActive, isTrue);

      // A set whose route stopped being current keeps its width until it is
      // actually retired; on this controller that is immediate.
      controller.updateActions(currentPage, width: 184, active: false);
      expect(controller.actionsActive, isFalse);
      controller.removeActions(currentPage);
      expect(controller.actionsWidth, 0);
      expect(controller.actionsActive, isFalse);
      expect(controller.paintedActionsWidth, 0);
    });
  });

  testWidgets(
    'a scoped descendant can attach and detach during a parent build',
    (tester) async {
      final controller = WindowChromeController();
      final source = _TestSource(false);
      addTearDown(controller.dispose);
      addTearDown(source.dispose);
      Widget scoped(bool attached) => Directionality(
        textDirection: TextDirection.ltr,
        child: WindowChromeScope(
          controller: controller,
          child: ValueListenableBuilder<bool>(
            valueListenable: controller,
            builder: (context, visible, _) => Column(
              children: [
                Text(visible ? 'visible' : 'hidden'),
                if (attached) _ChromeSourceBinding(source: source),
              ],
            ),
          ),
        ),
      );

      await tester.pumpWidget(scoped(true));
      await tester.pump();
      expect(find.text('hidden'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(scoped(false));
      await tester.pump();
      expect(find.text('visible'), findsOneWidget);
      expect(tester.takeException(), isNull);
      expect(source.listening, isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('fade and upward slide release the same height to the next row', (
    tester,
  ) async {
    await tester.pumpWidget(_chrome(visible: true));
    expect(tester.getTopLeft(find.byKey(_belowKey)).dy, 40);
    await tester.pumpWidget(_chrome(visible: false));
    await tester.pump(const Duration(milliseconds: 120));
    final progress = _progress(tester);
    expect(progress, inExclusiveRange(0, 1));
    expect(_opacity(tester), closeTo(progress, .0001));
    expect(
      tester.getTopLeft(find.byKey(_belowKey)).dy,
      closeTo(40 * progress, .001),
    );
    expect(
      tester
          .widget<FractionalTranslation>(find.byKey(_slideKey))
          .translation
          .dy,
      closeTo(progress - 1, .0001),
    );
    expect(
      tester.getTopLeft(find.byKey(_contentKey)).dy,
      closeTo(40 * (progress - 1), .001),
    );
    await tester.pumpAndSettle();
    expect(_opacity(tester), 0);
    expect(tester.getTopLeft(find.byKey(_belowKey)).dy, 0);

    await tester.pumpWidget(_chrome(visible: true));
    await tester.pump(const Duration(milliseconds: 120));
    expect(_progress(tester), inExclusiveRange(0, 1));
    expect(_opacity(tester), closeTo(_progress(tester), .0001));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.byKey(_belowKey)).dy, 40);
    expect(_opacity(tester), 1);
  });

  testWidgets('spring movement is quicker early and eases into its endpoint', (
    tester,
  ) async {
    await tester.pumpWidget(_chrome(visible: true));
    await tester.pumpWidget(_chrome(visible: false));
    await tester.pump(const Duration(milliseconds: 200));
    final early = 1 - _progress(tester);
    await tester.pump(const Duration(milliseconds: 200));
    final late = 1 - _progress(tester) - early;
    expect(early, greaterThan(late * 2));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('reversing the spring keeps its current position and velocity', (
    tester,
  ) async {
    await tester.pumpWidget(_chrome(visible: true));
    await tester.pumpWidget(_chrome(visible: false));
    await tester.pump(const Duration(milliseconds: 100));
    final before = _progress(tester);
    await tester.pumpWidget(_chrome(visible: true));
    expect(_progress(tester), closeTo(before, .0001));
    // Momentum initially continues upwards before the spring turns around.
    await tester.pump(const Duration(milliseconds: 16));
    expect(_progress(tester), lessThan(before));
    await tester.pumpAndSettle();
    expect(_progress(tester), 1);
    expect(_opacity(tester), 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reduced motion snaps on retarget and when enabled mid-flight', (
    tester,
  ) async {
    await tester.pumpWidget(_chrome(visible: true));
    await tester.pumpWidget(_chrome(visible: false));
    await tester.pump(const Duration(milliseconds: 80));
    expect(_progress(tester), inExclusiveRange(0, 1));
    await tester.pumpWidget(_chrome(visible: false, reduceMotion: true));
    expect(_progress(tester), 0);
    expect(_opacity(tester), 0);
    await tester.pumpWidget(_chrome(visible: true, reduceMotion: true));
    expect(_progress(tester), 1);
    expect(_opacity(tester), 1);
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets(
    'hidden chrome immediately leaves hit testing, focus and semantics',
    (tester) async {
      var taps = 0;
      final focus = FocusNode();
      addTearDown(focus.dispose);
      final semantics = tester.ensureSemantics();
      final content = Focus(
        focusNode: focus,
        child: Semantics(
          label: 'Window controls',
          button: true,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => taps++,
            child: const ColoredBox(color: Colors.blue),
          ),
        ),
      );
      await tester.pumpWidget(_chrome(visible: true, content: content));
      await tester.tapAt(const Offset(20, 20));
      expect(taps, 1);
      expect(focus.canRequestFocus, isTrue);
      expect(
        tester.semantics.simulatedAccessibilityTraversal(),
        contains(isSemantics(label: 'Window controls')),
      );

      await tester.pumpWidget(_chrome(visible: false, content: content));
      // The visual spring has just started, but hidden controls are inert now.
      expect(_opacity(tester), 1);
      await tester.tapAt(const Offset(20, 20));
      expect(taps, 1);
      expect(focus.canRequestFocus, isFalse);
      expect(
        tester.semantics.simulatedAccessibilityTraversal(),
        isNot(contains(isSemantics(label: 'Window controls'))),
      );
      await tester.pumpAndSettle();
      semantics.dispose();
    },
  );
  testWidgets(
    'a page command leaves the capsule before the player actions arrive',
    (tester) async {
      final pageOpen = ValueNotifier<bool>(true);
      final playerOpen = ValueNotifier<bool>(false);
      addTearDown(pageOpen.dispose);
      addTearDown(playerOpen.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: _CapsuleHandoverHost(
            pageOpen: pageOpen,
            playerOpen: playerOpen,
          ),
        ),
      );
      await tester.pump();

      // The page command owns the extension on its own.
      expect(_resetOpacity(tester), closeTo(1, .001));
      expect(find.byKey(_playerActionKey), findsNothing);

      // Opening the player hands the extension over: the command walks out
      // first, and the player's buttons only start arriving once it is gone.
      playerOpen.value = true;
      await tester.pump();
      await tester.pump();
      expect(
        _resetOpacity(tester),
        closeTo(1, .001),
        reason: 'the page command is the only set painting at the switch',
      );
      expect(
        _playerActionSettledOpacity(tester),
        lessThan(.02),
        reason: 'the arriving set may not paint over the command that is out',
      );

      await tester.pump(const Duration(milliseconds: 80));
      expect(
        _resetOpacity(tester),
        inExclusiveRange(.02, 1),
        reason: 'the command is on its way out',
      );
      expect(
        _playerActionSettledOpacity(tester),
        lessThan(.02),
        reason: 'the entrance may not start while the exit is still running',
      );

      // The exit is a spring, so the handover happens when it lands rather than
      // at a fixed boundary. Every frame of the exit keeps the arrival dark.
      for (var frame = 0; frame < 10; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
        if (_resetOpacity(tester) > .02) {
          expect(
            _playerActionSettledOpacity(tester),
            lessThan(.02),
            reason: 'the entrance follows the exit instead of overlapping it',
          );
        }
      }

      // Once the command is gone the player's buttons arrive on their own.
      await tester.pump(const Duration(milliseconds: 400));
      expect(_resetOpacity(tester), lessThan(.02));
      expect(_playerActionSettledOpacity(tester), closeTo(1, .02));
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );
}

/// Two action sets claiming one capsule, exactly as the font settings page and
/// the desktop player do when the player opens over the settings subview.
class _CapsuleHandoverHost extends StatefulWidget {
  const _CapsuleHandoverHost({
    required this.pageOpen,
    required this.playerOpen,
  });

  final ValueNotifier<bool> pageOpen;
  final ValueNotifier<bool> playerOpen;

  @override
  State<_CapsuleHandoverHost> createState() => _CapsuleHandoverHostState();
}

class _CapsuleHandoverHostState extends State<_CapsuleHandoverHost>
    with TickerProviderStateMixin {
  late final WindowChromeController _controller = WindowChromeController(
    vsync: this,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => WindowChromeScope(
    controller: _controller,
    inline: true,
    reveal: const AlwaysStoppedAnimation<double>(0),
    chromeTheme: Theme.of(context),
    child: Stack(
      children: [
        ValueListenableBuilder<bool>(
          valueListenable: widget.pageOpen,
          builder: (context, open, _) => open
              ? WindowChromeActions(
                  playerDriven: false,
                  leading: const Text('恢复默认', key: _resetKey),
                  children: const <Widget>[],
                )
              : const SizedBox.shrink(),
        ),
        ValueListenableBuilder<bool>(
          valueListenable: widget.playerOpen,
          builder: (context, open, _) => open
              ? const WindowChromeActions(
                  children: <Widget>[
                    Icon(Icons.search_rounded, key: _playerActionKey),
                  ],
                )
              : const SizedBox.shrink(),
        ),
      ],
    ),
  );
}

const _resetKey = ValueKey('handover-reset');
const _playerActionKey = ValueKey('handover-player-action');

double _paintedOpacity(WidgetTester tester, Key key) {
  final wrapper = find
      .ancestor(of: find.byKey(key), matching: find.byType(Opacity))
      .first;
  return tester.widget<Opacity>(wrapper).opacity;
}

double _resetOpacity(WidgetTester tester) => _paintedOpacity(tester, _resetKey);

/// The player action's painted opacity, or 0 while its set is off the capsule.
double _playerActionSettledOpacity(WidgetTester tester) {
  final action = find.byKey(_playerActionKey, skipOffstage: false);
  if (action.evaluate().isEmpty) return 0;
  return _paintedOpacity(tester, _playerActionKey);
}

class _TestSource extends ValueNotifier<bool> {
  _TestSource(super.value);

  bool get listening => hasListeners;
}

class _ChromeSourceBinding extends StatefulWidget {
  const _ChromeSourceBinding({required this.source});

  final ValueNotifier<bool> source;

  @override
  State<_ChromeSourceBinding> createState() => _ChromeSourceBindingState();
}

class _ChromeSourceBindingState extends State<_ChromeSourceBinding> {
  WindowChromeController? _controller;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final controller = WindowChromeScope.maybeOf(context);
    if (controller == _controller) return;
    _controller?.detach(widget.source);
    _controller = controller;
    controller?.attach(widget.source);
  }

  @override
  void dispose() {
    _controller?.detach(widget.source);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
