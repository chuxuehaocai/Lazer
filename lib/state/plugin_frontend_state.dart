part of 'app_state.dart';

/// Data-only frontend API. Consent is enforced by PluginManager before this
/// handler is reached. Credentials, local paths and stream URLs are omitted.
extension _PluginFrontendState on AppState {
  int _pluginPageNumber(Object? value, int fallback, int maximum) =>
      value is num && value.isFinite
      ? value.toInt().clamp(0, maximum)
      : fallback;

  Map<String, Object?> _pluginPlaylist(Playlist list) => {
    'id': list.id,
    'name': list.name,
    'description': list.description,
    'coverUrl': _pluginArtwork(list.coverUrl),
    'trackCount': list.trackCount,
  };

  Map<String, Object?> _pluginPage<T>(
    List<T> values,
    Map<String, dynamic> spec,
    Object? Function(T) encode,
  ) {
    final offset = _pluginPageNumber(spec['offset'], 0, 1000000);
    final limit = _pluginPageNumber(spec['limit'], 50, 200).clamp(1, 200);
    return {
      'items': values.skip(offset).take(limit).map(encode).toList(),
      'offset': offset,
      'limit': limit,
      'total': values.length,
      'hasMore': offset + limit < values.length,
    };
  }

  MusicGateway _pluginGateway(Map<String, dynamic> spec, [String? key]) {
    final id = key == null ? null : MusicId.tryParse(key);
    final gateway = id == null
        ? catalog.activeGateway
        : catalog.connections.resolve(id);
    // A provider VM cannot await a new call to itself while its current Lua
    // operation is suspended. Frontend plugins can use any other provider.
    if (gateway is LuaMusicGateway &&
        gateway.pluginId == spec['_callerPluginId']) {
      throw const PluginException(
        'Use the provider Lua functions directly for its own catalogue',
        code: 409,
      );
    }
    return gateway;
  }

  String _pluginEntityId(Map<String, dynamic> spec) {
    final id = spec['id'] ?? spec['playlistId'];
    if (id is! String || id.trim().isEmpty || id.length > 1024) {
      throw const FormatException('A catalogue id is required');
    }
    return id;
  }

