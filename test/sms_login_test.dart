import 'support/music_gateway.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lazer_nextgen/data/audio_quality.dart';
import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/ui/login.dart';
import 'package:lazer_nextgen/theme/apple_design.dart';
import 'package:lazer_nextgen/state/app_state.dart';

const String _scanUrl = 'https://music.163.com/login?codekey=fixture-key';

const FixtureProfile _profile = FixtureProfile(
  userId: 7,
  nickname: '测试账户',
  vipType: 11,
);

/// Scripted SMS authority: the QR handshake the card mounts with, the code
/// send call, and the captcha login that hands back the session cookie.
class _SmsGateway extends TestMusicGateway {
  final List<String> sentPhones = <String>[];
  final List<(String, String)> logins = <(String, String)>[];

  @override
  Future<String> createQrKey() async => 'fixture-key';

  @override
  Future<String> createQrCodeUrl(String key) async => _scanUrl;

  @override
  Future<FixtureQrCheck> checkQrCode(
    String key, {
    String secureCaptcha = '',
  }) async => const FixtureQrCheck(code: 801);

  @override
  Future<void> fixtureSendCaptcha(
    String phone, {
    String countryCode = '86',
  }) async {
    sentPhones.add('$countryCode:$phone');
  }

  @override
  Future<FixtureLoginResult> fixturePhoneCaptcha(
    String phone,
    String captcha, {
    String countryCode = '86',
    String? secureCaptcha,
  }) async {
    logins.add((phone, captcha));
    sessionCookie = 'MUSIC_U=fixture';
    return const FixtureLoginResult(
      code: 200,
      cookie: 'MUSIC_U=fixture',
      profile: _profile,
      account: FixtureAccount(id: 7),
    );
  }
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

AppState _state(_SmsGateway gateway) =>
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

  test('sending a code and signing in adopt the SMS session', () async {
    final gateway = _SmsGateway();
    final state = _state(gateway);
    addTearDown(() async {
      await _flush();
      state.dispose();
    });

    final AuthOutcome sent = await state.sendSmsCode('13800000000');
    expect(sent.ok, isTrue);
    expect(gateway.sentPhones, <String>['86:13800000000']);

    final AuthOutcome outcome = await state.signInWithPhoneCaptcha(
      '13800000000',
      '123456',
    );
    expect(outcome.ok, isTrue);
    expect(gateway.logins, <(String, String)>[('13800000000', '123456')]);
    expect(state.signedIn, isTrue);
    expect(state.user.method, AuthMethod.sms);
    expect(state.user.userId, 7);
    await _flush();
    expect(
      (await SharedPreferences.getInstance()).getString('lazer_gateway_cookie'),
      isNull,
    );
  });

  testWidgets('the verification-code form sends a code and finishes sign-in', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final gateway = _SmsGateway();
    final state = _state(gateway);
    addTearDown(() async {
      await _flush();
      state.dispose();
    });

    await _openCard(tester, state);
    await tester.tap(find.text('短信验证码登录'));
    await tester.pump();

    final Finder fields = find.byType(TextField);
    expect(fields, findsNWidgets(2));
    await tester.enterText(fields.at(0), '13800000000');
    await tester.enterText(fields.at(1), '123456');

    await tester.tap(find.text('获取验证码'));
    await tester.pump();
    await tester.pump();
    expect(gateway.sentPhones, <String>['86:13800000000']);
    expect(find.text('验证码已发送，请注意查收。'), findsOneWidget);
    // The resend button locks for a minute and counts down.
    expect(find.text('60 秒'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('59 秒'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, '登录'));
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(gateway.logins, <(String, String)>[('13800000000', '123456')]);
    expect(state.signedIn, isTrue);
    expect(find.text('获取验证码'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an invalid phone never reaches the gateway', (tester) async {
    tester.view.physicalSize = const Size(900, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final gateway = _SmsGateway();
    final state = _state(gateway);
    addTearDown(() async {
      await _flush();
      state.dispose();
    });

    await _openCard(tester, state);
    await tester.tap(find.text('短信验证码登录'));
    await tester.pump();
    await tester.enterText(find.byType(TextField).first, '123');
    await tester.tap(find.text('获取验证码'));
    await tester.pump();

    expect(gateway.sentPhones, isEmpty);
    expect(find.text('手机号格式不正确。'), findsOneWidget);
    expect(state.signedIn, isFalse);
  });
}
