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
import 'package:lazer_nextgen/widgets/window_chrome_surface.dart';

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

/// Where the page title of [title] starts, measured from the top of the window.
double _titleTop(WidgetTester tester, String title) => tester
    .getTopLeft(
      find.byWidgetPredicate(
        (widget) => widget is ApplePageTitle && widget.title == title,
      ),
    )
    .dy;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('the plugin pages keep the settings pages top gap', (
    tester,
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

    // Any settings category page is the reference: it clears the floating back
    // control and then adds its own title spacing.
    final reference = _titleTop(tester, '账户与扩展');
    expect(reference, greaterThan(kWindowChromeTop + kWindowChromeHeight));

    final open = find.byKey(const ValueKey('open-plugin-manager'));
    await tester.ensureVisible(open.first);
    await tester.pumpAndSettle();
    await tester.tap(open.first, warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(
      _titleTop(tester, '插件管理'),
      reference,
      reason: 'the manager starts where every other settings subview does',
    );

    await tester.tap(find.byKey(const ValueKey('plugin-market-action')));
    await tester.pumpAndSettle();
    expect(
      _titleTop(tester, '插件市场'),
      reference,
      reason: 'and so does the market',
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}