  Future<Object?> _pluginFrontendRequest(
    String command,
    Map<String, dynamic> spec,
  ) async {
    switch (command) {
      case 'library_playlists':
        _pluginGateway(spec);
        if (isLocalPlayback) {
          return _pluginPage<Playlist>([], spec, _pluginPlaylist);
        }
        final lists = await userCollections();
        return _pluginPage(
          [
            if (lists.liked != null) lists.liked!,
            ...lists.created,
            ...lists.subscribed,
          ],
          spec,
          _pluginPlaylist,
        );
      case 'library_local':
        await localLibrary.load();
        return _pluginPage(localLibrary.playableTracks, spec, _pluginTrack);
      case 'library_tracks':
      case 'library_album':
        final id = _pluginEntityId(spec);
        _pluginGateway(spec, id);
        final tracks = command == 'library_album'
            ? await catalog.albumTracksFor(id)
            : await catalog.playlistTracks(id);
        return _pluginPage(tracks, spec, _pluginTrack);
      case 'library_search':
        _pluginGateway(spec);
        final query = spec['query'];
        if (query is! String || query.trim().isEmpty || query.length > 256) {
          throw const FormatException(
            'Search query must contain 1-256 characters',
          );
        }
        final result = await search(query);
        return {
          'tracks': _pluginPage(result.tracks, spec, _pluginTrack),
          'playlists': _pluginPage(result.playlists, spec, _pluginPlaylist),
          'albums': _pluginPage(
            result.albums,
            spec,
            (album) => {
              'id': album.id,
              'title': album.title,
              'artist': album.artist,
              'coverUrl': _pluginArtwork(album.coverUrl),
              'trackCount': album.trackCount,
            },
          ),
          'artists': _pluginPage(
            result.artists,
            spec,
            (artist) => {
              'id': artist.key,
              'name': artist.name,
              'coverUrl': _pluginArtwork(artist.coverUrl),
            },
          ),
        };
      case 'library_play':
        final id = _pluginEntityId(spec);
        final gateway = _pluginGateway(spec, id);
        final kind = spec['kind'] ?? 'playlist';
        final List<Track> tracks;
        if (kind == 'song') {
          final local = localLibrary.playableTracks
              .where((track) => track.id == id)
              .firstOrNull;
          if (local != null) {
            tracks = [local];
          } else {
            final musicId = MusicId.tryParse(id);
            if (musicId == null || musicId.kind != MusicEntityKind.song) {
              throw const FormatException('A qualified song id is required');
            }
            tracks = [catalog.trackFromMusicSong(await gateway.song(musicId))];
          }
        } else if (kind == 'album') {
          tracks = await catalog.albumTracksFor(id);
        } else if (kind == 'playlist') {
          tracks = await catalog.playlistTracks(id);
        } else {
          throw const FormatException('Unknown catalogue entity kind');
        }
        if (tracks.isEmpty) return false;
        final start = _pluginPageNumber(spec['index'], 0, tracks.length - 1);
        // Loading may outlive its consent. Queue changes are publicly visible
        // through player events and player_queue, so do not publish these
        // tracks unless this exact request's grant is still current.
        final assertAccess = spec['_assertDataAccess'];
        if (assertAccess is! void Function()) {
          throw const PluginException(
            'Plugin data authorization required',
            code: 403,
          );
        }
        assertAccess();
        playQueue(tracks, startIndex: start);
        return true;
      case 'user_profile':
        // An explicit allowlist avoids accidentally exposing authentication
        // detail, cookies, provider storage or future SessionUser fields.
        return {
          'activePlatform': musicProvider.id,
          'activeConnection': activeConnectionKey,
          'accounts': [
            for (final gateway in musicConnections)
              if (gateway.user case final account?)
                {
                  'connection': GatewayRegistry.keyOf(gateway),
                  'platform': gateway.provider.id,
                  'id': account.id.value,
                  'name': account.name,
                  'handle': account.id.cacheKey,
                  'avatarUrl': _pluginArtwork(account.avatarUrl),
                },
          ],
        };
      case 'user_platforms':
        return [
          for (final gateway in musicConnections)
            {
              'id': gateway.provider.id,
              'name': gateway.provider.name,
              'connection': GatewayRegistry.keyOf(gateway),
              'active': identical(gateway, catalog.activeGateway),
              'signedIn': musicAccounts.containsKey(
                GatewayRegistry.keyOf(gateway),
              ),
              'capabilities': gateway.capabilities
                  .map((value) => value.name)
                  .toList(),
            },
        ];
      case 'user_statistics':
        await listeningStatistics.ready;
        final range = ListeningRange.values
            .where((value) => value.name == (spec['range'] ?? 'allTime'))
            .firstOrNull;
        if (range == null) {
          throw const FormatException('Unknown listening range');
        }
        final snapshot = listeningStatistics.snapshot(range);
        Map<String, Object?> entry(ListeningTrackStatistics value) => {
          'track': _pluginTrack(value.track),
          'playCount': value.playCount,
          'skipCount': value.skipCount,
          'durationMs': value.duration.inMilliseconds,
        };
        return {
          'range': range.name,
          'source': 'device',
          'playCount': snapshot.playCount,
          'skipCount': snapshot.skipCount,
          'durationMs': snapshot.totalDuration.inMilliseconds,
          'mostPlayed': _pluginPage(snapshot.mostPlayed, spec, entry),
          'mostSkipped': _pluginPage(snapshot.mostSkipped, spec, entry),
        };
      default:
        throw const FormatException('Unsupported frontend operation');
    }
  }
}

String? _pluginArtwork(String? value) {
  if (value == null) return null;
  final uri = Uri.tryParse(value);
  if (uri == null ||
      uri.userInfo.isNotEmpty ||
      (uri.scheme != 'https' && uri.scheme != 'http')) {
    return null;
  }
  return value;
}
