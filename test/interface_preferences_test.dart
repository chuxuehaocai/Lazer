import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lazer_nextgen/data/audio_quality.dart';
import 'package:lazer_nextgen/animation/apple_spring.dart';
import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/gateway/gateway.dart';
import 'package:lazer_nextgen/ui/pages.dart';
import 'package:lazer_nextgen/ui/player_bar.dart';
import 'package:lazer_nextgen/ui/shell.dart';
import 'package:lazer_nextgen/theme/apple_design.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/state/ui_preferences.dart';
import 'package:lazer_nextgen/widgets/ui_scaling.dart';

class _Gateway extends NeteaseGateway {
  @override
  Future<Set<int>> likedSongIds(int uid) async => <int>{};
}

class _Catalog extends Catalog {
  _Catalog() : super(gateway: _Gateway());
  @override
  Future<HomeFeed?> loadHome({int? userId}) async => null;
  @override
  Future<UserCollections> userCollections(int uid) async =>
      UserCollections.empty;
  @override
  Future<String?> audioUrlFor(
    Track track, {
    AudioQuality quality = AudioQuality.exhigh,
  }) async => null;
  @override
  Future<GatewayLyrics?> lyricsFor(Track track) async =>
      const GatewayLyrics(lrc: '');
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('ui preferences', () {
    test('animation speed snaps and rescales spring durations', () {
      final base = AppleSpring.smooth.duration;
      MotionTiming.speed = 1.54;
      expect(MotionTiming.speed, 1.5);
      expect(
        AppleSpring.smooth.duration,
        Duration(microseconds: (base.inMicroseconds / 1.5).round()),
      );
      MotionTiming.speed = 9;
      expect(MotionTiming.speed, MotionTiming.maxSpeed);
      MotionTiming.speed = MotionTiming.defaultSpeed;
    });

    test('animation speed persists and restores the runtime scale', () async {
      final state = AppState(catalog: _Catalog());
      addTearDown(state.dispose);
      await state.setAnimationSpeed(1.4);
      expect(state.animationSpeed, closeTo(1.4, 1e-12));
      expect(MotionTiming.speed, closeTo(1.4, 1e-12));

      final restored = AppState(catalog: _Catalog());
      addTearDown(restored.dispose);
      expect(MotionTiming.speed, MotionTiming.defaultSpeed);
      await restored.bootstrap();
      expect(restored.animationSpeed, closeTo(1.4, 1e-12));
      expect(MotionTiming.speed, closeTo(1.4, 1e-12));
      await restored.resetAnimationSpeed();
      expect(MotionTiming.speed, MotionTiming.defaultSpeed);
    });

    test('dpi scale snaps to five-percent steps inside the slider range', () {
      expect(normalizeDpiScale(1), 1);
      expect(normalizeDpiScale(1.26), 1.25);
      expect(normalizeDpiScale(1.24), 1.25);
      expect(normalizeDpiScale(0.1), kDpiScaleMin);
      expect(normalizeDpiScale(9), kDpiScaleMax);
      expect(normalizeDpiScale(double.nan), kDpiScaleDefault);
      expect(normalizeDpiScale(double.infinity), kDpiScaleDefault);
    });

    test('the forced layout ignores the window width', () {
      expect(useCompactLayout(AppUiMode.auto, 700), isTrue);
      expect(useCompactLayout(AppUiMode.auto, kCompactBreakpoint), isFalse);
      expect(useCompactLayout(AppUiMode.desktop, 320), isFalse);
      expect(useCompactLayout(AppUiMode.mobile, 1920), isTrue);
      expect(AppUiModeLabels.parse('mobile'), AppUiMode.mobile);
      expect(AppUiModeLabels.parse('nope'), AppUiMode.auto);
      expect(AppUiModeLabels.parse(null), AppUiMode.auto);
    });

    test('the automatic scale only grows large workspaces', () {
      expect(dpiScaleForWorkspace(const Size(1920, 1080)), 1);
      expect(dpiScaleForWorkspace(const Size(1280, 800)), 1);
      expect(dpiScaleForWorkspace(const Size(1366, 768)), 1);
      expect(
        dpiScaleForWorkspace(const Size(2560, 1440)),
        closeTo(1.35, .0001),
      );
      expect(dpiScaleForWorkspace(const Size(3840, 2160)), kAutoDpiScaleMax);
      expect(dpiScaleForWorkspace(Size.zero), kDpiScaleDefault);
    });

    test('a head unit is a low-density landscape Android panel', () {
      bool detect({
        TargetPlatform platform = TargetPlatform.android,
        Size size = const Size(1280, 720),
        double dpr = 1,
      }) => looksLikeCarDisplay(
        platform: platform,
        physicalSize: size,
        devicePixelRatio: dpr,
      );

      // Typical 720p and 1080p head units, including wide short panels.
      expect(detect(), isTrue);
      expect(detect(size: const Size(1920, 720)), isTrue);
      expect(detect(size: const Size(1024, 600)), isTrue);
      // Phones report a high density, tablets and portrait panels are excluded.
      expect(detect(dpr: 2.75), isFalse);
      expect(detect(size: const Size(720, 1280)), isFalse);
      expect(detect(size: const Size(800, 480)), isFalse);
      // A window on a desktop says nothing about the display behind it.
      expect(detect(platform: TargetPlatform.windows), isFalse);
      expect(detect(platform: TargetPlatform.linux), isFalse);
      expect(detect(platform: TargetPlatform.iOS, dpr: 3), isFalse);
      expect(detect(dpr: 0), isFalse);
    });

    test('the device form decides whether the car profile applies', () {
      expect(carSurfaceActive(AppSurface.auto, detected: true), isTrue);
      expect(carSurfaceActive(AppSurface.auto, detected: false), isFalse);
      expect(
        carSurfaceActive(AppSurface.car, detected: false),
        isTrue,
        reason: 'an explicit choice wins over detection',
      );
      expect(carSurfaceActive(AppSurface.standard, detected: true), isFalse);
      expect(AppSurfaceLabels.parse('car'), AppSurface.car);
      expect(AppSurfaceLabels.parse('standard'), AppSurface.standard);
      expect(AppSurfaceLabels.parse('nope'), AppSurface.auto);
    });

    test('the car profile floors the scale at its minimum', () {
      expect(dpiScaleFloor(car: true), kCarScaleMin);
      expect(dpiScaleFloor(car: false), kDpiScaleMin);
      expect(profileDpiScale(1, floor: kCarScaleMin), kCarScaleMin);
      expect(profileDpiScale(kCarScaleMin, floor: kCarScaleMin), kCarScaleMin);
      expect(profileDpiScale(1.5, floor: kCarScaleMin), 1.5);
      expect(profileDpiScale(9, floor: kCarScaleMin), kDpiScaleMax);
      expect(profileDpiScale(1, floor: kDpiScaleMin), 1);
    });

    test(
      'a television overrides the car heuristic and keeps the standard floor',
      () {
        // The television profile is explicit or detected from Leanback.
        expect(tvSurfaceActive(AppSurface.tv, detected: false), isTrue);
        expect(tvSurfaceActive(AppSurface.auto, detected: true), isTrue);
        expect(tvSurfaceActive(AppSurface.auto, detected: false), isFalse);
        expect(tvSurfaceActive(AppSurface.car, detected: true), isFalse);
        expect(tvSurfaceActive(AppSurface.standard, detected: true), isFalse);
        expect(AppSurfaceLabels.parse('tv'), AppSurface.tv);
        expect(AppSurfaceLabels.parse('car'), AppSurface.car);

        // Density and input are separate: 自动 picks TV before the car guess.
        expect(
          resolveDeviceProfile(AppSurface.auto, television: true, car: true),
          DeviceProfile.tv,
        );
        expect(
          resolveDeviceProfile(AppSurface.auto, television: false, car: true),
          DeviceProfile.car,
        );
        expect(
          resolveDeviceProfile(AppSurface.auto, television: false, car: false),
          DeviceProfile.standard,
        );
        expect(
          resolveDeviceProfile(AppSurface.car, television: true, car: true),
          DeviceProfile.car,
          reason: 'an explicit choice still wins',
        );
        expect(
          resolveDeviceProfile(
            AppSurface.standard,
            television: true,
            car: false,
          ),
          DeviceProfile.standard,
        );
        // Density keeps the standard floor; only the input model is TV-specific.
        expect(dpiScaleFloor(car: false), kDpiScaleMin);
        expect(profileDpiScale(1, floor: kDpiScaleMin), 1);
      },
    );

    test('layout and dpi choices persist and reset together', () async {
      final state = AppState(catalog: _Catalog());
      addTearDown(state.dispose);
      await state.setUiMode(AppUiMode.mobile);
      await state.setDpiScale(1.3);
      expect(state.dpiScale, 1.3);
      expect(
        state.autoDpiScale,
        isFalse,
        reason: 'dragging the slider is a manual choice',
      );
      await state.setAutoDpiScale(true);

      final restarted = AppState(catalog: _Catalog());
      addTearDown(restarted.dispose);
      await restarted.bootstrap();
      expect(restarted.uiMode, AppUiMode.mobile);
      expect(restarted.dpiScale, 1.3);
      expect(restarted.autoDpiScale, isTrue);

      await restarted.resetDpiScale();
      expect(restarted.dpiScale, kDpiScaleDefault);
      expect(restarted.autoDpiScale, isTrue);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getDouble('lazer_dpi_scale'), kDpiScaleDefault);
      expect(prefs.getBool('lazer_auto_dpi_scale'), isTrue);
    });
  });

  testWidgets('ui scaling lays the interface out at workspace / scale', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final state = AppState(catalog: _Catalog())
      ..surface = AppSurface.standard
      ..autoDpiScale = false
      ..dpiScale = 1.25;
    addTearDown(state.dispose);

    Size? laidOut;
    Size? media;
    double? published;
    double? auto;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppleTheme(),
        home: UiScaling(
          state: state,
          child: Scaffold(
            body: LayoutBuilder(
              builder: (BuildContext context, BoxConstraints constraints) {
                laidOut = constraints.biggest;
                media = MediaQuery.sizeOf(context);
                published = UiMetrics.scaleOf(context);
                auto = UiMetrics.autoScaleOf(context);
                return const SizedBox.expand();
              },
            ),
          ),
        ),
      ),
    );
    expect(laidOut, const Size(800, 640));
    expect(media, const Size(800, 640));
    expect(published, 1.25);
    expect(auto, kDpiScaleDefault);
    // The paint transform restores the original window size.
    final Transform transform = tester.widget<Transform>(
      find.byType(Transform).first,
    );
    expect(transform.transform.getMaxScaleOnAxis(), 1.25);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a scale below 1x still covers the whole window', (tester) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final state = AppState(catalog: _Catalog())
      ..surface = AppSurface.standard
      ..autoDpiScale = false
      ..dpiScale = .8;
    addTearDown(state.dispose);

    Size? laidOut;
    bool tappedCorner = false;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppleTheme(),
        home: UiScaling(
          state: state,
          child: Scaffold(
            body: LayoutBuilder(
              builder: (BuildContext context, BoxConstraints constraints) {
                laidOut = constraints.biggest;
                return Stack(
                  children: <Widget>[
                    const Positioned.fill(
                      child: SizedBox.expand(
                        key: ValueKey<String>('scaled-page'),
                      ),
                    ),
                    Positioned(
                      right: 0,
                      bottom: 0,
                      width: 200,
                      height: 80,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => tappedCorner = true,
                        child: const SizedBox.expand(),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );

    // The workspace is the window divided by the scale: below 1x it is larger.
    expect(laidOut, const Size(1600, 900));
    // Painted through the transform, it lands exactly on the window instead of
    // a corner of it.
    final Rect painted = tester.getRect(
      find.byKey(const ValueKey<String>('scaled-page')),
    );
    expect(painted.left, closeTo(0, .01));
    expect(painted.top, closeTo(0, .01));
    expect(painted.width, closeTo(1280, .01));
    expect(painted.height, closeTo(720, .01));
    // And the bottom-right corner of the window is still a live hit target.
    await tester.tapAt(const Offset(1276, 716));
    expect(tappedCorner, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a sub-1x scale fills the shell window', (tester) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final state = AppState(catalog: _Catalog())
      ..autoDpiScale = false
      ..dpiScale = .8;
    addTearDown(state.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppleTheme(),
        builder: (BuildContext context, Widget? child) =>
            UiScaling(state: state, child: child!),
        home: AppShell(state: state),
      ),
    );
    await tester.pump(const Duration(milliseconds: 200));

    // The bar sits on the window's bottom edge, not on the edge of an
    // 80%-sized copy floating in the corner.
    final Rect bar = tester.getRect(find.byType(AppPlayerBar));
    expect(bar.left, closeTo(0, .5));
    expect(bar.width, closeTo(1280, .5));
    expect(bar.bottom, closeTo(720, .5));
    expect(tester.takeException(), isNull);
  });

  testWidgets('1x leaves the subtree untouched', (tester) async {
    tester.view.physicalSize = const Size(900, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final state = AppState(catalog: _Catalog())
      ..surface = AppSurface.standard
      ..autoDpiScale = false;
    addTearDown(state.dispose);
    Size? laidOut;
    BuildContext? probe;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppleTheme(),
        home: UiScaling(
          state: state,
          child: Scaffold(
            body: LayoutBuilder(
              builder: (BuildContext context, BoxConstraints constraints) {
                laidOut = constraints.biggest;
                probe = context;
                return const SizedBox.expand();
              },
            ),
          ),
        ),
      ),
    );
    expect(laidOut, const Size(900, 700));
    expect(UiMetrics.scaleOf(probe!), 1);
    expect(UiMetrics.autoScaleOf(probe!), kDpiScaleDefault);
  });

  testWidgets('the legacy settings drive device form, layout and dpi scale', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final state = AppState(catalog: _Catalog());
    addTearDown(state.dispose);
    await tester.pumpWidget(
      AnimatedBuilder(
        animation: state,
        builder: (BuildContext context, _) => MaterialApp(
          theme: buildAppleTheme(),
          builder: (BuildContext context, Widget? child) =>
              UiScaling(state: state, child: child!),
          home: Scaffold(body: AppSettingsPage(state: state)),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Layout dropdown: the forced modes are the three documented choices.
    final layoutDropdown = find.byType(DropdownButton<AppUiMode>);
    expect(layoutDropdown, findsOneWidget);
    await tester.tap(layoutDropdown);
    await tester.pumpAndSettle();
    expect(find.text('强制桌面端'), findsOneWidget);
    await tester.tap(find.text('强制移动端').last);
    await tester.pumpAndSettle();
    expect(state.uiMode, AppUiMode.mobile);
    expect(
      (await SharedPreferences.getInstance()).getString('lazer_ui_mode'),
      'mobile',
    );

    // Dragging the slider pins a manual scale and turns the auto mode off.
    expect(state.autoDpiScale, isTrue);
    final dpiSlider = find.descendant(
      of: find.byKey(const ValueKey('dpi-scale-slider')),
      matching: find.byType(Slider),
    );
    await tester.drag(dpiSlider, const Offset(60, 0));
    await tester.pumpAndSettle();
    expect(state.autoDpiScale, isFalse);
    expect(state.dpiScale, greaterThan(1));

    // The switch works in both directions.
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('auto-dpi-switch')),
        matching: find.byType(Switch),
      ),
    );
    await tester.pumpAndSettle();
    expect(state.autoDpiScale, isTrue);
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('auto-dpi-switch')),
        matching: find.byType(Switch),
      ),
    );
    await tester.pumpAndSettle();
    expect(state.autoDpiScale, isFalse);

    // Device form: choosing the car raises the floor the slider may reach.
    expect(tester.widget<Slider>(dpiSlider).min, kDpiScaleMin);
    final surfaceDropdown = find.byType(DropdownButton<AppSurface>);
    await tester.tap(surfaceDropdown);
    await tester.pumpAndSettle();
    await tester.tap(find.text('车机').last);
    await tester.pumpAndSettle();
    expect(state.surface, AppSurface.car);
    expect(
      (await SharedPreferences.getInstance()).getString('lazer_surface'),
      'car',
    );
    expect(UiMetrics.carOf(tester.element(surfaceDropdown)), isTrue);
    expect(find.textContaining('车机形态已把界面放大到'), findsOneWidget);
    expect(tester.widget<Slider>(dpiSlider).min, kCarScaleMin);
    expect(
      tester.widget<Slider>(dpiSlider).value,
      greaterThanOrEqualTo(kCarScaleMin),
    );

    // The floor holds whatever the manual value is: the applied scale can
    // never fall back to desktop density on a head unit.
    BuildContext settingsContext = tester.element(surfaceDropdown);
    expect(UiMetrics.scaleOf(settingsContext), kCarScaleMin);
    await state.setDpiScale(0.9);
    await tester.pumpAndSettle();
    settingsContext = tester.element(surfaceDropdown);
    expect(state.dpiScale, 0.9);
    expect(
      UiMetrics.scaleOf(settingsContext),
      kCarScaleMin,
      reason: 'the car floor overrides a smaller manual value',
    );
    expect(tester.widget<Slider>(dpiSlider).value, kCarScaleMin);
    expect(find.text('135%'), findsWidgets);

    // 大屏幕模式 keeps the standard density: no car-style floor is applied,
    // while the remote input model is layered on top.
    await tester.tap(surfaceDropdown);
    await tester.pumpAndSettle();
    await tester.tap(find.text('大屏幕模式').last);
    await tester.pumpAndSettle();
    expect(state.surface, AppSurface.tv);
    expect(UiMetrics.tvOf(tester.element(surfaceDropdown)), isTrue);
    expect(find.textContaining('车机形态已把界面放大到'), findsNothing);
    expect(tester.widget<Slider>(dpiSlider).min, kDpiScaleMin);
    settingsContext = tester.element(surfaceDropdown);
    expect(
      UiMetrics.scaleOf(settingsContext),
      0.9,
      reason: 'the manual scale survives; television adds no floor',
    );

    // Reset returns to the shipped 100% default, and standard restores 80%.
    await tester.tap(find.byKey(const ValueKey('dpi-scale-reset')));
    await tester.pumpAndSettle();
    expect(state.dpiScale, kDpiScaleDefault);
    expect(state.autoDpiScale, isTrue);

    final speedSlider = find.descendant(
      of: find.byKey(const ValueKey('animation-speed-slider')),
      matching: find.byType(Slider),
    );
    expect(tester.widget<Slider>(speedSlider).min, MotionTiming.minSpeed);
    expect(tester.widget<Slider>(speedSlider).max, MotionTiming.maxSpeed);
    expect(tester.widget<Slider>(speedSlider).value, MotionTiming.defaultSpeed);
    await tester.drag(speedSlider, const Offset(80, 0));
    await tester.pumpAndSettle();
    expect(state.animationSpeed, greaterThan(1));
    expect(MotionTiming.speed, state.animationSpeed);
    expect(
      (await SharedPreferences.getInstance()).getDouble(
        AppState.animationSpeedKey,
      ),
      state.animationSpeed,
    );
    await tester.tap(find.byKey(const ValueKey('animation-speed-reset')));
    await tester.pumpAndSettle();
    expect(state.animationSpeed, MotionTiming.defaultSpeed);
    expect(MotionTiming.speed, MotionTiming.defaultSpeed);

    await tester.tap(surfaceDropdown);
    await tester.pumpAndSettle();
    await tester.tap(find.text('标准').last);
    await tester.pumpAndSettle();
    settingsContext = tester.element(surfaceDropdown);
    expect(UiMetrics.carOf(settingsContext), isFalse);
    expect(tester.widget<Slider>(dpiSlider).min, kDpiScaleMin);
    expect(tester.takeException(), isNull);
  });
}
