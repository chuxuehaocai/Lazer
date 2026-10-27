import 'dart:convert';

import 'transport.dart';

/// Search types accepted by `/search`.
enum GatewaySearchType { song, album, artist, playlist }

extension on GatewaySearchType {
  int get apiValue => switch (this) {
    GatewaySearchType.song => 1,
    GatewaySearchType.album => 10,
    GatewaySearchType.artist => 100,
    GatewaySearchType.playlist => 1000,
  };
}

class GatewayUserProfile {
  const GatewayUserProfile({
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

  factory GatewayUserProfile.fromJson(Map<String, dynamic> json) =>
      GatewayUserProfile(
        userId: (json['userId'] as num?)?.toInt() ?? 0,
        nickname: json['nickname'] as String? ?? '',
        avatarUrl: json['avatarUrl'] as String?,
        signature: json['signature'] as String?,
        vipType: (json['vipType'] as num?)?.toInt(),
      );
}

class GatewayLoginStatus {
  const GatewayLoginStatus({this.profile, this.account});

  final GatewayUserProfile? profile;
  final GatewayAccount? account;

  bool get signedIn => (profile?.userId ?? 0) > 0 || (account?.id ?? 0) > 0;

  factory GatewayLoginStatus.fromJson(Map<String, dynamic> json) {
    final dynamic data = json['data'];
    final Map<String, dynamic> dataMap = data is Map<String, dynamic>
        ? data
        : const <String, dynamic>{};
    final dynamic profile = dataMap['profile'];
    final dynamic account = dataMap['account'];
    return GatewayLoginStatus(
      profile: profile is Map<String, dynamic>
          ? GatewayUserProfile.fromJson(profile)
          : null,
      account: account is Map<String, dynamic>
          ? GatewayAccount.fromJson(account)
          : null,
    );
  }
}

class GatewayAccount {
  const GatewayAccount({required this.id, this.userName, this.vipType});

  final int id;
  final String? userName;
  final int? vipType;

  factory GatewayAccount.fromJson(Map<String, dynamic> json) => GatewayAccount(
    id: (json['id'] as num?)?.toInt() ?? 0,
    userName: json['userName'] as String?,
    vipType: (json['vipType'] as num?)?.toInt(),
  );
}

class GatewayLoginResult {
  const GatewayLoginResult({
    required this.code,
    this.cookie,
    this.profile,
    this.account,
    this.message,
  });

  final int code;
  final String? cookie;
  final GatewayUserProfile? profile;
  final GatewayAccount? account;
  final String? message;

  bool get ok => code == 200 && cookie != null && profile != null;

  factory GatewayLoginResult.fromJson(Map<String, dynamic> json) {
    final dynamic profile = json['profile'];
    final dynamic account = json['account'];
    return GatewayLoginResult(
      code: (json['code'] as num?)?.toInt() ?? 0,
      cookie: json['cookie'] as String?,
      profile: profile is Map<String, dynamic>
          ? GatewayUserProfile.fromJson(profile)
          : null,
      account: account is Map<String, dynamic>
          ? GatewayAccount.fromJson(account)
          : null,
      message: json['message'] as String?,
    );
  }
}

class GatewayQrCheck {
  const GatewayQrCheck({required this.code, this.message, this.cookie});

  final int code;
  final String? message;
  final String? cookie;
}

class GatewayArtist {
  const GatewayArtist({required this.id, required this.name, this.coverUrl});
  final int id;
  final String name;
  final String? coverUrl;
  factory GatewayArtist.fromJson(Map<String, dynamic> json) => GatewayArtist(
    id: (json['id'] as num?)?.toInt() ?? 0,
    name: json['name'] as String? ?? '',
    coverUrl: (json['cover'] ?? json['picUrl'] ?? json['img1v1Url']) as String?,
  );
  static List<GatewayArtist> list(Object? values) => values is List
      ? [
          for (final value in values)
            if (value is Map<String, dynamic>) GatewayArtist.fromJson(value),
        ]
      : const [];
}

class GatewaySong {
  const GatewaySong({
    required this.id,
    required this.title,
    required this.artists,
    required this.albumName,
    required this.duration,
    this.albumId = 0,
    this.coverUrl,
    this.mv = 0,
    this.fee = 0,
    this.translatedTitle,
    this.artistDetails = const [],
  });

  final int id;
  final String title;
  final List<String> artists;
  final String albumName;
  final Duration duration;
  final int albumId;
  final String? coverUrl;
  final int mv;
  final int fee;
  final String? translatedTitle;
  final List<GatewayArtist> artistDetails;

  String get artistLine => artists.isEmpty ? '未知艺术家' : artists.join(' / ');

  factory GatewaySong.fromJson(Map<String, dynamic> json) {
    final dynamic ar = json['ar'] ?? json['artists'];
    final dynamic al = json['al'] ?? json['album'];
    final Map<String, dynamic> album = al is Map<String, dynamic>
        ? al
        : const <String, dynamic>{};
    final List<String> artists = ar is List
        ? ar
              .whereType<Map<String, dynamic>>()
              .map<String>(
                (Map<String, dynamic> artist) =>
                    artist['name'] as String? ?? '',
              )
              .where((String name) => name.isNotEmpty)
              .toList()
        : const <String>[];
    final dynamic dt = json['dt'] ?? json['duration'];
    final dynamic translated = json['tns'] ?? json['transNames'];
    final String translatedTitle = translated is List
        ? translated
              .whereType<String>()
              .map((value) => value.trim())
              .where((value) => value.isNotEmpty && value != json['name'])
              .toSet()
              .join(' / ')
        : '';
    return GatewaySong(
      id: (json['id'] as num?)?.toInt() ?? 0,
      title: json['name'] as String? ?? '',
      artists: artists,
      artistDetails: GatewayArtist.list(ar),
      albumName: album['name'] as String? ?? '',
      duration: Duration(milliseconds: (dt as num?)?.toInt() ?? 0),
      albumId: (album['id'] as num?)?.toInt() ?? 0,
      coverUrl: album['picUrl'] as String?,
      mv: (json['mv'] as num?)?.toInt() ?? 0,
      fee: (json['fee'] as num?)?.toInt() ?? 0,
      translatedTitle: translatedTitle.isEmpty ? null : translatedTitle,
    );
  }
}

/// One row of the listener's play record: a song and how often it was played.
class GatewayPlayRecord {
  const GatewayPlayRecord({required this.song, required this.playCount});

  final GatewaySong song;
  final int playCount;
}

class GatewaySongUrl {
  const GatewaySongUrl({
    required this.id,
    this.url,
    this.br,
    this.type,
    this.code,
    this.level,
    this.size,
  });

  final int id;
  final String? url;

  /// Actual bitrate of the returned rendition.
  final int? br;
  final String? type;
  final int? code;

  /// Tier name the service reports, when it answers with one.
  final String? level;

  /// File size of the returned rendition, when the service reports it.
  final int? size;
}

class GatewayPlaylist {
  const GatewayPlaylist({
    required this.id,
    required this.name,
    this.description = '',
    this.coverUrl,
    this.trackCount = 0,
    this.playCount = 0,
    this.trackIds = const <int>[],
    this.created = false,
    this.subscribed,
    this.creatorId,
    this.specialType,
  });

  final int id;
  final String name;
  final String description;
  final String? coverUrl;
  final int trackCount;
  final int playCount;
  final List<int> trackIds;

  /// Set by [NeteaseGateway.createPlaylist] for a playlist that was just
  /// created; `/user/playlist` does not send this legacy flag.
  final bool created;

  /// `/user/playlist` marks collected playlists with `subscribed: true` and
  /// leaves it false for the account's own playlists.
  final bool? subscribed;

  /// Owner id (`creator.userId`). Together with [subscribed] this identifies
  /// playlists owned by the signed-in account.
  final int? creatorId;

  /// NetEase marks the personal "liked songs" collection as `specialType = 5`.
  final int? specialType;

  factory GatewayPlaylist.fromJson(Map<String, dynamic> json) {
    final dynamic trackIds = json['trackIds'];
    final dynamic creator = json['creator'];
    final dynamic subscribed = json['subscribed'];
    return GatewayPlaylist(
      id: (json['id'] as num?)?.toInt() ?? 0,
      name: json['name'] as String? ?? '',
      description: json['description'] as String? ?? '',
      coverUrl: (json['coverImgUrl'] ?? json['picUrl']) as String?,
      trackCount: (json['trackCount'] as num?)?.toInt() ?? 0,
      playCount: (json['playCount'] as num?)?.toInt() ?? 0,
      created: json['created'] as bool? ?? false,
      subscribed: subscribed is bool ? subscribed : null,
      creatorId: creator is Map<String, dynamic>
          ? (creator['userId'] as num?)?.toInt()
          : null,
      specialType: (json['specialType'] as num?)?.toInt(),
      trackIds: trackIds is List
          ? trackIds
                .whereType<Map<String, dynamic>>()
                .map<int>(
                  (Map<String, dynamic> id) => (id['id'] as num?)?.toInt() ?? 0,
                )
                .where((int id) => id > 0)
                .toList()
          : const <int>[],
    );
  }
}

class GatewayAlbum {
  const GatewayAlbum({
    required this.id,
    required this.title,
    this.artist = '',
    this.coverUrl,
    this.publishTime,
    this.trackCount = 0,
    this.artists = const [],
    this.releaseType = '',
    this.subType = '',
  });

  final int id;
  final String title;
  final String artist;
  final String? coverUrl;
  final int? publishTime;
  final int trackCount;
  final List<GatewayArtist> artists;
  final String releaseType;
  final String subType;

  factory GatewayAlbum.fromJson(Map<String, dynamic> json) {
    final dynamic artist =
        json['artist'] ??
        (json['artists'] is List && (json['artists'] as List).isNotEmpty
            ? (json['artists'] as List).first
            : null);
    final artists = GatewayArtist.list(
      json['artists'] ?? (artist is Map<String, dynamic> ? [artist] : null),
    );
    final names = artists
        .map((artist) => artist.name)
        .where((name) => name.isNotEmpty)
        .toSet();
    return GatewayAlbum(
      id: (json['id'] as num?)?.toInt() ?? 0,
      title: json['name'] as String? ?? '',
      artist: names.isNotEmpty
          ? names.join(' / ')
          : artist is Map<String, dynamic>
          ? artist['name'] as String? ?? ''
          : '',
      coverUrl: (json['picUrl'] ?? json['blurPicUrl']) as String?,
      publishTime: (json['publishTime'] as num?)?.toInt(),
      trackCount: (json['size'] as num?)?.toInt() ?? 0,
      artists: artists,
      releaseType: json['type'] as String? ?? '',
      subType: json['subType'] as String? ?? '',
    );
  }
}

class GatewayBanner {
  const GatewayBanner({this.targetId, this.imageUrl, this.title, this.url});

  final int? targetId;
  final String? imageUrl;
  final String? title;
  final String? url;
}

class GatewayLyrics {
  const GatewayLyrics({
    this.lrc,
    this.yrc,
    this.tlyric,
    this.ytlrc,
    this.pureMusic = false,
  });

  final String? lrc;
  final String? yrc;
  final String? tlyric;
  final String? ytlrc;
  final bool pureMusic;

  bool get hasTimedLyric {
    final String? yrcLyric = yrc;
    final String? lrcLyric = lrc;
    if (yrcLyric != null && _yrcTimedLine.hasMatch(yrcLyric)) return true;
    return lrcLyric != null && _lrcTimedLine.hasMatch(lrcLyric);
  }

  static final RegExp _yrcTimedLine = RegExp(
    r'^\s*\[\d+,\d+\]',
    multiLine: true,
  );
  static final RegExp _lrcTimedLine = RegExp(
    r'^\s*\[\d{1,2}:\d{2}',
    multiLine: true,
  );
}

/// Port of NeteaseMusicGateway.kt: the typed facade over the route table.
class NeteaseGateway {
  NeteaseGateway({NeteaseTransport? transport})
    : _transport = transport ?? NeteaseTransport();

  final NeteaseTransport _transport;

  String? get sessionCookie {
    final String? stored = _transport.cookie;
    final String? normalized = normalizeGatewaySessionCookie(stored);
    if (stored != normalized) _transport.cookie = normalized;
    return normalized;
  }

  set sessionCookie(String? value) =>
      _transport.cookie = normalizeGatewaySessionCookie(value);

  void clearSession() => _transport.cookie = null;

  /// Installs a user-supplied cookie and verifies it; an invalid cookie never
  /// replaces the previous session.
  Future<GatewayLoginStatus> loginWithCookie(String cookie) async {
    final String? candidate = normalizeGatewaySessionCookie(cookie);
    if (candidate == null) {
      throw ArgumentError('cookie does not contain any valid cookie fields.');
    }
    final String? previous = sessionCookie;
    sessionCookie = candidate;
    try {
      final GatewayLoginStatus status = await loginStatus();
      if (!status.signedIn) sessionCookie = previous;
      return status;
    } catch (_) {
      sessionCookie = previous;
      rethrow;
    }
  }

  Future<GatewayLoginResult> loginWithPhonePassword(
    String phone,
    String password, {
    String countryCode = '86',
    String? sliderToken,
  }) async {
    if (phone.trim().isEmpty) throw ArgumentError('phone cannot be blank.');
    if (password.trim().isEmpty) {
      throw ArgumentError('password cannot be blank.');
    }
    return _remember(
      GatewayLoginResult.fromJson(
        await _transport.request('/login/cellphone', <String, String>{
          'phone': phone,
          'password': password,
          'countrycode': countryCode,
          'sca': sliderToken ?? '',
        }),
      ),
    );
  }

  Future<GatewayLoginResult> loginWithPhoneCaptcha(
    String phone,
    String captcha, {
    String countryCode = '86',
    String? secureCaptcha,
  }) async {
    if (phone.trim().isEmpty) throw ArgumentError('phone cannot be blank.');
    if (captcha.trim().isEmpty) throw ArgumentError('captcha cannot be blank.');
    return _remember(
      GatewayLoginResult.fromJson(
        await _transport.request('/login/cellphone', <String, String>{
          'phone': phone,
          'captcha': captcha,
          'countrycode': countryCode,
          'sca': secureCaptcha ?? '',
        }),
      ),
    );
  }

  Future<GatewayLoginResult> loginWithEmail(
    String email,
    String password,
  ) async {
    if (email.trim().isEmpty) throw ArgumentError('email cannot be blank.');
    if (password.trim().isEmpty) {
      throw ArgumentError('password cannot be blank.');
    }
    return _remember(
      GatewayLoginResult.fromJson(
        await _transport.request('/login', <String, String>{
          'email': email,
          'password': password,
        }),
      ),
    );
  }

  Future<String> createQrKey() async {
    // No `platform` parameter: the default `pc` QR points at
    // `https://music.163.com/login?codekey=<unikey>`, the URL the phone app
    // can confirm. Asking for `web` would attach a `chainId` derived from a
    // device id this anonymous session does not have (see `_qrLoginUrl`).
    final Map<String, dynamic> body = await _transport.request(
      '/login/qr/key',
      const <String, String>{},
    );
    // Persist the unikey session cookie up front: the check poll must replay
    // this cookie, exactly like api-enhanced's query.cookie passthrough.
    final String? keyCookie = body['cookie'] as String?;
    if (keyCookie != null) sessionCookie = keyCookie;
    final dynamic data = body['data'];
    return data is Map<String, dynamic> ? data['unikey'] as String? ?? '' : '';
  }

  /// `/login/qr/create` is synthesized in-process, matching the Kotlin transport.
  Future<String> createQrCodeUrl(String key) async {
    if (key.trim().isEmpty) throw ArgumentError('key cannot be blank.');
    final Map<String, dynamic> body = await _transport.request(
      '/login/qr/create',
      <String, String>{'key': key, 'qrimg': 'true'},
    );
    final dynamic data = body['data'];
    return data is Map<String, dynamic> ? data['qrurl'] as String? ?? '' : '';
  }

  /// Polls a scan key. [secureCaptcha] carries the Yidun token when the scan
  /// tripped risk control (the poll answers 8821 first), exactly like the
  /// desktop client's `checkQRCodeLogin`.
  Future<GatewayQrCheck> checkQrCode(
    String key, {
    String secureCaptcha = '',
  }) async {
    if (key.trim().isEmpty) throw ArgumentError('key cannot be blank.');
    final Map<String, dynamic> body = await _transport.request(
      '/login/qr/check',
      <String, String>{'key': key, 'secureCaptcha': secureCaptcha},
    );
    return _readQrCheck(body);
  }

  GatewayQrCheck _readQrCheck(Map<String, dynamic> body) {
    final Object? rawCookie = body['cookie'];
    final String? cookie = rawCookie is String ? rawCookie : null;
    // Refresh on every code (801/802 included), not only on 803 — the QR
    // session rotates while the user scans, mirroring api-enhanced.
    if (cookie != null) sessionCookie = cookie;
    return GatewayQrCheck(
      code: (body['code'] as num?)?.toInt() ?? 0,
      message: body['message'] as String?,
      cookie: cookie,
    );
  }

  Future<void> refreshLogin() async {
    await _transport.request('/login/refresh', const <String, String>{});
  }

  Future<GatewayLoginStatus> loginStatus() async {
    return GatewayLoginStatus.fromJson(
      await _transport.request('/login/status', const <String, String>{}),
    );
  }

  Future<void> logout() async {
    await _transport.request('/logout', const <String, String>{});
    clearSession();
  }

  Future<void> sendCaptcha(String phone, {String countryCode = '86'}) async {
    if (phone.trim().isEmpty) throw ArgumentError('phone cannot be blank.');
    final Map<String, dynamic> body = await _transport.request(
      '/captcha/sent/v1',
      <String, String>{'phone': phone, 'ctcode': countryCode},
    );
    // Keep the device cookies this anonymous call minted; the captcha login
    // that follows has to present them (api-enhanced keeps the whole jar).
    final String? cookie = body['cookie'] as String?;
    if (cookie != null) sessionCookie = cookie;
  }

  Future<List<GatewaySong>> search(
    String keywords, {
    GatewaySearchType type = GatewaySearchType.song,
    int limit = 30,
    int offset = 0,
    bool useCloudSearch = false,
  }) async {
    if (keywords.trim().isEmpty) {
      throw ArgumentError('keywords cannot be blank.');
    }
    if (limit <= 0 || offset < 0) throw ArgumentError('Invalid search page.');
    final Map<String, dynamic> body = await _transport
        .request(useCloudSearch ? '/cloudsearch' : '/search', <String, String>{
          'keywords': keywords,
          'type': type.apiValue.toString(),
          'limit': limit.toString(),
          'offset': offset.toString(),
        });
    final dynamic result = body['result'];
    final Map<String, dynamic> resultMap = result is Map<String, dynamic>
        ? result
        : const <String, dynamic>{};
    final dynamic songs = resultMap['songs'];
    return songs is List
        ? songs
              .whereType<Map<String, dynamic>>()
              .map<GatewaySong>(GatewaySong.fromJson)
              .where((GatewaySong song) => song.id > 0)
              .toList()
        : const <GatewaySong>[];
  }

  Future<Map<String, dynamic>> defaultSearchKeyword() =>
      _transport.request('/search/default', const <String, String>{});

  Future<Map<String, dynamic>> searchSuggestions(
    String keywords, {
    bool mobile = false,
  }) {
    if (keywords.trim().isEmpty) {
      throw ArgumentError('keywords cannot be blank.');
    }
    return _transport.request('/search/suggest', <String, String>{
      'keywords': keywords,
      if (mobile) 'type': 'mobile',
    });
  }

  Future<List<GatewayPlaylist>> searchPlaylists(
    String keywords, {
    int limit = 20,
  }) async {
    if (keywords.trim().isEmpty) {
      throw ArgumentError('keywords cannot be blank.');
    }
    final Map<String, dynamic> body = await _transport
        .request('/search', <String, String>{
          'keywords': keywords,
          'type': GatewaySearchType.playlist.apiValue.toString(),
          'limit': limit.toString(),
        });
    final dynamic result = body['result'];
    final Map<String, dynamic> resultMap = result is Map<String, dynamic>
        ? result
        : const <String, dynamic>{};
    final dynamic playlists = resultMap['playlists'];
    return playlists is List
        ? playlists
              .whereType<Map<String, dynamic>>()
              .map<GatewayPlaylist>(GatewayPlaylist.fromJson)
              .where((GatewayPlaylist playlist) => playlist.id > 0)
              .toList()
        : const <GatewayPlaylist>[];
  }

  Future<List<GatewayAlbum>> searchAlbums(
    String keywords, {
    int limit = 10,
  }) async {
    if (keywords.trim().isEmpty) {
      throw ArgumentError('keywords cannot be blank.');
    }
    final Map<String, dynamic> body = await _transport
        .request('/search', <String, String>{
          'keywords': keywords,
          'type': GatewaySearchType.album.apiValue.toString(),
          'limit': limit.toString(),
        });
    final dynamic result = body['result'];
    final Map<String, dynamic> resultMap = result is Map<String, dynamic>
        ? result
        : const <String, dynamic>{};
    final dynamic albums = resultMap['albums'];
    return albums is List
        ? albums
              .whereType<Map<String, dynamic>>()
              .map<GatewayAlbum>(GatewayAlbum.fromJson)
              .where((GatewayAlbum album) => album.id > 0)
              .toList()
        : const <GatewayAlbum>[];
  }

  Future<List<GatewayArtist>> searchArtists(
    String keywords, {
    int limit = 10,
  }) async {
    if (keywords.trim().isEmpty) {
      throw ArgumentError('keywords cannot be blank.');
    }
    final Map<String, dynamic> body = await _transport
        .request('/search', <String, String>{
          'keywords': keywords,
          'type': GatewaySearchType.artist.apiValue.toString(),
          'limit': limit.toString(),
        });
    final dynamic result = body['result'];
    final Map<String, dynamic> resultMap = result is Map<String, dynamic>
        ? result
        : const <String, dynamic>{};
    final dynamic artists = resultMap['artists'];
    return artists is List
        ? artists
              .whereType<Map<String, dynamic>>()
              .map<GatewayArtist>(GatewayArtist.fromJson)
              .where((GatewayArtist artist) => artist.id > 0)
              .toList()
        : const <GatewayArtist>[];
  }

  Future<List<String>> hotSearches() async {
    final Map<String, dynamic> body = await _transport.request(
      '/search/hot/detail',
      const <String, String>{},
    );
    final dynamic data = body['data'];
    if (data is! List) return const <String>[];
    return data
        .whereType<Map<String, dynamic>>()
        .map<String>(
          (Map<String, dynamic> item) =>
              (item['first'] ?? item['keyword']) as String? ?? '',
        )
        .where((String word) => word.isNotEmpty)
        .toList();
  }

  Future<List<GatewaySong>> songDetails(List<int> ids) async {
    if (ids.isEmpty) throw ArgumentError('ids cannot be empty.');
    final Map<String, dynamic> body = await _transport.request(
      '/song/detail',
      <String, String>{'ids': ids.map((int id) => id.toString()).join(',')},
    );
    final dynamic songs = body['songs'];
    return songs is List
        ? songs
              .whereType<Map<String, dynamic>>()
              .map<GatewaySong>(GatewaySong.fromJson)
              .where((GatewaySong song) => song.id > 0)
              .toList()
        : const <GatewaySong>[];
  }

  Future<GatewaySongUrl?> songUrl(int id, {String level = 'exhigh'}) async {
    if (id <= 0) throw ArgumentError('id must be positive.');
    final Map<String, dynamic> body = await _transport.request(
      '/song/url/v1',
      <String, String>{'id': id.toString(), 'level': level},
    );
    final dynamic data = body['data'];
    if (data is! List || data.isEmpty) return null;
    final dynamic first = data.first;
    if (first is! Map<String, dynamic>) return null;
    return GatewaySongUrl(
      id: (first['id'] as num?)?.toInt() ?? 0,
      url: first['url'] as String?,
      br: (first['br'] as num?)?.toInt(),
      type: first['type'] as String?,
      code: (first['code'] as num?)?.toInt(),
      level: first['level'] as String?,
      size: (first['size'] as num?)?.toInt(),
    );
  }

  Future<bool> isMusicAvailable(int id) async {
    final Map<String, dynamic> body = await _transport.request(
      '/check/music',
      <String, String>{'id': id.toString()},
    );
    return body['success'] == true;
  }

  Future<GatewayLyrics> lyrics(int id) async {
    final Map<String, dynamic> body = await _transport.request(
      '/lyric',
      <String, String>{'id': id.toString()},
    );
    return _lyricsFrom(body);
  }

  Future<GatewayLyrics> wordByWordLyrics(int id) async {
    final Map<String, dynamic> body = await _transport.request(
      '/lyric/new',
      <String, String>{'id': id.toString()},
    );
    return _lyricsFrom(body);
  }

  /// Prefers `/lyric/new`, falling back when it lacks a timed payload.
  Future<GatewayLyrics> preferredLyrics(int id) async {
    GatewayLyrics? enhanced;
    try {
      enhanced = await wordByWordLyrics(id);
      if (enhanced.pureMusic || enhanced.hasTimedLyric) return enhanced;
    } catch (_) {}
    try {
      return await lyrics(id);
    } catch (_) {
      if (enhanced != null &&
          ((enhanced.lrc?.isNotEmpty ?? false) ||
              (enhanced.yrc?.isNotEmpty ?? false))) {
        return enhanced;
      }
      rethrow;
    }
  }

  Future<Map<String, dynamic>> playlistDetail(
    int id, {
    int subscriberLimit = 8,
  }) async {
    return _transport.request('/playlist/detail', <String, String>{
      'id': id.toString(),
      's': subscriberLimit.toString(),
    });
  }

  Future<Map<String, dynamic>> playlistTracks(
    int id, {
    int? limit,
    int offset = 0,
  }) async {
    return _transport.request('/playlist/track/all', <String, String>{
      'id': id.toString(),
      if (limit != null) 'limit': limit.toString(),
      'offset': offset.toString(),
    });
  }

  /// Creates a playlist on the signed-in account and returns it.
  ///
  /// [privacy] maps to the official client's 私密 mode: a private playlist is
  /// still created in the cloud but is visible only to its owner. A missing
  /// playlist in the response is tolerated — the created id is enough for the
  /// caller to add a song right away.
  Future<GatewayPlaylist?> createPlaylist(
    String name, {
    bool privacy = false,
  }) async {
    final String trimmed = name.trim();
    if (trimmed.isEmpty) throw ArgumentError('name cannot be blank.');
    if (trimmed.length > 40) {
      throw ArgumentError('name cannot be longer than 40 characters.');
    }
    final Map<String, dynamic> body = await _transport.request(
      '/playlist/create',
      <String, String>{'name': trimmed, 'privacy': privacy ? '10' : '0'},
    );
    final dynamic data = body['data'];
    final dynamic nestedPlaylist = data is Map<String, dynamic>
        ? data['playlist']
        : null;
    final dynamic raw = body['playlist'] ?? nestedPlaylist;
    if (raw is Map<String, dynamic>) {
      final GatewayPlaylist playlist = GatewayPlaylist.fromJson(raw);
      if (playlist.id > 0) return playlist;
    }
    final dynamic rawId =
        body['id'] ??
        body['playlistId'] ??
        (data is Map<String, dynamic>
            ? (data['id'] ?? data['playlistId'])
            : null);
    final int id = rawId is num
        ? rawId.toInt()
        : (rawId is String ? int.tryParse(rawId) ?? 0 : 0);
    if (id <= 0) return null;
    return GatewayPlaylist(id: id, name: trimmed, created: true);
  }

  /// Adds [trackIds] to a playlist the account owns.
  ///
  /// The service's manipulate endpoint answers with the playlist's new id
  /// list; callers invalidate their cached copy instead of parsing it.
  Future<void> addTracksToPlaylist(int playlistId, List<int> trackIds) async {
    if (playlistId <= 0) throw ArgumentError.value(playlistId, 'playlistId');
    if (trackIds.isEmpty) throw ArgumentError('trackIds cannot be empty.');
    if (trackIds.any((int id) => id <= 0)) {
      throw ArgumentError.value(trackIds, 'trackIds', 'must be positive IDs.');
    }
    await _transport.request('/playlist/tracks', <String, String>{
      'op': 'add',
      'pid': '$playlistId',
      'tracks': trackIds.join(','),
    });
  }

  /// Removes [trackIds] from a playlist the account owns.
  Future<void> removeTracksFromPlaylist(
    int playlistId,
    List<int> trackIds,
  ) async {
    if (playlistId <= 0) throw ArgumentError.value(playlistId, 'playlistId');
    if (trackIds.isEmpty) throw ArgumentError('trackIds cannot be empty.');
    if (trackIds.any((int id) => id <= 0)) {
      throw ArgumentError.value(trackIds, 'trackIds', 'must be positive IDs.');
    }
    await _transport.request('/playlist/tracks', <String, String>{
      'op': 'del',
      'pid': '$playlistId',
      'tracks': trackIds.join(','),
    });
  }

  Future<GatewayPlaylist?> topPlaylist(int id) async {
    final Map<String, dynamic> detail = await playlistDetail(id);
    final dynamic playlist = detail['playlist'];
    return playlist is Map<String, dynamic>
        ? GatewayPlaylist.fromJson(playlist)
        : null;
  }

  Future<List<GatewayPlaylist>> topPlaylists({
    String category = '全部',
    int limit = 12,
    int offset = 0,
  }) async {
    final Map<String, dynamic> body = await _transport.request(
      '/top/playlist',
      <String, String>{
        'cat': category,
        'limit': limit.toString(),
        'offset': offset.toString(),
      },
    );
    final dynamic playlists = body['playlists'];
    return playlists is List
        ? playlists
              .whereType<Map<String, dynamic>>()
              .map<GatewayPlaylist>(GatewayPlaylist.fromJson)
              .toList()
        : const <GatewayPlaylist>[];
  }

  Future<List<GatewayPlaylist>> chartPlaylists() async {
    final Map<String, dynamic> body = await _transport.request(
      '/toplist/detail',
      const <String, String>{},
    );
    final dynamic playlists = body['list'];
    return playlists is List
        ? playlists
              .whereType<Map<String, dynamic>>()
              .map<GatewayPlaylist>(GatewayPlaylist.fromJson)
              .where((playlist) => playlist.id > 0)
              .toList()
        : const <GatewayPlaylist>[];
  }

  Future<List<GatewayPlaylist>> userPlaylists(
    int uid, {
    int limit = 30,
    int offset = 0,
  }) async {
    final Map<String, dynamic> body = await _transport.request(
      '/user/playlist',
      <String, String>{
        'uid': uid.toString(),
        'limit': limit.toString(),
        'offset': offset.toString(),
      },
    );
    final dynamic playlists = body['playlist'];
    return playlists is List
        ? playlists
              .whereType<Map<String, dynamic>>()
              .map<GatewayPlaylist>(GatewayPlaylist.fromJson)
              .toList()
        : const <GatewayPlaylist>[];
  }

  Future<GatewayAlbum?> albumDetail(int id) async {
    final Map<String, dynamic> body = await albumDetailRaw(id);
    final dynamic album = body['album'];
    return album is Map<String, dynamic> ? GatewayAlbum.fromJson(album) : null;
  }

  /// Raw `/album` payload: `album` plus the full `songs` list.
  Future<Map<String, dynamic>> albumDetailRaw(int id) async {
    return _transport.request('/album', <String, String>{'id': id.toString()});
  }

  Future<List<GatewaySong>> artistTopSongs(int id) async {
    final Map<String, dynamic> body = await _transport.request(
      '/artist/top/song',
      <String, String>{'id': id.toString()},
    );
    final dynamic songs = body['songs'];
    return songs is List
        ? songs
              .whereType<Map<String, dynamic>>()
              .map<GatewaySong>(GatewaySong.fromJson)
              .toList()
        : const <GatewaySong>[];
  }

  Future<List<GatewayArtist>> similarArtists(int id) async {
    if (id <= 0) throw ArgumentError.value(id, 'id');
    final body = await _transport.request('/simi/artist', <String, String>{
      'id': '$id',
    });
    return GatewayArtist.list(
      body['artists'],
    ).where((artist) => artist.id > 0).toList();
  }

  Future<Map<String, dynamic>> artistSongs(
    int id, {
    int limit = 100,
    int offset = 0,
  }) {
    if (id <= 0 || limit <= 0 || limit > 500 || offset < 0) {
      throw ArgumentError('Invalid artist song page.');
    }
    return _transport.request('/artist/songs', <String, String>{
      'id': '$id',
      'limit': '$limit',
      'offset': '$offset',
      'order': 'hot',
    });
  }

  Future<List<GatewayBanner>> banners() async {
    final Map<String, dynamic> body = await _transport.request(
      '/banner',
      const <String, String>{'type': '0'},
    );
    final dynamic banners = body['banners'];
    if (banners is! List) return const <GatewayBanner>[];
    return banners.whereType<Map<String, dynamic>>().map<GatewayBanner>((
      Map<String, dynamic> item,
    ) {
      return GatewayBanner(
        targetId: (item['targetId'] as num?)?.toInt(),
        imageUrl: item['imageUrl'] as String?,
        title: item['typeTitle'] as String?,
        url: item['url'] as String?,
      );
    }).toList();
  }

  Future<List<GatewaySong>> dailyRecommendedSongs() async {
    final Map<String, dynamic> body = await _transport.request(
      '/recommend/songs',
      const <String, String>{},
    );
    final dynamic data = body['data'];
    final Map<String, dynamic> dataMap = data is Map<String, dynamic>
        ? data
        : const <String, dynamic>{};
    final dynamic songs = dataMap['dailySongs'] ?? body['recommend'];
    return songs is List
        ? songs
              .whereType<Map<String, dynamic>>()
              .map<GatewaySong>(GatewaySong.fromJson)
              .where((GatewaySong song) => song.id > 0)
              .toList()
        : const <GatewaySong>[];
  }

  Future<List<GatewayPlaylist>> dailyRecommendedPlaylists() async {
    final Map<String, dynamic> body = await _transport.request(
      '/recommend/resource',
      const <String, String>{},
    );
    final dynamic recommend = body['recommend'];
    if (recommend is! List) return const <GatewayPlaylist>[];
    return recommend
        .whereType<Map<String, dynamic>>()
        .map<GatewayPlaylist>((Map<String, dynamic> item) {
          return GatewayPlaylist(
            id: (item['id'] as num?)?.toInt() ?? 0,
            name: item['name'] as String? ?? '',
            description: item['copywriter'] as String? ?? '',
            coverUrl: item['picUrl'] as String?,
            trackCount: (item['trackCount'] as num?)?.toInt() ?? 0,
          );
        })
        .where((GatewayPlaylist playlist) => playlist.id > 0)
        .toList();
  }

  Future<List<GatewayPlaylist>> personalizedPlaylists({int limit = 12}) async {
    final body = await _transport.request('/personalized', {'limit': '$limit'});
    final result = body['result'];
    if (result is! List) return const [];
    return result
        .whereType<Map<String, dynamic>>()
        .map(
          (item) => GatewayPlaylist(
            id: (item['id'] as num?)?.toInt() ?? 0,
            name: item['name'] as String? ?? '',
            description: item['copywriter'] as String? ?? '',
            coverUrl: item['picUrl'] as String?,
            trackCount: (item['trackCount'] as num?)?.toInt() ?? 0,
          ),
        )
        .where((playlist) => playlist.id > 0)
        .toList();
  }

  Future<List<GatewaySong>> personalizedNewSongs({int limit = 20}) async {
    final body = await _transport.request('/personalized/newsong', {
      'limit': '$limit',
    });
    final dynamic result = body['result'];
    if (result is! List) return const <GatewaySong>[];
    return result
        .whereType<Map<String, dynamic>>()
        .map((item) {
          final dynamic song = item['song'];
          return song is Map<String, dynamic> ? song : item;
        })
        .map(GatewaySong.fromJson)
        .where((song) => song.id > 0)
        .toList();
  }

  Future<List<GatewaySong>> intelligenceList({
    required int songId,
    required int playlistId,
    int count = 20,
  }) async {
    final body = await _transport.request('/playmode/intelligence/list', {
      'id': '$songId',
      'pid': '$playlistId',
      'sid': '$songId',
      'count': '$count',
    });
    final dynamic data = body['data'];
    if (data is! List) return const <GatewaySong>[];
    return data
        .whereType<Map<String, dynamic>>()
        .map((item) {
          final dynamic song = item['songInfo'] ?? item['song'];
          return song is Map<String, dynamic> ? song : item;
        })
        .map(GatewaySong.fromJson)
        .where((song) => song.id > 0)
        .toList();
  }

  /// The all-time play record behind 听歌排行.
  ///
  /// The response carries `playCount` per song; the UI joins that with the
  /// song duration to show both the number of plays and the listening time
  /// the official app reports.
  Future<List<GatewayPlayRecord>> playRecord(int uid) async {
    if (uid <= 0) return const <GatewayPlayRecord>[];
    final body = await _transport.request('/v1/play/record', {
      'uid': '$uid',
      'type': '0',
    });
    final dynamic all = body['allData'];
    if (all is! List) return const <GatewayPlayRecord>[];
    return <GatewayPlayRecord>[
      for (final item in all.whereType<Map<String, dynamic>>())
        if (item['song'] is Map<String, dynamic> && _countOf(item) != null)
          GatewayPlayRecord(
            song: GatewaySong.fromJson(item['song'] as Map<String, dynamic>),
            playCount: _countOf(item)!,
          ),
    ];
  }

  static int? _countOf(Map<String, dynamic> item) {
    final dynamic value = item['playCount'];
    return value is num
        ? value.toInt()
        : int.tryParse(value is String ? value : '');
  }

  /// Reports one qualified play to the account's play record.
  ///
  /// This is the upload half of the play-count / listening-time sync: the
  /// official client posts an `play` action to the weblog endpoint, and the
  /// account's record (read back by [playRecord]) gains both the play and the
  /// listened seconds. [playedSeconds] is the time actually heard in this
  /// session, not the track duration.
  Future<void> reportPlayback({
    required int songId,
    required int playedSeconds,
  }) async {
    if (songId <= 0 || playedSeconds <= 0) return;
    final String logs = jsonEncode(<Map<String, Object?>>[
      <String, Object?>{
        'action': 'play',
        'json': <String, Object?>{
          'id': songId,
          'type': 'song',
          'time': playedSeconds,
          'end': 'playend',
          'wifi': 0,
          'source': 'list',
          'mainsite': 1,
          'download': 0,
          'content': '',
        },
      },
    ]);
    await _transport.request('/feedback/weblog', <String, String>{
      'logs': logs,
    });
  }

  Future<List<GatewaySong>> personalFm() async {
    final Map<String, dynamic> body = await _transport.request(
      '/personal_fm',
      const <String, String>{},
    );
    final dynamic data = body['data'];
    return data is List
        ? data
              .whereType<Map<String, dynamic>>()
              .map<GatewaySong>(GatewaySong.fromJson)
              .where((GatewaySong song) => song.id > 0)
              .toList()
        : const <GatewaySong>[];
  }

  Future<Map<String, dynamic>> userDetail(int uid) {
    if (uid <= 0) throw ArgumentError.value(uid, 'uid');
    return _transport.request('/user/detail', <String, String>{'uid': '$uid'});
  }

  Future<Map<String, dynamic>> artistDetail(int id) {
    if (id <= 0) throw ArgumentError.value(id, 'id');
    return _transport.request('/artist/detail', <String, String>{'id': '$id'});
  }

  Future<Map<String, dynamic>> artistAlbums(
    int id, {
    int limit = 30,
    int offset = 0,
  }) {
    if (id <= 0 || limit <= 0 || offset < 0) {
      throw ArgumentError('Invalid artist page.');
    }
    return _transport.request('/artist/album', <String, String>{
      'id': '$id',
      'limit': '$limit',
      'offset': '$offset',
    });
  }

  Future<Map<String, dynamic>> songComments(
    int songId, {
    int limit = 20,
    int offset = 0,
  }) {
    if (songId <= 0 || limit <= 0 || limit > 100 || offset < 0) {
      throw ArgumentError('Invalid comment page.');
    }
    return _transport.request('/comment/music', <String, String>{
      'id': '$songId',
      'limit': '$limit',
      'offset': '$offset',
    });
  }

  Future<void> setSongCommentLiked(
    int songId,
    int commentId,
    bool liked,
  ) async {
    if (songId <= 0 || commentId <= 0) {
      throw ArgumentError('Invalid comment ID.');
    }
    await _transport.request(
      liked ? '/comment/like' : '/comment/unlike',
      <String, String>{'id': '$songId', 'commentId': '$commentId'},
    );
  }

  Future<void> replyToSongComment(
    int songId,
    int commentId,
    String content,
  ) async {
    if (songId <= 0 || commentId <= 0 || content.trim().isEmpty) {
      throw ArgumentError('Invalid comment reply.');
    }
    await _transport.request('/comment/reply', <String, String>{
      'id': '$songId',
      'commentId': '$commentId',
      'content': content.trim().substring(
        0,
        content.trim().length.clamp(0, 140),
      ),
    });
  }

  Future<Set<int>> likedSongIds(int uid) async {
    if (uid <= 0) throw ArgumentError.value(uid, 'uid');
    final body = await _transport.request('/likelist', <String, String>{
      'uid': '$uid',
    });
    final ids = body['ids'];
    return ids is List
        ? ids.whereType<num>().map((id) => id.toInt()).toSet()
        : <int>{};
  }

  Future<void> setSongLiked(int songId, int userId, bool liked) async {
    if (songId <= 0 || userId <= 0) {
      throw ArgumentError('Invalid song or user ID.');
    }
    await _transport.request('/song/like', <String, String>{
      'id': '$songId',
      'uid': '$userId',
      'like': '$liked',
    });
  }

  Future<void> setPersonalFmLiked(int songId, bool liked) async {
    if (songId <= 0) throw ArgumentError.value(songId, 'songId');
    await _transport.request('/like', <String, String>{
      'id': '$songId',
      'like': '$liked',
    });
  }

  Future<Map<String, dynamic>> listenTogetherCreateRoom() => _transport.request(
    '/listentogether/room/create',
    const <String, String>{},
  );

  Future<Map<String, dynamic>> listenTogetherCreateMultiRoom(
    int songId, {
    List<int> nextSongIds = const <int>[],
    int playedTimeMillis = 0,
  }) {
    if (songId <= 0) throw ArgumentError.value(songId, 'songId');
    return _transport
        .request('/listentogether/multi/room/create', <String, String>{
          'id': '$songId',
          'nextSongIds': nextSongIds.join(','),
          'playedTime': '${playedTimeMillis.clamp(0, 1 << 62)}',
        });
  }

  Future<Map<String, dynamic>> listenTogetherAccept(
    String roomId,
    int inviterId,
  ) => _transport.request('/listentogether/accept', <String, String>{
    'roomId': roomId,
    'inviterId': '$inviterId',
  });

  Future<Map<String, dynamic>> listenTogetherRoomCheck(String roomId) =>
      _transport.request('/listentogether/room/check', <String, String>{
        'roomId': roomId,
      });

  Future<Map<String, dynamic>> listenTogetherStatus() =>
      _transport.request('/listentogether/status', const <String, String>{});

  Future<Map<String, dynamic>> listenTogetherEnd(String roomId) => _transport
      .request('/listentogether/end', <String, String>{'roomId': roomId});

  Future<Map<String, dynamic>> listenTogetherHeartbeat(
    String roomId,
    int songId,
    String playStatus,
    int progress,
  ) => _transport.request('/listentogether/heartbeat', <String, String>{
    'roomId': roomId,
    'songId': '$songId',
    'playStatus': playStatus,
    'progress': '${progress.clamp(0, 1 << 62)}',
  });

  Future<Map<String, dynamic>> listenTogetherPlayCommand(
    String roomId,
    Map<String, Object?> commandInfo,
  ) => _transport.request('/listentogether/play/command', <String, String>{
    'roomId': roomId,
    'commandInfo': jsonEncode(commandInfo),
  });

  Future<Map<String, dynamic>> listenTogetherSyncList(
    String roomId,
    Map<String, Object?> playlistParam,
  ) => _transport.request('/listentogether/sync/list/command', <String, String>{
    'roomId': roomId,
    'playlistParam': jsonEncode(playlistParam),
  });

  Future<Map<String, dynamic>> listenTogetherPlaylist(String roomId) =>
      _transport.request('/listentogether/sync/playlist/get', <String, String>{
        'roomId': roomId,
      });

  GatewayLoginResult _remember(GatewayLoginResult result) {
    if (result.cookie != null) sessionCookie = result.cookie;
    return result;
  }

  GatewayLyrics _lyricsFrom(Map<String, dynamic> body) {
    final dynamic lrc = body['lrc'];
    final dynamic yrc = body['yrc'];
    return GatewayLyrics(
      lrc: lrc is Map<String, dynamic> ? lrc['lyric'] as String? : null,
      yrc: yrc is Map<String, dynamic> ? yrc['lyric'] as String? : null,
      pureMusic: body['pureMusic'] == true,
      tlyric: body['tlyric'] is Map
          ? (body['tlyric'] as Map)['lyric'] as String?
          : null,
      ytlrc: body['ytlrc'] is Map
          ? (body['ytlrc'] as Map)['lyric'] as String?
          : null,
    );
  }
}
