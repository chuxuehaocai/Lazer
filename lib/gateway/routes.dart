import '../data/audio_quality.dart';
import 'crypto.dart';

/// One in-process route: upstream path plus the pre-encoded payload.
class NeteaseRequest {
  const NeteaseRequest({
    required this.path,
    required this.payload,
    this.encoding = NeteaseEncoding.eapi,
    this.mobileClient = false,
    this.desktopClient = false,
    this.domain,
  });

  final String path;
  final Map<String, Object?> payload;
  final NeteaseEncoding encoding;
  final bool mobileClient;

  /// Identifies the desktop client (`os=osx`) for endpoints that only accept
  /// plays from that player, such as the client-log deposit.
  final bool desktopClient;

  /// Overrides the request host, for example the client-log deposit host.
  /// Scheme and host only, without a trailing slash.
  final String? domain;
}

/// Port of the finite route table in NeteaseRoutes.kt.
NeteaseRequest buildNeteaseRequest(
  String alias,
  Map<String, String> parameters,
) {
  String value(String key, [String fallback = '']) =>
      parameters[key] ?? fallback;

  String id([String key = 'id']) {
    final String raw = value(key);
    final int? parsed = int.tryParse(raw);
    if (parsed == null || parsed <= 0) {
      throw ArgumentError.value(raw, key, 'must be a positive ID.');
    }
    return raw;
  }

  String roomId() {
    final raw = value('roomId').trim();
    if (raw.isEmpty || raw.length > 256 || !RegExp(r'^[\w-]+$').hasMatch(raw)) {
      throw ArgumentError.value(raw, 'roomId', 'Invalid room identifier.');
    }
    return raw;
  }

  NeteaseRequest request(
    String path, {
    bool web = false,
    bool plain = false,
    bool desktop = false,
    String? domain,
    Map<String, Object?> body = const <String, Object?>{},
  }) => NeteaseRequest(
    path: path,
    payload: body,
    encoding: plain
        ? NeteaseEncoding.api
        : (web ? NeteaseEncoding.weapi : NeteaseEncoding.eapi),
    mobileClient: alias.startsWith('/listentogether/'),
    desktopClient: desktop,
    domain: domain,
  );

  Map<String, Object?> page({int defaultLimit = 30}) => <String, Object?>{
    'limit': value('limit', defaultLimit.toString()),
    'offset': value('offset', '0'),
  };

  switch (alias) {
    case '/login/cellphone':
      return request(
        '/api/w/login/cellphone',
        web: true,
        body: <String, Object?>{
          'type': '1',
          'https': 'true',
          'phone': value('phone'),
          'countrycode': value('countrycode', '86'),
          'remember': 'true',
          'secureCaptcha': value('sca'),
          if (value('captcha').isNotEmpty)
            'captcha': value('captcha')
          else
            'password':
                parameters['md5_password'] ?? gatewayMd5(value('password')),
        },
      );
    case '/login':
      return request(
        '/api/w/login',
        body: <String, Object?>{
          'type': '0',
          'https': 'true',
          'username': value('email'),
          'password':
              parameters['md5_password'] ?? gatewayMd5(value('password')),
          'rememberLogin': 'true',
        },
      );
    case '/login/qr/key':
      // Plain `/api/` surface, exactly like the official desktop client
      // (`page:loginQrcode` → `/api/login/qrcode/unikey`). The confirmed login
      // is only handed back to a poller on this surface.
      return request(
        '/api/login/qrcode/unikey',
        plain: true,
        body: <String, Object?>{'type': 3},
      );
    case '/login/qr/check':
      return request(
        '/api/login/qrcode/client/login',
        plain: true,
        body: <String, Object?>{
          'key': value('key'),
          'type': 3,
          // The desktop client always sends it; it carries the Yidun captcha
          // token when the scan hit risk control (8821).
          'secureCaptcha': value('secureCaptcha'),
        },
      );
    case '/login/status':
      return request('/api/w/nuser/account/get', web: true);
    case '/login/refresh':
      return request('/api/login/token/refresh');
    case '/logout':
      return request('/api/logout');
    case '/register/anonimous':
      throw UnsupportedError(
        'Anonymous registration requires an unsupported upstream handshake.',
      );
    case '/captcha/sent/v1':
      return request(
        '/api/middle/captcha/sent/v1',
        body: <String, Object?>{
          'ctcode': value('ctcode', '86'),
          'secrete': 'music_middleuser_pclogin',
          'cellphone': value('phone'),
          'scene': '0',
        },
      );
    case '/search':
    case '/cloudsearch':
      final bool voice = alias == '/search' && value('type') == '2000';
      final String path = voice
          ? '/api/search/voice/get'
          : alias == '/cloudsearch'
          ? '/api/cloudsearch/pc'
          : '/api/search/get';
      return request(
        path,
        body: <String, Object?>{
          if (voice)
            'keyword': value('keywords')
          else ...<String, Object?>{
            's': value('keywords'),
            'type': value('type', '1'),
          },
          ...page(),
          if (alias == '/cloudsearch') 'total': true,
        },
      );
    case '/search/default':
      return request('/api/search/defaultkeyword/get');
    case '/search/hot/detail':
      return request('/api/hotsearchlist/get', web: true);
    case '/search/suggest':
      return request(
        value('type') == 'mobile'
            ? '/api/search/suggest/keyword'
            : '/api/search/suggest/web',
        web: true,
        body: <String, Object?>{'s': value('keywords')},
      );
    case '/song/detail':
      return request(
        '/api/v3/song/detail',
        web: true,
        body: <String, Object?>{'c': _songIdPayload(value('ids'))},
      );
    case '/song/url/v1':
      if (value('unblock', 'false') != 'false') {
        throw UnsupportedError('External music matching is not supported.');
      }
      final AudioQuality quality =
          AudioQualityInfo.fromLevel(value('level', 'exhigh')) ??
          (throw UnsupportedError(
            'This audio quality requires an unsupported upstream handshake.',
          ));
      return request(
        '/api/song/enhance/player/url',
        web: true,
        body: <String, Object?>{
          'ids': _songIds(value('id')).toString(),
          'br': quality.bitrate,
        },
      );
    case '/check/music':
      return request(
        '/api/song/enhance/player/url',
        web: true,
        body: <String, Object?>{
          'ids': '[${id()}]',
          'br': int.tryParse(value('br', '999000')) ?? 999000,
        },
      );
    case '/lyric':
      return request(
        '/api/song/lyric',
        body: <String, Object?>{
          'id': id(),
          'tv': -1,
          'lv': -1,
          'rv': -1,
          'kv': -1,
          '_nmclfl': 1,
        },
      );
    case '/lyric/new':
      return request(
        '/api/song/lyric/v1',
        body: <String, Object?>{
          'id': id(),
          'cp': false,
          for (final String counter in const <String>[
            'tv',
            'lv',
            'rv',
            'kv',
            'yv',
            'ytv',
            'yrv',
          ])
            counter: -1,
        },
      );
    case '/playlist/detail':
      return request(
        '/api/v6/playlist/detail',
        body: <String, Object?>{'id': id(), 'n': 100000, 's': value('s', '8')},
      );
    case '/playlist/create':
      final String name = value('name').trim();
      if (name.isEmpty || name.length > 40) {
        throw ArgumentError.value(name, 'name', 'must be 1-40 characters.');
      }
      return request(
        '/api/playlist/create',
        web: true,
        body: <String, Object?>{
          'name': name,
          // NetEase: '10' is a private playlist, '0' is public.
          'privacy': value('privacy', '0') == '10' ? '10' : '0',
          'type': 'NORMAL',
        },
      );
    case '/playlist/tracks':
      final String op = value('op', 'add');
      if (op != 'add' && op != 'del') {
        throw ArgumentError.value(op, 'op', 'must be add or del.');
      }
      return request(
        '/api/playlist/manipulate/tracks',
        web: true,
        body: <String, Object?>{
          'op': op,
          'pid': id('pid'),
          // The service expects a JSON array of ids, not a form list.
          'trackIds': '[${_songIds(value('tracks')).join(',')}]',
          'imme': 'true',
        },
      );
    case '/playlist/delete':
      return request(
        '/api/playlist/delete',
        web: true,
        body: <String, Object?>{'pid': id('pid')},
      );
    case '/user/playlist':
      return request(
        '/api/user/playlist',
        web: true,
        body: <String, Object?>{
          'uid': id('uid'),
          ...page(),
          'includeVideo': true,
        },
      );
    case '/top/playlist':
      return request(
        '/api/playlist/list',
        web: true,
        body: <String, Object?>{
          'cat': value('cat', '全部'),
          'order': value('order', 'hot'),
          ...page(defaultLimit: 50),
          'total': true,
        },
      );
    case '/toplist/detail':
      return request('/api/toplist/detail', web: true);
    case '/user/detail':
      return request('/api/v1/user/detail/${id('uid')}', web: true);
    case '/comment/music':
      return request(
        '/api/v1/resource/comments/R_SO_4_${id()}',
        web: true,
        body: <String, Object?>{
          'rid': id(),
          'limit': value('limit', '20'),
          'offset': value('offset', '0'),
          'beforeTime': value('before', '0'),
        },
      );
    case '/comment/like':
    case '/comment/unlike':
      final action = alias == '/comment/like' ? 'like' : 'unlike';
      return request(
        '/api/v1/comment/$action',
        web: true,
        body: <String, Object?>{
          'threadId': 'R_SO_4_${id()}',
          'commentId': id('commentId'),
        },
      );
    case '/comment/reply':
      return request(
        '/api/resource/comments/reply',
        body: <String, Object?>{
          'threadId': 'R_SO_4_${id()}',
          'commentId': id('commentId'),
          'content': value('content'),
        },
      );
    case '/album':
      return request('/api/v1/album/${id()}', web: true);
    case '/artist/detail':
      return request(
        '/api/artist/head/info/get',
        body: <String, Object?>{'id': id()},
      );
    case '/artist/top/song':
      return request(
        '/api/artist/top/song',
        web: true,
        body: <String, Object?>{'id': id()},
      );
    case '/artist/songs':
      return request(
        '/api/v1/artist/songs',
        body: <String, Object?>{
          'id': id(),
          'order': value('order'),
          ...page(),
          'private_cloud': 'true',
          'work_type': 1,
        },
      );
    case '/artist/album':
      return request(
        '/api/artist/albums/${id()}',
        web: true,
        body: <String, Object?>{...page(), 'total': true},
      );
    case '/simi/artist':
      return request(
        '/api/discovery/simiArtist',
        web: true,
        body: <String, Object?>{'artistid': id()},
      );
    case '/banner':
      return request(
        '/api/v2/banner/get',
        body: <String, Object?>{
          'clientType': switch (value('type')) {
            '1' => 'android',
            '2' => 'iphone',
            '3' => 'ipad',
            _ => 'pc',
          },
        },
      );
    case '/recommend/songs':
      return request(
        '/api/v3/discovery/recommend/songs',
        web: true,
        body: <String, Object?>{
          if (parameters['afresh'] != null) 'afresh': parameters['afresh'],
        },
      );
    case '/recommend/resource':
      return request('/api/v1/discovery/recommend/resource', web: true);
    case '/personalized':
      return request(
        '/api/personalized/playlist',
        web: true,
        body: {'limit': value('limit', '30'), 'total': true, 'n': 1000},
      );
    case '/personalized/newsong':
      return request(
        '/api/personalized/newsong',
        web: true,
        body: <String, Object?>{
          'type': 'recommend',
          'limit': value('limit', '20'),
          'areaId': value('areaId', '0'),
        },
      );
    case '/personal_fm':
      return request('/api/v1/radio/get', web: true);
    case '/playmode/intelligence/list':
      return request(
        '/api/playmode/intelligence/list',
        body: <String, Object?>{
          'songId': id(),
          'type': 'fromPlayOne',
          'playlistId': id('pid'),
          'startMusicId': value('sid', value('id')),
          'count': value('count', '1'),
        },
      );
    case '/v1/play/record':
      return request(
        '/api/v1/play/record',
        web: true,
        body: <String, Object?>{'uid': id('uid'), 'type': value('type', '0')},
      );
    case '/feedback/weblog':
      // The play-record deposit is not the ordinary interface host: the
      // official player posts its client-log entries to the client-log host
      // through the eapi envelope, which is the surface the account's
      // 最近播放 and 听歌排行 are built from. The webapi copy is accepted but
      // does not reach that store.
      return request(
        '/api/feedback/weblog',
        desktop: true,
        domain: 'https://clientlog.music.163.com',
        body: <String, Object?>{'logs': value('logs')},
      );
    case '/likelist':
      return request(
        '/api/song/like/get',
        body: <String, Object?>{'uid': id('uid')},
      );
    case '/song/like':
      return request(
        '/api/song/like',
        body: <String, Object?>{
          'trackId': id(),
          'userid': id('uid'),
          'like': value('like') != 'false',
        },
      );
    case '/listentogether/room/create':
      return request(
        '/api/listen/together/room/create',
        body: <String, Object?>{'refer': 'songplay_more'},
      );
    case '/listentogether/multi/room/create':
      return request(
        '/api/listen/together/multi/room/create',
        body: <String, Object?>{
          'type': value('type', '0'),
          'songId': id(),
          'from': 'CREATE',
          'playedTime': value('playedTime', '0'),
          'groupIds': _idArray(value('groupIds')),
          'inviteUids': _idArray(value('inviteUids')),
          'nextSongIds': _idArray(value('nextSongIds')),
          'checkToken': '',
        },
      );
    case '/listentogether/accept':
      return request(
        '/api/listen/together/play/invitation/accept',
        body: <String, Object?>{
          'refer': 'inbox_invite',
          'roomId': roomId(),
          'inviterId': id('inviterId'),
        },
      );
    case '/listentogether/room/check':
      return request(
        '/api/listen/together/room/check',
        body: <String, Object?>{'roomId': roomId()},
      );
    case '/listentogether/status':
      return request('/api/listen/together/status/get', web: true);
    case '/listentogether/end':
      return request(
        '/api/listen/together/end/v2',
        body: <String, Object?>{'roomId': roomId()},
      );
    case '/listentogether/heartbeat':
      return request(
        '/api/listen/together/heartbeat',
        body: <String, Object?>{
          'roomId': roomId(),
          'songId': value('songId', '0'),
          'playStatus': value('playStatus'),
          'progress': value('progress'),
          'playlistVersion': value('playlistVersion', '[]'),
        },
      );
    case '/listentogether/play/command':
      return request(
        '/api/listen/together/play/command/report',
        body: <String, Object?>{
          'roomId': roomId(),
          'commandInfo': value('commandInfo'),
        },
      );
    case '/listentogether/sync/list/command':
      return request(
        '/api/listen/together/sync/list/command/report',
        body: <String, Object?>{
          'roomId': roomId(),
          'playlistParam': value('playlistParam'),
        },
      );
    case '/listentogether/sync/playlist/get':
      return request(
        '/api/listen/together/sync/playlist/get',
        body: <String, Object?>{'roomId': roomId()},
      );
    case '/like':
      return request(
        '/api/radio/like',
        web: true,
        body: <String, Object?>{
          'alg': 'itembased',
          'trackId': id(),
          'like': value('like') != 'false',
          'time': '3',
        },
      );
    default:
      throw ArgumentError('Unsupported built-in Gateway route.');
  }
}

List<int> _songIds(String value) {
  return value
      .split(',')
      .map((String raw) {
        final int? parsed = int.tryParse(raw.trim());
        if (parsed == null || parsed <= 0) {
          throw ArgumentError.value(
            value,
            'ids',
            'Song IDs must be positive integers.',
          );
        }
        return parsed;
      })
      .toList(growable: false);
}

String _songIdPayload(String value) =>
    '[${_songIds(value).map((int id) => '{"id":$id}').join(',')}]';

String _idArray(String value) =>
    value.trim().isEmpty ? '[]' : _songIds(value).toString();
