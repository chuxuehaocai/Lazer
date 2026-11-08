import 'package:lazer_nextgen/gateway/gateway.dart';
export 'package:lazer_nextgen/gateway/gateway.dart';

/// In-memory account fake for UI tests; no provider API or HTTP implementation.
class TestMusicGateway extends MusicAccountGateway {
  String? sessionCookie;
  MusicUser? _user;
  @override
  MusicProvider get provider =>
      const MusicProvider(id: 'fixture', name: 'Fixture Music');
  @override
  String get connectionId => 'test';
  @override
  MusicUser? get user => _user;
  @override
  Set<MusicCapability> get capabilities => const {MusicCapability.recommendations,MusicCapability.savedAlbums,MusicCapability.comments,MusicCapability.listenTogether};
  @override
  Set<String> get authenticationMethods => const {
    'qr',
    'sms',
    'password',
    'cookie',
    'exportCookie',
  };
  MusicUser? _adopt(FixtureProfile? profile) => _user = profile == null
      ? null
      : MusicUser(
          id: id(MusicEntityKind.user, '${profile.userId}'),
          name: profile.nickname,
          avatarUrl: profile.avatarUrl,
          signature: profile.signature,
          membership: (profile.vipType ?? 0) > 0 ? '会员' : null,
        );
  Future<FixtureLoginStatus> fixtureLoginWithCookie(String value) async {
    sessionCookie = value;
    return const FixtureLoginStatus(
      profile: FixtureProfile(userId: 7, nickname: 'Tester'),
    );
  }

  Future<FixtureLoginStatus> fixtureLoginStatus() async =>
      const FixtureLoginStatus();
  Future<FixtureLoginResult> fixturePhonePassword(
    String phone,
    String password, {
    String countryCode = '86',
  }) async => const FixtureLoginResult(code: 400);
  Future<FixtureLoginResult> fixtureEmailPassword(
    String email,
    String password,
  ) async => const FixtureLoginResult(code: 400);
  Future<FixtureLoginResult> fixturePhoneCaptcha(
    String phone,
    String captcha, {
    String countryCode = '86',
  }) async => const FixtureLoginResult(code: 400);
  Future<void> fixtureSendCaptcha(
    String phone, {
    String countryCode = '86',
  }) async {}
  Future<String> createQrKey() async => 'fixture-key';
  Future<String> createQrCodeUrl(String key) async =>
      'https://fixture.test/login?token=$key';
  Future<FixtureQrCheck> checkQrCode(
    String key, {
    String secureCaptcha = '',
  }) async => const FixtureQrCheck(code: 801);
  @override
  Future<MusicUser?> loginWithCookie(String cookie) async =>
      _adopt((await fixtureLoginWithCookie(cookie)).profile);
  @override
  Future<MusicUser?> checkSession() async =>
      _adopt((await fixtureLoginStatus()).profile);
  @override
  Future<MusicUser?> loginWithPassword(String account, String password) async {
    final result = await (account.contains('@')
        ? fixtureEmailPassword(account, password)
        : fixturePhonePassword(account, password));
    return result.code == 200 ? _adopt(result.profile) : null;
  }

  @override
  Future<MusicUser?> loginWithCaptcha(String phone, String captcha) async {
    final result = await fixturePhoneCaptcha(phone, captcha);
    return result.code == 200 ? _adopt(result.profile) : null;
  }

  @override
  Future<void> sendCaptcha(String phone) => fixtureSendCaptcha(phone);
  @override
  Future<String?> qrKey() => createQrKey();
  final _qrUrls = <String, String>{};
  @override
  Future<String> qrUrl(String key) async {
    final url = await createQrCodeUrl(key);
    _qrUrls[url] = key;
    return url;
  }

  @override
  Future<int> qrCheck(String key) async =>
      _qrUrls.containsKey(key) ? (await checkQrCode(_qrUrls[key]!)).code : 800;
  @override
  Future<String?> exportCookie() async => sessionCookie;
  @override
  void clearSession() {
    _user = null;
    sessionCookie = null;
  }
}

class FixtureProfile {
  const FixtureProfile({
    required this.userId,
    required this.nickname,
    this.avatarUrl,
    this.signature,
    this.vipType,
  });

  final int userId;
  final String nickname;
  final String? avatarUrl;
  final String? signature;
  final int? vipType;

  factory FixtureProfile.fromJson(Map<String, dynamic> json) => FixtureProfile(
    userId: (json['userId'] as num?)?.toInt() ?? 0,
    nickname: json['nickname'] as String? ?? '',
    avatarUrl: json['avatarUrl'] as String?,
    signature: json['signature'] as String?,
    vipType: (json['vipType'] as num?)?.toInt(),
  );
}

class FixtureLoginStatus {
  const FixtureLoginStatus({this.profile, this.account});

  final FixtureProfile? profile;
  final FixtureAccount? account;

  bool get signedIn => (profile?.userId ?? 0) > 0 || (account?.id ?? 0) > 0;

  factory FixtureLoginStatus.fromJson(Map<String, dynamic> json) {
    final dynamic data = json['data'];
    final Map<String, dynamic> dataMap = data is Map<String, dynamic>
        ? data
        : const <String, dynamic>{};
    final dynamic profile = dataMap['profile'];
    final dynamic account = dataMap['account'];
    return FixtureLoginStatus(
      profile: profile is Map<String, dynamic>
          ? FixtureProfile.fromJson(profile)
          : null,
      account: account is Map<String, dynamic>
          ? FixtureAccount.fromJson(account)
          : null,
    );
  }
}

class FixtureAccount {
  const FixtureAccount({required this.id, this.userName, this.vipType});

  final int id;
  final String? userName;
  final int? vipType;

  factory FixtureAccount.fromJson(Map<String, dynamic> json) => FixtureAccount(
    id: (json['id'] as num?)?.toInt() ?? 0,
    userName: json['userName'] as String?,
    vipType: (json['vipType'] as num?)?.toInt(),
  );
}

class FixtureLoginResult {
  const FixtureLoginResult({
    required this.code,
    this.cookie,
    this.profile,
    this.account,
    this.message,
  });

  final int code;
  final String? cookie;
  final FixtureProfile? profile;
  final FixtureAccount? account;
  final String? message;

  bool get ok => code == 200 && cookie != null && profile != null;

  factory FixtureLoginResult.fromJson(Map<String, dynamic> json) {
    final dynamic profile = json['profile'];
    final dynamic account = json['account'];
    return FixtureLoginResult(
      code: (json['code'] as num?)?.toInt() ?? 0,
      cookie: json['cookie'] as String?,
      profile: profile is Map<String, dynamic>
          ? FixtureProfile.fromJson(profile)
          : null,
      account: account is Map<String, dynamic>
          ? FixtureAccount.fromJson(account)
          : null,
      message: json['message'] as String?,
    );
  }
}

class FixtureQrCheck {
  const FixtureQrCheck({required this.code, this.message, this.cookie});

  final int code;
  final String? message;
  final String? cookie;
}
