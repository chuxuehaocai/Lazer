import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lazer_nextgen/data/audio_quality.dart';
import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/gateway/gateway.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/theme/apple_design.dart';
import 'package:lazer_nextgen/ui/login.dart';

const String _scanUrl = 'https://music.163.com/login?codekey=fixture-key';

const GatewayUserProfile _profile = GatewayUserProfile(
  userId: 7,
  nickname: '测试账户',
  vipType: 11,
);

/// Scripted password authority: the QR handshake the card mounts with, plus
/// the phone and email password calls the card can make.
class _PasswordGateway extends NeteaseGateway {
  final List<(String, String, String)> phoneLogins =
      <(String, String, String)>[];
  final List<(String, String)> emailLogins = <(String, String)>[];

  @override
  Future<String> createQrKey() async => 'fixture-key';

  @override
  Future<String> createQrCodeUrl(String key) async => _scanUrl;

  @override
  Future<GatewayQrCheck> checkQrCode(
    String key, {
    String secureCaptcha = '',
  }) async => const GatewayQrCheck(code: 801);

  @override
  Future<GatewayLoginResult> loginWithPhonePassword(
    String phone,
    String password, {
    String countryCode = '86',
    String? sliderToken,
  }) async {
    phoneLogins.add((countryCode, phone, password));
    sessionCookie = 'MUSIC_U=fixture';
    return const GatewayLoginResult(
      code: 200,
      cookie: 'MUSIC_U=fixture',
      profile: _profile,
      account: GatewayAccount(id: 7),
    );
  }

  @override
  Future<GatewayLoginResult> loginWithEmail(
    String email,
    String password,
  ) async {
    emailLogins.add((email, password));
    sessionCookie = 'MUSIC_U=fixture';
    return const GatewayLoginResult(
      code: 200,
      cookie: 'MUSIC_U=fixture',
      profile: _profile,
      account: GatewayAccount(id: 7),
    );
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
  Future<String?> audioUrlFor(
    Track track, {
    AudioQuality quality = AudioQuality.exhigh,
  }) async => null;
  @override
  Future<GatewayLyrics?> lyricsFor(Track track) async =>
      const GatewayLyrics(lrc: '');
}

AppState _state(_PasswordGateway gateway) =>
    AppState(catalog: _Catalog(gateway: gateway));

/// Adopting a session fans out into unawaited refreshes; let them finish
/// before the test tears the state down.
Future<void> _flush() => Future<void>.delayed(Duration.zero);

Future<void> _openCard(WidgetTester tester, AppState state) async {
  await tester.pumpWidget(
    AnimatedBuilder(
      animation: state,
      builder: (BuildContext context, _) => MaterialApp(
        theme: buildAppleTheme(),
        home: Builder(
          builder: (BuildContext context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => showAppLoginDialog(context, state),
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
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'email sign-in uses the mail endpoint and keeps a masked detail',
    () async {
      final gateway = _PasswordGateway();
      final state = _state(gateway);
      addTearDown(() async {
        await _flush();
        state.dispose();
      });

      final AuthOutcome outcome = await state.signInWithPassword(
        'listener@example.com',
        'hunter2',
      );

      expect(outcome.ok, isTrue);
      expect(gateway.emailLogins, <(String, String)>[
        ('listener@example.com', 'hunter2'),
      ]);
      expect(gateway.phoneLogins, isEmpty);
      expect(state.signedIn, isTrue);
      expect(state.user.method, AuthMethod.password);
      expect(state.user.detail, 'li***@example.com');
    },
  );

  test('phone sign-in uses the cellphone endpoint with +86', () async {
    final gateway = _PasswordGateway();
    final state = _state(gateway);
    addTearDown(() async {
      await _flush();
      state.dispose();
    });

    final AuthOutcome outcome = await state.signInWithPassword(
      '13800000000',
      'secret',
    );

    expect(outcome.ok, isTrue);
    expect(gateway.phoneLogins, <(String, String, String)>[
      ('86', '13800000000', 'secret'),
    ]);
    expect(gateway.emailLogins, isEmpty);
    expect(state.user.detail, '138****0000');
  });

  test('blank account and password never reach the gateway', () async {
    final gateway = _PasswordGateway();
    final state = _state(gateway);
    addTearDown(() async {
      await _flush();
      state.dispose();
    });

    expect((await state.signInWithPassword('', 'secret')).error, '请输入手机号或邮箱。');
    expect(
      (await state.signInWithPassword('listener@example.com', '')).error,
      '请输入密码。',
    );
    expect(gateway.emailLogins, isEmpty);
    expect(gateway.phoneLogins, isEmpty);
  });

  testWidgets('the password form signs in with an email account', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final gateway = _PasswordGateway();
    final state = _state(gateway);
    addTearDown(() async {
      await _flush();
      state.dispose();
    });

    await _openCard(tester, state);
    await tester.tap(find.text('密码登录'));
    await tester.pump();

    expect(find.byType(TextField), findsNWidgets(2));
    await tester.enterText(
      find.byKey(const ValueKey('login-password-account')),
      'listener@example.com',
    );
    await tester.enterText(
      find.byKey(const ValueKey('login-password-password')),
      'hunter2',
    );
    await tester.tap(find.byKey(const ValueKey('login-password-submit')));
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(gateway.emailLogins, <(String, String)>[
      ('listener@example.com', 'hunter2'),
    ]);
    expect(state.signedIn, isTrue);
    expect(find.text('忘记密码？'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the password form rejects a malformed email before sign-in', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final gateway = _PasswordGateway();
    final state = _state(gateway);
    addTearDown(() async {
      await _flush();
      state.dispose();
    });

    await _openCard(tester, state);
    await tester.tap(find.text('密码登录'));
    await tester.pump();
    await tester.enterText(
      find.byKey(const ValueKey('login-password-account')),
      'listener@',
    );
    await tester.enterText(
      find.byKey(const ValueKey('login-password-password')),
      'hunter2',
    );
    await tester.tap(find.byKey(const ValueKey('login-password-submit')));
    await tester.pump();

    expect(gateway.emailLogins, isEmpty);
    expect(find.text('邮箱格式不正确。'), findsOneWidget);
    expect(state.signedIn, isFalse);
  });
}
