import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/state/ui_preferences.dart';
import 'package:lazer_nextgen/widgets/shared_browse_background.dart';
import 'package:lazer_nextgen/widgets/windows_backdrop.dart';

const _backdropChannel = MethodChannel('dev.naominet.lazer/window_backdrop');
const _windowChannel = MethodChannel('window_manager');

class _BackdropHarness {
  _BackdropHarness(this.tester) {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      _backdropChannel,
      (call) async {
        expect(call.method, 'setMica');
        final args = call.arguments as Map;
        final options = (args['enabled'] as bool, args['dark'] as bool);
        requests.add(options);
        return respond(options);
      },
    );
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      _windowChannel,
      (call) async {
        expect(call.method, 'setBackgroundColor');
        final args = call.arguments as Map;
        windowColors.add(
          Color.fromARGB(
            args['backgroundColorA'] as int,
            args['backgroundColorR'] as int,
            args['backgroundColorG'] as int,
            args['backgroundColorB'] as int,
          ),
        );
        return null;
      },
    );
  }

  final WidgetTester tester;
  final AppState state = AppState();
  final List<(bool, bool)> requests = [];
  final List<Color> windowColors = [];
  Future<bool?> Function((bool, bool)) respond = (options) async => options.$1;

  bool get active => tester
      .widget<WindowsBackdropScope>(find.byType(WindowsBackdropScope))
      .active;

  double get surfaceAlpha => tester
      .widget<ColoredBox>(
        find.descendant(
          of: find.byType(MicaSurface),
          matching: find.byType(ColoredBox),
        ),
      )
      .color
      .a;

  Future<void> mount({Brightness brightness = Brightness.light}) async {
    await tester.pumpWidget(
      Theme(
        data: ThemeData(brightness: brightness),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: WindowsBackdrop(state: state, child: const MicaSurface()),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> windowEvent(String name) async {
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      _windowChannel.name,
      const StandardMethodCodec().encodeMethodCall(
        MethodCall('onEvent', {'eventName': name}),
      ),
      (_) {},
    );
    await flushNativeReplies();
  }

  Future<void> flushNativeReplies() async {
    // Platform-event callbacks may complete outside the widget fake clock.
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
  }

  Future<void> presentPlayer(bool presented) async {
    state.playerPresentationChanged(presented);
    // In the app, pushing or popping the player also schedules a route frame.
    tester.binding.scheduleFrame();
    await tester.pumpAndSettle();
  }

  Future<void> dispose() async {
    // Unmount while the target platform override is still active, so the
    // WindowListener is removed before the next test starts.
    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      _backdropChannel,
      null,
    );
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      _windowChannel,
      null,
    );
  }
}

