/// Search types accepted by `/search`.
enum GatewaySearchType { song, album, artist, playlist }

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

  /// Set by `createPlaylist` for a playlist that was just
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
