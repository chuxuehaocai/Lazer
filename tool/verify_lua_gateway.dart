// Opt-in live verification. Credentials stay in a temporary directory and are
// never included in console output, fixtures, reports or the plugin archive.
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';

import 'package:lazer_nextgen/gateway/lua_music_gateway.dart';
import 'package:lazer_nextgen/gateway/music_gateway.dart';
import 'package:lazer_nextgen/plugins/lua_plugin_runtime.dart';
import 'package:lazer_nextgen/plugins/plugin_manifest.dart';

Future<void> main(List<String> arguments) async {
  if (arguments.length != 2) {
    stderr.writeln(
      'Usage: dart run tool/verify_lua_gateway.dart <plugin.zip> <cookie-file>',
    );
    exitCode = 64;
    return;
  }
  final archive = ZipDecoder().decodeBytes(
    await File(arguments[0]).readAsBytes(),
    verify: true,
  );
  final manifest = PluginManifest.decode(
    utf8.decode(archive.findFile('manifest.json')!.content),
  );
  final sources = {
    for (final file in archive.where(
      (file) => file.isFile && file.name.endsWith('.lua'),
    ))
      file.name: utf8.decode(file.content),
  };
  final directory = await Directory.systemTemp.createTemp(
    'lazer-gateway-verification-',
  );
  final runtimes = <LuaPluginRuntime>[];
  LuaMusicGateway create(String path) {
    final runtime = LuaPluginRuntime(
      manifest: manifest,
      sources: sources,
      dataDirectory: path,
      timeout: const Duration(seconds: 90),
    );
    runtimes.add(runtime);
    return LuaMusicGateway(
      runtime: runtime,
      provider: MusicProvider(id: manifest.provider, name: manifest.name),
      connectionId: manifest.id,
    );
  }

  Future<T> check<T>(String name, Future<T> Function() body) async {
    try {
      final result = await body();
      stdout.writeln('$name: PASS');
      return result;
    } catch (error) {
      stderr.writeln(
        '$name: FAIL (${error.runtimeType}${error is PluginException ? ', code=${error.code}' : ''})',
      );
      rethrow;
    }
  }

  void require(bool value) {
    if (!value) throw const FormatException('Verification assertion failed');
  }

  try {
    final gateway = create('${directory.path}/account');
    await check('lua_platform_description', () async {
      final value = await gateway.runtime.invoke('describe');
      require(
        value is Map &&
            value['providers'] is List &&
            (value['providers'] as List).isNotEmpty,
      );
    });
    final anonymous = create('${directory.path}/qr');
    final key = await check('qr_key', () async {
      final key = await anonymous.qrKey();
      require(key != null && key.isNotEmpty);
      return key!;
    });
    await check('qr_url_and_poll', () async {
      final url = await anonymous.qrUrl(key);
      require(Uri.tryParse(url)?.queryParameters['codekey'] == key);
      require({801, 802, 800}.contains(await anonymous.qrCheck(key)));
    });
    final cookie = await File(arguments[1]).readAsString();
    final account = await check('cookie_login', () async {
      final user = await gateway.loginWithCookie(cookie);
      require(user != null && user.id.value.isNotEmpty && user.name.isNotEmpty);
      return user!;
    });
    await check(
      'session',
      () async => require((await gateway.checkSession())?.id == account.id),
    );
    final results = await check('search', () async {
      final result = await gateway.search('周杰伦', limit: 3);
      require(result.songs.items.isNotEmpty);
      return result;
    });
    final song = await check('song_metadata', () async {
      final song = await gateway.song(results.songs.items.first.id);
      require(song.title.isNotEmpty && song.artists.isNotEmpty);
      return song;
    });
    if (song.albumId != null) {
      await check('album_and_pagination', () async {
        final album = await gateway.album(song.albumId!);
        require(album.title.isNotEmpty);
        final first = await gateway.albumSongs(song.albumId!, limit: 2);
        final second = await gateway.albumSongs(
          song.albumId!,
          limit: 2,
          offset: 2,
        );
        require(first.items.isNotEmpty);
        if (second.items.isNotEmpty) {
          require(first.items.first.id != second.items.first.id);
        }
      });
    }
    if (song.artists.isNotEmpty) {
      await check('artist_and_albums', () async {
        final artist = await gateway.artist(song.artists.first.id);
        require(artist.name.isNotEmpty);
        await gateway.artistAlbums(artist.id, limit: 2);
      });
    }
    await check('saved_albums', () async {
      await gateway.albums(limit: 3);
    });
    final playlists = await check(
      'playlists',
      () async => gateway.playlists(limit: 2),
    );
    if (playlists.items.isNotEmpty) {
      await check('playlist_metadata_and_tracks', () async {
        final playlist = await gateway.playlist(playlists.items.first.id);
        require(playlist.name.isNotEmpty);
        final first = await gateway.playlistSongs(playlist.id, limit: 2);
        final second = await gateway.playlistSongs(
          playlist.id,
          limit: 2,
          offset: 2,
        );
        if (second.items.isNotEmpty) {
          require(first.items.first.id != second.items.first.id);
        }
      });
    }
    await check('favorites', () async {
      await gateway.favorites(limit: 3);
    });
    await check('complete_library_pagination', () async {
      var offset = 0;
      while (true) {
        final page = await gateway.favorites(limit: 100, offset: offset);
        if (!page.hasMore || page.items.isEmpty) break;
        offset = page.nextOffset;
        require(offset < 100000);
      }
    });
    await check('recommendations', () async {
      require((await gateway.recommendations(limit: 3)).items.isNotEmpty);
    });
    if (manifest.capabilities.contains('homeFeed')) {
      await check('provider_home_feed', () async {
        final feed = await gateway.homeFeed();
        require(
          feed.quick.isNotEmpty ||
              feed.daily.isNotEmpty ||
              feed.playlists.isNotEmpty ||
              feed.albums.isNotEmpty,
        );
        if (manifest.provider == 'netease') {
          require(feed.editorialPlaylists.isNotEmpty);
          require(
            feed.editorialPlaylists.any(
              (item) => item.coverUrl?.isNotEmpty == true,
            ),
          );
        }
      });
    }
    if (manifest.capabilities.contains('savedAlbums')) {
      await check('saved_albums', () async {
        await gateway.savedAlbums(limit: 3);
      });
    }
    if (manifest.capabilities.contains('charts')) {
      await check('provider_charts', () async {
        require((await gateway.charts()).isNotEmpty);
      });
    }
    if (manifest.capabilities.contains('radio')) {
      await check('personal_radio', () async {
        await gateway.radio(MusicRadioKind.personal, limit: 3);
      });
    }
    if (manifest.capabilities.contains('comments')) {
      await check('song_comments', () async {
        final page = await gateway.comments(song.id, limit: 3);
        require(page.containsKey('total') && page.containsKey('latest'));
      });
    }
    await check('lyrics', () async {
      await gateway.lyrics(song.id);
    });
    await check('play_statistics', () async {
      await gateway.playStats(limit: 3);
    });
    await check('stream_and_media_bytes', () async {
      MusicStream? stream;
      for (final candidate in results.songs.items) {
        try {
          stream = await gateway.stream(
            candidate.id,
            quality: MusicStreamQuality.high,
          );
          break;
        } catch (_) {
          /* A regional or membership restriction can affect one song. */
        }
      }
      require(stream != null && {'http', 'https'}.contains(stream.uri.scheme));
      final client = HttpClient();
      try {
        final request = await client
            .getUrl(stream!.uri)
            .timeout(const Duration(seconds: 20));
        request.headers.set('Range', 'bytes=0-16383');
        final response = await request.close().timeout(
          const Duration(seconds: 20),
        );
        require(response.statusCode == 200 || response.statusCode == 206);
        require((await response.first).isNotEmpty);
      } finally {
        client.close(force: true);
      }
    });
    gateway.close();
    final restored = create('${directory.path}/account');
    await check('restart_auto_login', () async {
      require((await restored.checkSession())?.id == account.id);
    });
    await check('invalid_login_preserves_session', () async {
      final invalid = await restored.loginWithCookie(
        'MUSIC_U=invalid-development-fixture',
      );
      require(invalid == null);
      require((await restored.checkSession())?.id == account.id);
    });
    await check('local_logout_persists', () async {
      await restored.logout();
      restored.close();
      final signedOut = create('${directory.path}/account');
      require(await signedOut.checkSession() == null);
    });
  } catch (_) {
    exitCode = 1;
  } finally {
    for (final runtime in runtimes) {
      runtime.close();
    }
    await directory.delete(recursive: true);
  }
}
