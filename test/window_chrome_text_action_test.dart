import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lazer_nextgen/audio/audio_engine.dart';
import 'package:lazer_nextgen/audio/system_media_handler.dart';
import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/l10n/app_localizations.dart';
import 'package:lazer_nextgen/main.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/state/ui_preferences.dart';
import 'package:lazer_nextgen/ui/widgets.dart';

import 'support/music_gateway.dart';

class _State extends AppState {
  _State() : super(catalog: Catalog(gateway: TestMusicGateway())) {
    autoDpiScale = false;
    layoutStyle = AppLayoutStyle.desktop;
    titleBarStyle = DesktopTitleBarStyle.inline;
  }

  @override
  Future<void> bootstrap() async {}

  @override
  bool get autoUpdateCheckDue => false;

  @override
  HomeFeed get home => const HomeFeed(
    featuredTracks: [],
    quick: [],
    daily: [],
    playlists: [],
    recommended: [],
    albums: [],
  );
}

class _UnusedAudio extends Fake implements AudioEngine {
  @override
  void dispose() {}
}

Future<void> _hover(WidgetTester tester, Finder finder) async {
  final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await gesture.addPointer(location: Offset.zero);
  await tester.pump();
  await gesture.moveTo(tester.getCenter(finder));
  await tester.pumpAndSettle();
  // Removed before returning: the tracker asserts that a device is added only
  // when the previous event for it was a removal.
  await gesture.removePointer();
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<AppState> openManager(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('window_manager'),
      (call) async => call.method.startsWith('is') ? false : null,
    );
    await tester.runAsync(
      () => AppLocalizations.delegate.load(const Locale('en')),
    );
    final state = _State();
    await state.setIndependentPlayback(true);
    await tester.pumpWidget(
      LazerApp(
        state: state,
        audio: _UnusedAudio(),
        media: SystemMediaController(state),
        windowFrameEnabled: true,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byWidgetPredicate(
        (widget) => widget is AppRailItem && widget.label == '设置',
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Accounts & extensions'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('open-plugin-manager')).first);
    await tester.pumpAndSettle();
    return state;
  }

  testWidgets('capsule text commands hover like the player top bar', (
    tester,
  ) async {
    await openManager(tester);

    final market = find.byWidgetPredicate(
      (widget) => widget is TrText && widget.data == '插件市场',
    );
    expect(market, findsOneWidget);
    final context = tester.element(market);
    final style = TextButtonTheme.of(context).style!;
    final scheme = Theme.of(context).colorScheme;

    // One hover language for the capsule: the player's icon buttons paint the
    // same fill, in the same square shape, on the same 40 dp band.
    expect(
      style.backgroundColor!.resolve(<WidgetState>{WidgetState.hovered}),
      scheme.onSurface.withValues(alpha: .07),
    );
    expect(
      style.backgroundColor!.resolve(<WidgetState>{WidgetState.pressed}),
      scheme.onSurface.withValues(alpha: .13),
    );
    expect(
      style.backgroundColor!.resolve(<WidgetState>{}),
      scheme.onSurface.withValues(alpha: 0),
    );
    expect(
      (style.shape!.resolve(<WidgetState>{})! as RoundedRectangleBorder)
          .borderRadius,
      BorderRadius.zero,
    );
    expect(style.minimumSize!.resolve(<WidgetState>{})!.height, 40);
    expect(
      style.textStyle!.resolve(<WidgetState>{})!.fontWeight,
      FontWeight.w600,
      reason: 'the capsule commands carry more weight than page buttons',
    );
    expect(
      style.overlayColor!.resolve(<WidgetState>{WidgetState.hovered}),
      Colors.transparent,
      reason: 'one fill, not a fill plus a ripple',
    );

    await _hover(tester, market);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('hovering the market commands throws nothing', (tester) async {
    await openManager(tester);

    await tester.tap(
      find.byWidgetPredicate(
        (widget) => widget is TrText && widget.data == '插件市场',
      ),
    );
    await tester.pumpAndSettle();

    final capsule = find.byKey(const ValueKey('settings-capsule-actions'));
    expect(capsule, findsOneWidget);
    // A Tooltip opens a second overlay portal inside the one the capsule paints
    // through, which is what tripped the overlay theater's depth assertion the
    // moment the pointer reached these buttons.
    expect(
      find.descendant(of: capsule, matching: find.byType(Tooltip)),
      findsNothing,
    );

    final buttons = find.descendant(
      of: capsule,
      matching: find.byType(IconButton),
    );
    expect(buttons, findsNWidgets(2));
    await _hover(tester, buttons.first);
    expect(tester.takeException(), isNull);
    await _hover(tester, buttons.last);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}