void _testBackdrop(
  String name,
  Future<void> Function(WidgetTester, _BackdropHarness) body, {
  TargetPlatformVariant? variant,
}) {
  testWidgets(name, (tester) async {
    final harness = _BackdropHarness(tester);
    try {
      await body(tester, harness);
    } finally {
      await harness.dispose();
    }
  }, variant: variant ?? TargetPlatformVariant.only(TargetPlatform.windows));
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  _testBackdrop(
    'Mica stays opaque and never calls native APIs on other platforms',
    (tester, harness) async {
      harness.state.backgroundMode = AppBackgroundMode.windowsMica;
      await harness.mount();
      expect(harness.requests, isEmpty);
      expect(harness.windowColors, isEmpty);
      expect(harness.active, isFalse);
      expect(harness.surfaceAlpha, 1);
    },
    variant: TargetPlatformVariant(
      TargetPlatform.values.where((p) => p != TargetPlatform.windows).toSet(),
    ),
  );

  _testBackdrop('successful Mica exposes the native backdrop', (
    tester,
    harness,
  ) async {
    harness.state.backgroundMode = AppBackgroundMode.windowsMica;
    await harness.mount();
    expect(harness.requests, [(true, false)]);
    expect(harness.windowColors, [Colors.transparent]);
    expect(harness.active, isTrue);
    expect(harness.surfaceAlpha, 0);
  });

  for (final failure in ['unsupported', 'missing plugin', 'platform error']) {
    _testBackdrop('$failure restores an opaque native and Flutter surface', (
      tester,
      harness,
    ) async {
      harness.state.backgroundMode = AppBackgroundMode.windowsMica;
      harness.respond = (_) async {
        if (failure == 'missing plugin') throw MissingPluginException();
        if (failure == 'platform error') {
          throw PlatformException(code: 'composition-unavailable');
        }
        return false;
      };
      await harness.mount();
      expect(harness.active, isFalse);
      expect(harness.surfaceAlpha, 1);
      expect(harness.windowColors, [Colors.transparent, Colors.white]);
    });
  }

  _testBackdrop('dark theme Mica failure uses a dark native fallback', (
    tester,
    harness,
  ) async {
    harness.state.backgroundMode = AppBackgroundMode.windowsMica;
    harness.respond = (_) async => false;
    await harness.mount(brightness: Brightness.dark);
    expect(harness.requests, [(true, true)]);
    expect(harness.windowColors, [Colors.transparent, Colors.black]);
    expect(harness.surfaceAlpha, 1);
  });

  _testBackdrop('player Mica is dark and closing restores light browsing', (
    tester,
    harness,
  ) async {
    harness.state.backgroundMode = AppBackgroundMode.windowsMica;
    harness.state.playerBackground = AppBackgroundMode.windowsMica;
    await harness.mount();

    await harness.presentPlayer(true);
    expect(harness.requests, [(true, false), (true, true)]);
    expect(harness.active, isTrue);

    await harness.presentPlayer(false);
    expect(harness.requests, [(true, false), (true, true), (true, false)]);

    // An unrelated preference update must not repeatedly reconfigure DWM.
    await harness.state.setAppUiAlpha(.6);
    await tester.pumpAndSettle();
    expect(harness.requests, hasLength(3));
  });

  _testBackdrop('a non-Mica player restores browsing Mica when closed', (
    tester,
    harness,
  ) async {
    harness.state.backgroundMode = AppBackgroundMode.windowsMica;
    harness.state.playerBackground = AppBackgroundMode.off;
    await harness.mount();

    await harness.presentPlayer(true);
    expect(harness.requests.last, (false, true));
    expect(harness.windowColors.last, Colors.black);
    expect(harness.active, isFalse);
    expect(harness.surfaceAlpha, 1);

    await harness.presentPlayer(false);
    expect(harness.requests.last, (true, false));
    expect(harness.windowColors.last, Colors.transparent);
    expect(harness.active, isTrue);
  });

  _testBackdrop('fullscreen transitions reapply the native frame', (
    tester,
    harness,
  ) async {
    final listenerCount = windowManager.listeners.length;
    harness.state.backgroundMode = AppBackgroundMode.windowsMica;
    await harness.mount();
    expect(windowManager.listeners, hasLength(listenerCount + 1));
    await harness.windowEvent('enter-full-screen');
    await harness.windowEvent('leave-full-screen');
    expect(harness.requests, [(true, false), (true, false), (true, false)]);
    expect(harness.active, isTrue);

    await tester.pumpWidget(const SizedBox.shrink());
    expect(windowManager.listeners, hasLength(listenerCount));
    await harness.windowEvent('leave-full-screen');
    expect(harness.requests, hasLength(3));
  });

  _testBackdrop('late Mica success cannot override a newer disabled choice', (
    tester,
    harness,
  ) async {
    harness.state.backgroundMode = AppBackgroundMode.off;
    await harness.mount();
    final enabled = Completer<bool>();
    final disabled = Completer<bool>();
    harness.respond = (options) =>
        options.$1 ? enabled.future : disabled.future;

    await harness.state.setAppBackground(AppBackgroundMode.windowsMica);
    await tester.pump();
    expect(harness.requests.last, (true, false));
    await harness.state.setAppBackground(AppBackgroundMode.off);
    await tester.pump();
    // Native operations are serialized while enabling is in flight.
    expect(harness.requests, [(false, false), (true, false)]);

    enabled.complete(true);
    await harness.flushNativeReplies();
    expect(harness.requests.last, (false, false));
    expect(harness.active, isFalse);
    expect(harness.surfaceAlpha, 1);
    expect(harness.windowColors.last, Colors.white);

    disabled.complete(false);
    await tester.pumpAndSettle();
    expect(harness.active, isFalse);
    expect(harness.surfaceAlpha, 1);
  });

  testWidgets('browsing Mica opacity is independent of content opacity', (
    tester,
  ) async {
    final state = AppState()
      ..backgroundMode = AppBackgroundMode.windowsMica
      ..backgroundOpacity = .35;
    final navigation = BrowseNavigationObserver();
    try {
      await tester.pumpWidget(
        Theme(
          data: ThemeData.light(),
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: WindowsBackdropScope(
              active: true,
              child: SharedBrowseBackground(
                state: state,
                navigation: navigation,
                child: const SizedBox.shrink(),
              ),
            ),
          ),
        ),
      );
      double surfaceAlpha() => tester
          .widget<ColoredBox>(
            find.descendant(
              of: find.byType(MicaSurface),
              matching: find.byType(ColoredBox),
            ),
          )
          .color
          .a;
      expect(surfaceAlpha(), closeTo(.65, .001));
      await state.setAppUiAlpha(.4);
      await tester.pumpAndSettle();
      expect(surfaceAlpha(), closeTo(.65, .001));
      expect(
        tester
            .widget<Opacity>(
              find.byKey(const ValueKey('browse-content-opacity')),
            )
            .opacity,
        .4,
      );
      await state.setBackgroundOpacity(.8);
      await tester.pumpAndSettle();
      expect(surfaceAlpha(), closeTo(.2, .001));
      expect(state.uiAlpha, .4);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      navigation.dispose();
      state.dispose();
    }
  });
}
