import 'support/music_gateway.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lazer_nextgen/data/audio_quality.dart';
import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/theme/apple_design.dart';
import 'package:lazer_nextgen/ui/pages.dart';
import 'package:lazer_nextgen/widgets/spring_buttons.dart';

const FixtureProfile _profile = FixtureProfile(userId: 7, nickname: '测试账户');

class _CookieGateway extends TestMusicGateway {
  @override
  Future<FixtureLoginStatus> fixtureLoginWithCookie(String cookie) async {
    sessionCookie = cookie;
    return const FixtureLoginStatus(profile: _profile);
  }
}

class _CookieCatalog extends Catalog {
  _CookieCatalog({super.gateway});

  @override
  Future<HomeFeed?> loadHome({int? userId}) async => null;

  @override
  Future<UserCollections> userCollections(int uid) async =>
      UserCollections.empty;

  @override
  Future<String?> audioUrlFor(
    Track track, {
    AudioQuality quality = AudioQuality.exhigh,
    bool Function()? isCancelled,
  }) async => null;

  @override
  Future<GatewayLyrics?> lyricsFor(Track track) async =>
      const GatewayLyrics(lrc: '');
}

Future<AppState> _pumpSettings(
  WidgetTester tester, {
  AppState? existing,
}) async {
  tester.view.physicalSize = const Size(1280, 4200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final AppState state = existing ?? AppState(catalog:_CookieCatalog(gateway:_CookieGateway()));
  addTearDown(state.dispose);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppleTheme(brightness: Brightness.dark),
      home: Scaffold(body: AppSettingsPage(state: state)),
    ),
  );
  await tester.pumpAndSettle();
  return state;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  testWidgets(
    'the account section offers a disabled cookie export while guest',
    (tester) async {
      await _pumpSettings(tester);

      expect(find.text('导出 Cookie'), findsOneWidget);
      expect(find.text('登录后可导出当前平台登录 Cookie'), findsOneWidget);
      final SpringOutlinedButton exportButton = tester.widget(
        find.byKey(const ValueKey('export-session-cookie')),
      );
      expect(exportButton.onPressed, isNull);
    },
  );

  testWidgets(
    'a signed-in account copies its session cookie to the clipboard',
    (tester) async {
      final List<String> copied = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (
            MethodCall call,
          ) async {
            if (call.method == 'Clipboard.setData') {
              final Map<Object?, Object?> data =
                  call.arguments as Map<Object?, Object?>;
              copied.add(data['text']! as String);
            }
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null),
      );

      final gateway = _CookieGateway();
      final state = AppState(catalog: _CookieCatalog(gateway: gateway));
      final bool signedIn = (await state.signInWithCookie(
        'MUSIC_U=fixture; __csrf=token',
      )).ok;
      expect(signedIn, isTrue);

      await _pumpSettings(tester, existing: state);
      final Finder exportButton = find.byKey(
        const ValueKey('export-session-cookie'),
      );
      await tester.ensureVisible(exportButton);
      await tester.pumpAndSettle();
      await tester.tap(exportButton);
      await tester.pumpAndSettle();

      expect(copied, <String>['MUSIC_U=fixture; __csrf=token']);
      expect(find.text('登录 Cookie 已复制到剪贴板。'), findsOneWidget);
    },
  );
}
