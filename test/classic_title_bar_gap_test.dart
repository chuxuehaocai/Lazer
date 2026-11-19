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
import 'package:lazer_nextgen/widgets/apple_ui.dart';

import 'support/music_gateway.dart';

class _State extends AppState {
  _State({required this.desktopTitleBar})
    : super(catalog: Catalog(gateway: TestMusicGateway())) {
    autoDpiScale = false;
    layoutStyle = AppLayoutStyle.desktop;
    titleBarStyle = desktopTitleBar;
  }

  final DesktopTitleBarStyle desktopTitleBar;

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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  /// Opens 设置 → 账户与扩展 and reports where the page title starts relative to
  /// the bottom of its floating back control.
  Future<double> gapBelowBack(
    WidgetTester tester,
    DesktopTitleBarStyle style,
  ) async {
    tester.view.physicalSize = const Size(1354, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('window_manager'),
      (call) async => call.method.startsWith('is') ? false : null,
    );
    await tester.runAsync(
      () => AppLocalizations.delegate.load(const Locale('en')),
    );
    final state = _State(desktopTitleBar: style);
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

    final title = find.byWidgetPredicate(
      (widget) => widget is ApplePageTitle && widget.title == '账户与扩展',
    );
    final back = find.byKey(const ValueKey('settings-detail-back'));
    final gap = tester.getTopLeft(title).dy - tester.getRect(back).bottom;
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    return gap;
  }

  testWidgets('a classic title bar leaves the same gap as the floating capsule', (
    tester,
  ) async {
    final inlineGap = await gapBelowBack(tester, DesktopTitleBarStyle.inline);

    final classicGap = await gapBelowBack(tester, DesktopTitleBarStyle.classic);

    expect(
      classicGap,
      inlineGap,
      reason: 'the page must clear the back control the same way in both modes',
    );
    expect(
      classicGap,
      greaterThanOrEqualTo(8),
      reason: 'and keep breathing room under it',
    );
  });
}
