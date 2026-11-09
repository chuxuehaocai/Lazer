import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/network/ftp_source.dart';
import 'package:lazer_nextgen/network/network_library.dart';
import 'package:lazer_nextgen/network/network_source.dart';
import 'package:lazer_nextgen/network/podcast_feed.dart';
import 'package:lazer_nextgen/network/radio_station.dart';
import 'package:lazer_nextgen/network/remote_source.dart';

void main() {
  group('remote paths', () {
    test('normalize keeps a root anchor and resolves dot segments', () {
      expect(remoteNormalize(''), '/');
      expect(remoteNormalize('Music/Album'), '/Music/Album');
      expect(remoteNormalize('/Music//Album/'), '/Music/Album');
      expect(remoteNormalize('/Music/../Album'), '/Album');
      expect(remoteNormalize('../..'), '/');
    });

    test('join, parent, name and within agree with each other', () {
      expect(remoteJoin('/Music', 'Album'), '/Music/Album');
      expect(remoteParent('/Music/Album/song.flac'), '/Music/Album');
      expect(remoteParent('/song.flac'), '/');
      expect(remoteName('/Music/Album/song.flac'), 'song.flac');
      expect(remoteName('/'), '');
      expect(remoteIsWithin('/Music', '/Music/Album/a.flac'), isTrue);
      expect(remoteIsWithin('/Music', '/Music'), isTrue);
      expect(remoteIsWithin('/Music', '/Movies/a.flac'), isFalse);
    });

    test('SMB splits its path into a share and a folder', () {
      expect(smbSplitShare('Music'), ('Music', '/'));
      expect(smbSplitShare('/Music/Album/'), ('Music', '/Album'));
      expect(smbSplitShare(''), ('', '/'));
    });

    test('extension classification drives what the browser shows', () {
      const RemoteEntry flac = RemoteEntry(
        name: 'song.FLAC',
        path: '/song.FLAC',
        isDirectory: false,
      );
      const RemoteEntry folder = RemoteEntry(
        name: 'Music',
        path: '/Music',
        isDirectory: true,
      );
      const RemoteEntry cover = RemoteEntry(
        name: 'cover.jpg',
        path: '/cover.jpg',
        isDirectory: false,
      );
      expect(flac.isAudio, isTrue);
      expect(folder.isAudio, isFalse);
      expect(cover.isAudio, isFalse);
      expect(audioContentType('song.flac'), 'audio/flac');
      expect(audioContentType('song.unknown'), 'application/octet-stream');
    });
  });

  group('RangeRequest', () {
    test('a missing or foreign header asks for the whole object', () {
      expect(RangeRequest.parse(null, 100), isNull);
      expect(RangeRequest.parse('items=0-3', 100), isNull);
      expect(RangeRequest.parse('bytes=', 100), isNull);
    });

    test('bounded, open and suffix ranges', () {
      expect(RangeRequest.parse('bytes=10-19', 100)!.start, 10);
      expect(RangeRequest.parse('bytes=10-19', 100)!.end, 19);
      expect(RangeRequest.parse('bytes=90-', 100)!.start, 90);
      expect(RangeRequest.parse('bytes=90-', 100)!.end, isNull);
      expect(RangeRequest.parse('bytes=-10', 100)!.start, 90);
      expect(RangeRequest.parse('bytes=-200', 100)!.start, 0);
      // Multiple ranges: only the first is honoured.
      expect(RangeRequest.parse('bytes=5-9,20-29', 100)!.start, 5);
    });

    test('impossible ranges are marked unsatisfiable', () {
      expect(RangeRequest.parse('bytes=100-', 100)!.isUnsatisfiable, isTrue);
      expect(RangeRequest.parse('bytes=20-10', 100)!.isUnsatisfiable, isTrue);
      expect(RangeRequest.parse('bytes=abc-', 100)!.isUnsatisfiable, isTrue);
      expect(RangeRequest.parse('bytes=-0', 100)!.isUnsatisfiable, isTrue);
    });

    test('unknown length still honours the start', () {
      final RangeRequest range = RangeRequest.parse('bytes=4-8', null)!;
      expect(range.start, 4);
      expect(range.end, 8);
    });
  });

  group('network track ids', () {
    test('round-trip source and path', () {
      final String id = networkTrackId('ns-1', '/Music/Album/一首歌.flac');
      final (String source, String path) = decodeNetworkTrackId(id)!;
      expect(source, 'ns-1');
      expect(path, '/Music/Album/一首歌.flac');
      expect(id.startsWith('network:'), isTrue);
      expect(decodeNetworkTrackId('local:abc'), isNull);
      expect(decodeNetworkTrackId('network:not-base64!!'), isNull);
    });

    test('radio and podcast ids are namespaced', () {
      expect(radioTrackId('rs-1'), 'radio:rs-1');
      expect(radioStationIdOf('radio:rs-1'), 'rs-1');
      expect(radioStationIdOf('radio:'), isNull);
      expect(podcastTrackIdOf('pe-1'), 'podcast:pe-1');
      expect(podcastEpisodeIdOf('podcast:pe-1'), 'pe-1');
      expect(podcastEpisodeIdOf('podcast:'), isNull);
    });

    test('owned ids are exactly the three namespaces', () {
      expect(isNetworkOwnedTrackId('network:x'), isTrue);
      expect(isNetworkOwnedTrackId('radio:x'), isTrue);
      expect(isNetworkOwnedTrackId('podcast:x'), isTrue);
      expect(isNetworkOwnedTrackId('local:x'), isFalse);
      expect(isNetworkOwnedTrackId('42'), isFalse);
    });
  });

  group('source drafts', () {
    test('an empty host or an SMB path without a share is refused', () {
      final NetworkSourceDraft draft = NetworkSourceDraft(
        kind: NetworkSourceKind.webdav,
      );
      expect(draft.invalidReason, '请填写服务器地址。');
      draft.host = 'nas.local';
      expect(draft.invalidReason, isNull);
      draft.port = 70000;
      expect(draft.invalidReason, '端口应在 1 到 65535 之间。');
      final NetworkSourceDraft smb = NetworkSourceDraft(
        kind: NetworkSourceKind.smb,
        host: 'nas.local',
      );
      expect(smb.invalidReason, contains('共享名'));
      smb.path = 'Music';
      expect(smb.invalidReason, isNull);
    });

    test('a source round-trips through JSON and keeps its defaults', () {
      final NetworkSource source = NetworkSourceDraft(
        kind: NetworkSourceKind.sftp,
        name: 'NAS',
        host: 'nas.local',
        port: 2222,
        path: '/music',
        username: 'me',
      ).toSource(id: 'ns-1');
      final NetworkSource decoded = NetworkSource.fromJson(source.toJson());
      expect(decoded.id, 'ns-1');
      expect(decoded.kind, NetworkSourceKind.sftp);
      expect(decoded.port, 2222);
      expect(decoded.path, '/music');
      expect(decoded.username, 'me');
      expect(decoded.displayName, 'NAS');
      expect(decoded.address, 'nas.local:2222');
      expect(decoded.rootPath, '/music');
    });

    test('the port falls back to the protocol default', () {
      final NetworkSource source = NetworkSource.fromJson(<String, dynamic>{
        'id': 'x',
        'kind': 'smb',
        'host': 'nas',
      });
      expect(source.port, 445);
      expect(source.address, 'nas');
      expect(source.locationLabel, '未选择共享');
    });

    test('SMB always dials 445, whatever the draft said', () {
      final NetworkSource source = NetworkSourceDraft(
        kind: NetworkSourceKind.smb,
        host: 'nas',
        port: 1445,
        path: 'Music',
      ).toSource(id: 's');
      expect(source.port, 445);
      expect(source.address, 'nas');
      expect(source.connection(password: '').port, 445);
    });

    test('the SMB root path drops the share', () {
      final NetworkSource source = NetworkSourceDraft(
        kind: NetworkSourceKind.smb,
        host: 'nas',
        path: 'Music/Albums',
      ).toSource(id: 's');
      expect(source.path, 'Music/Albums');
      expect(source.rootPath, '/Albums');
      expect(source.locationLabel, 'Music/Albums');
    });
  });

  group('FTP listing parsers', () {
    test('MLSD facts become entries with sizes and times', () {
      const String body =
          'type=file;size=1024;modify=20240102030405; song.flac\n'
          'type=dir;modify=20240102030405; Album\n'
          'type=cdir; .\n'
          'type=pdir; ..\n';
      final List<RemoteEntry> entries = parseFtpMlsd(body, '/Music');
      expect(entries.length, 2);
      expect(entries.first.name, 'song.flac');
      expect(entries.first.isDirectory, isFalse);
      expect(entries.first.size, 1024);
      expect(entries.first.path, '/Music/song.flac');
      expect(entries.first.modifiedAt, isNotNull);
      expect(entries.last.isDirectory, isTrue);
      expect(entries.last.size, isNull);
    });

    test('UNIX LIST lines keep names with spaces', () {
      const String body =
          'drwxr-xr-x    2 ftp      ftp          4096 Jan 02 12:34 Album Name\n'
          '-rw-r--r--    1 ftp      ftp       1234567 Feb 03  2023 a song.mp3\n'
          'total 12\n';
      final List<RemoteEntry> entries = parseFtpList(body, '/Music');
      expect(entries.length, 2);
      expect(entries.first.name, 'Album Name');
      expect(entries.first.isDirectory, isTrue);
      expect(entries.last.name, 'a song.mp3');
      expect(entries.last.size, 1234567);
      expect(entries.last.modifiedAt!.year, 2023);
    });

    test('MS-DOS LIST lines from IIS are understood', () {
      const String body =
          '01-02-24  03:04PM       <DIR>          Album\n'
          '01-02-24  03:04PM             12345 song.mp3\n';
      final List<RemoteEntry> entries = parseFtpList(body, '/');
      expect(entries.first.isDirectory, isTrue);
      expect(entries.last.size, 12345);
      expect(entries.last.name, 'song.mp3');
    });

    test('timestamps are UTC as the protocol reports them', () {
      final DateTime? time = parseFtpTimestamp('20240102030405');
      expect(time, isNotNull);
      expect(
        time!.toUtc(),
        DateTime.utc(2024, 1, 2, 3, 4, 5),
      );
      expect(parseFtpTimestamp(''), isNull);
    });
  });

  group('radio playlists', () {
    test('M3U keeps EXTINF names and bare URLs', () {
      final List<RadioPlaylistEntry> entries = parseRadioPlaylist(
        '#EXTM3U\n#EXTINF:-1,Jazz FM\nhttp://a.example/stream\n'
        'http://b.example/stream\n',
      );
      expect(entries.length, 2);
      expect(entries.first.name, 'Jazz FM');
      expect(entries.last.name, '网络电台');
      expect(looksLikeRadioPlaylist('http://x/radio.pls'), isTrue);
      expect(looksLikeRadioPlaylist('http://x/stream.mp3'), isFalse);
    });

    test('PLS pairs titles with files, out of order', () {
      final List<RadioPlaylistEntry> entries = parseRadioPlaylist(
        '[playlist]\nFile2=http://b.example/2\nTitle2=Two\n'
        'File1=http://a.example/1\nTitle1=One\nNumberOfEntries=2\n',
      );
      expect(entries.map((RadioPlaylistEntry e) => e.name), <String>[
        'One',
        'Two',
      ]);
    });

    test('ASX and XSPF are read without their namespaces', () {
      final List<RadioPlaylistEntry> asx = parseRadioPlaylist(
        '<asx version="3.0"><entry><title>News</title>'
        '<ref href="http://news.example/live"/></entry></asx>',
      );
      expect(asx.single.name, 'News');
      final List<RadioPlaylistEntry> xspf = parseRadioPlaylist(
        '<playlist><trackList><track><title>Classic</title>'
        '<location>http://classic.example/live</location></track>'
        '</trackList></playlist>',
      );
      expect(xspf.single.url, 'http://classic.example/live');
    });

    test('mirrored stations collapse to one row', () {
      final List<RadioPlaylistEntry> entries = parseRadioPlaylist(
        '[playlist]\n'
        'File1=http://ice5.example.com/live\n'
        'Title1=SomaFM: Groove Salad (#5): chilled beats\n'
        'File2=http://ice2.example.com/live\n'
        'Title2=SomaFM: Groove Salad (#2): chilled beats\n'
        'File3=http://other.example.net/news\n'
        'Title3=News\n',
      );
      expect(entries.length, 2);
      expect(entries.first.url, contains('ice5'));
      expect(entries.last.name, 'News');
    });

    test('duplicate URLs are dropped', () {
      final List<RadioPlaylistEntry> entries = parseRadioPlaylist(
        'http://a.example/1\nhttp://a.example/1\n',
      );
      expect(entries.length, 1);
    });
  });

  group('podcast values', () {
    test('durations accept hh:mm:ss, mm:ss and seconds', () {
      expect(parsePodcastDuration('1:02:03'), const Duration(hours: 1, minutes: 2, seconds: 3));
      expect(parsePodcastDuration('62:03'), const Duration(minutes: 62, seconds: 3));
      expect(parsePodcastDuration('3723'), const Duration(seconds: 3723));
      expect(parsePodcastDuration('3723.5'), const Duration(milliseconds: 3723500));
      expect(parsePodcastDuration(''), isNull);
      expect(parsePodcastDuration('soon'), isNull);
    });

    test('episode ids prefer the GUID and survive a missing one', () {
      expect(podcastEpisodeId('guid-1', 'http://a/1.mp3'), podcastEpisodeId('guid-1', 'http://b/2.mp3'));
      expect(podcastEpisodeId('', 'http://a/1.mp3'), podcastEpisodeId('', 'http://a/1.mp3'));
      expect(podcastEpisodeId('', 'http://a/1.mp3'), isNot(podcastEpisodeId('', 'http://a/2.mp3')));
    });

    test('a subscription keeps the resume point of episodes it still has', () {
      const PodcastEpisode episode = PodcastEpisode(
        id: 'e1',
        title: 'One',
        audioUrl: 'http://a/1.mp3',
      );
      final PodcastSubscription subscription = PodcastSubscription(
        id: 'p',
        feedUrl: 'http://a/feed',
        title: 'Show',
        episodes: const <PodcastEpisode>[episode],
        progress: const <String, PodcastProgress>{
          'e1': PodcastProgress(position: Duration(minutes: 3)),
          'gone': PodcastProgress(position: Duration(minutes: 1)),
        },
      );
      expect(subscription.continueEpisode?.id, 'e1');
      expect(subscription.unplayedCount, 1);
      expect(subscription.copyWith(clearError: true).error, isNull);
    });
  });

  group('indexed entries', () {
    test('a remote file becomes a track with a stable cover seed', () {
      final NetworkTrackEntry entry = NetworkTrackEntry.fromRemote(
        'ns-1',
        const RemoteEntry(
          name: '01 - Artist Name - Song.flac',
          path: '/Music/Album/01 - Artist Name - Song.flac',
          isDirectory: false,
          size: 42,
        ),
        albumFallback: 'NAS',
        now: DateTime(2024),
      );
      expect(entry.title, 'Artist Name - Song');
      expect(entry.artist, '01');
      expect(entry.album, 'Album');
      expect(entry.toTrack().id, entry.id);
      expect(
        entry.coverSeed,
        NetworkTrackEntry.fromRemote(
          'ns-1',
          const RemoteEntry(
            name: '01 - Artist Name - Song.flac',
            path: '/Music/Album/01 - Artist Name - Song.flac',
            isDirectory: false,
            size: 42,
          ),
          albumFallback: 'NAS',
          now: DateTime(2024),
        ).coverSeed,
      );
      final NetworkTrackEntry decoded = NetworkTrackEntry.fromJson(
        jsonDecode(jsonEncode(entry.toJson())) as Map<String, dynamic>,
      );
      expect(decoded.id, entry.id);
      expect(decoded.path, entry.path);
    });

    test('a file without an artist tag falls back to 未知歌手', () {
      final NetworkTrackEntry entry = NetworkTrackEntry.fromRemote(
        'ns-1',
        const RemoteEntry(
          name: 'song.flac',
          path: '/Music/song.flac',
          isDirectory: false,
        ),
        albumFallback: 'NAS',
      );
      expect(entry.artist, '未知歌手');
      expect(entry.album, 'Music');
    });
  });

  group('failure vocabulary', () {
    test('socket failures become unreachable, timeouts stay timeouts', () {
      expect(
        RemoteFailure.from(const SocketException('no route')).kind,
        RemoteFailureKind.unreachable,
      );
      expect(
        RemoteFailure.from(TimeoutException('slow')).kind,
        RemoteFailureKind.timeout,
      );
      expect(
        RemoteFailure.from(const RemoteFailure(RemoteFailureKind.auth)).kind,
        RemoteFailureKind.auth,
      );
    });

    test('each kind has a sentence and an optional diagnostic', () {
      for (final RemoteFailureKind kind in RemoteFailureKind.values) {
        expect(RemoteFailure(kind).message, isNotEmpty);
      }
      const RemoteFailure failure = RemoteFailure(
        RemoteFailureKind.auth,
        detail: 'HTTP 401',
      );
      expect(failure.diagnostic, 'HTTP 401');
      expect(failure.toString(), contains('auth'));
    });
  });
}
