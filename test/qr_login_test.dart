import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lazer_nextgen/data/audio_quality.dart';
import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/gateway/gateway.dart';
import 'package:lazer_nextgen/legacy/legacy_login.dart';
import 'package:lazer_nextgen/legacy/legacy_theme.dart';
import 'package:lazer_nextgen/theme/font_preferences.dart';
import 'package:lazer_nextgen/state/app_state.dart';

const String _scanUrl = 'https://music.163.com/login?codekey=fixture-key';

const GatewayUserProfile _profile = GatewayUserProfile(
  userId: 7,
  nickname: '测试账户',
  vipType: 11,
);

/// Scripted QR authority: the key handshake, the poll codes in order, and the
/// account endpoint that may trail the confirmation.
class _QrGateway extends NeteaseGateway {
  _QrGateway({
    this.codes = const <int>[801],
    this.statuses = const <GatewayLoginStatus>[],
  });

  final List<int> codes;
  final List<GatewayLoginStatus> statuses;

  int polls = 0;
  int statusCalls = 0;
  final List<String> checkedKeys = <String>[];
  final List<String> captchas = <String>[];

  @override
  Future<String> createQrKey() async => 'fixture-key';

  @override
  Future<String> createQrCodeUrl(String key) async => _scanUrl;

  @override
  Future<GatewayQrCheck> checkQrCode(String key, {String secureCaptcha = ''}) async {
    checkedKeys.add(key);
    captchas.add(secureCaptcha);
    final int index = polls < codes.length ? polls : codes.length - 1;
    polls++;
    final int code = codes.isEmpty ? 801 : codes[index];
    if (code == 803) sessionCookie = 'MUSIC_U=fixture';
    return GatewayQrCheck(code: code, cookie: sessionCookie);
  }

  @override
  Future<GatewayLoginStatus> loginStatus() async {
    final int index = statusCalls < statuses.length
        ? statusCalls
        : statuses.length - 1;
    statusCalls++;
    if (statuses.isEmpty) return const GatewayLoginStatus();
    return statuses[index];
  }

  @override
  Future<Set<int>> likedSongIds(int uid) async => <int>{};
}

class _Catalog extends Catalog {
  _Catalog({super.gateway});
  @override
  Future<HomeFeed?> loadHome({int? userId}) async => null;
  @override
  Future<UserCollections> userCollections(int uid) async =>
      UserCollections.empty;
  @override
  Future<String?> audioUrlFor(Track track, {AudioQuality quality = AudioQuality.exhigh}) async => null;
  @override
  Future<GatewayLyrics?> lyricsFor(Track track) async =>
      const GatewayLyrics(lrc: '');
}

AppState _state(_QrGateway gateway) =>
    AppState(catalog: _Catalog(gateway: gateway));

/// Adopting a session fans out into unawaited refreshes; let them finish
/// before the test tears the state down.
Future<void> _flush() => Future<void>.delayed(Duration.zero);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('cookie input uses the selected system font', (tester) async {
    final state = _state(_QrGateway(codes: [801]));
    addTearDown(() async {
      await _flush();
      state.dispose();
    });
    await state.setFontFamily(
      const FontFamilyPreference(source: FontSource.system),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showLegacyLoginDialog(context, state),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('使用 Cookie 登录'));
    await tester.pump();
    expect(
      tester.widget<TextField>(find.byType(TextField)).style!.fontFamily,
      state.fontPreferences.family.resolvedFamily,
    );
    await tester.tap(find.byTooltip('取消'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  test('a waiting key keeps the poll at 801 and never signs in', () async {
    final gateway = _QrGateway(codes: <int>[801]);
    final state = _state(gateway);
    addTearDown(() async { await _flush(); state.dispose(); });
    final String? url = await state.beginQrLogin();
    expect(url, _scanUrl);
    expect(await state.pollQrLogin(url!), 801);
    expect(state.signedIn, isFalse);
    // The poll carries the key from the scan URL, not the whole URL.
    expect(gateway.checkedKeys, <String>['fixture-key']);
    expect(gateway.captchas, <String>['']);
    expect(state.qrPollError, isNull);
  });

  test(
    'a confirmed key retries the account endpoint before reporting the login',
    () async {
      final gateway = _QrGateway(
        codes: <int>[803],
        statuses: const <GatewayLoginStatus>[
          GatewayLoginStatus(),
          GatewayLoginStatus(profile: _profile),
        ],
      );
      final state = _state(gateway);
      addTearDown(() async { await _flush(); state.dispose(); });
      final String? url = await state.beginQrLogin();
      expect(await state.pollQrLogin(url!), 803);
      expect(gateway.statusCalls, greaterThan(1));
      expect(state.signedIn, isTrue);
      expect(state.user.method, AuthMethod.qrcode);
      expect(state.user.userId, 7);
      await _flush();
      expect(
        (await SharedPreferences.getInstance()).getString(
          'lazer_gateway_cookie',
        ),
        'MUSIC_U=fixture',
      );
    },
  );

  test('a spent key still adopts a confirmation the account lagged behind', () async {
    final gateway = _QrGateway(
      codes: <int>[803, 800],
      statuses: const <GatewayLoginStatus>[
        GatewayLoginStatus(),
        GatewayLoginStatus(),
        GatewayLoginStatus(),
        GatewayLoginStatus(profile: _profile),
      ],
    );
    final state = _state(gateway);
    addTearDown(() async { await _flush(); state.dispose(); });
    final String? url = await state.beginQrLogin();
    // First poll: confirmed, but the account is not ready yet.
    expect(await state.pollQrLogin(url!), 802);
    expect(state.signedIn, isFalse);
    // Second poll: the key is spent (800), the account is ready now.
    expect(await state.pollQrLogin(url), 803);
    expect(state.signedIn, isTrue);
  });

  test('a URL without a codekey reports expiry instead of polling', () async {
    final gateway = _QrGateway();
    final state = _state(gateway);
    addTearDown(() async { await _flush(); state.dispose(); });
    expect(
      await state.pollQrLogin('https://music.163.com/login'),
      800,
    );
    expect(gateway.polls, 0);
  });

  testWidgets('the QR panel closes the sign-in card once the scan confirms', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final gateway = _QrGateway(
      codes: <int>[801, 803],
      statuses: const <GatewayLoginStatus>[
        GatewayLoginStatus(profile: _profile),
      ],
    );
    final state = _state(gateway);
    addTearDown(() async { await _flush(); state.dispose(); });

    await tester.pumpWidget(
      AnimatedBuilder(
        animation: state,
        builder: (BuildContext context, _) => MaterialApp(
          theme: buildLegacyTheme(),
          home: Builder(
            builder: (BuildContext context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () => showLegacyLoginDialog(context, state),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump();
    // First poll answered "waiting": the card stays up with the QR code.
    // The dialog class is private to the legacy shell, so the cookie escape
    // hatch it always renders stands in for the widget type.
    expect(find.text('使用 Cookie 登录'), findsOneWidget);
    expect(state.signedIn, isFalse);

    // Second poll reports the confirmation.
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(state.signedIn, isTrue);
    expect(find.text('使用 Cookie 登录'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
