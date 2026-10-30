part of 'app_state.dart';

class _MusicPlatformState {
  _MusicPlatformState(this.state);
  final AppState state;
  SessionUser neteaseUser = SessionUser.guest;
  final Set<String> liked = {};
  bool busy = false;
  int _request = 0;
  static const _configKey = 'lazer_music_connections_v1';
  static const _selectedKey = 'lazer_music_connection';

  void cancelPending() {
    _request++;
  }

  Future<void> selectNetease() => select(
    GatewayRegistry.keyOf(
      state.musicConnections.firstWhere(
        (gateway) => gateway.provider.id == 'netease',
      ),
    ),
  );

  Future<AuthOutcome> login(
    String server,
    String username,
    String password,
    bool allowHttp,
  ) async {
    if (busy) return const AuthOutcome(false, error: '正在连接音乐服务器。');
    final request = ++_request;
    busy = true;
    state.notifyListeners();
    NavidromeGateway? candidate;
    try {
      candidate =
          state.navidromeFactory?.call(server, username, allowHttp) ??
          NavidromeGateway(
            serverUrl: server,
            username: username,
            allowInsecureHttp: allowHttp,
          );
      await candidate.login(password);
      if (request != _request) {
        candidate.close();
        return const AuthOutcome(false, error: '连接已取消。');
      }
      final key = GatewayRegistry.keyOf(candidate);
      await _resetPlayback();
      if (request != _request) {
        candidate.close();
        return const AuthOutcome(false, error: '连接已取消。');
      }
      if (!state.isNavidrome) neteaseUser = state.user;
      final registry = state.catalog.connections;
      if (registry.connections.any(
        (gateway) => GatewayRegistry.keyOf(gateway) == key,
      )) {
        registry.remove(key);
      }
      registry.add(candidate);
      _activate(key);
      candidate = null;
      await _save();
      unawaited(state.refreshHome());
      return const AuthOutcome(true);
    } catch (error) {
      candidate?.close();
      return AppState._failure(error);
    } finally {
      busy = false;
      if (!state._presentationDisposed) state.notifyListeners();
    }
  }

  Future<void> select(String key) async {
    if (key == state.activeConnectionKey || busy) return;
    if (!state.musicConnections.any(
      (gateway) => GatewayRegistry.keyOf(gateway) == key,
    )) {
      throw ArgumentError('Unknown music connection.');
    }
    final request = ++_request;
    busy = true;
    state.notifyListeners();
    try {
      if (!state.isNavidrome) neteaseUser = state.user;
      await _resetPlayback();
      if (request != _request) return;
      _activate(key);
      await _save();
      unawaited(state.refreshHome());
    } finally {
      busy = false;
      if (!state._presentationDisposed) state.notifyListeners();
    }
  }

  Future<void> _resetPlayback() async {
    state._finishPlaySession();
    await state._flushPlayUploads();
    await state.listenTogether.leave();
    state.pause();
    state._realActive = false;
    state._queuedNextIndex = null;
    state._queueId = null;
    state._generation++;
    state._lyricGeneration++;
    await state.audioEngine?.stop();
    state._queue = [];
    state._queueIndex = 0;
    state._markQueueChanged();
    state._position = Duration.zero;
    state._stationLoader = null;
    state._stationLoading = false;
    state._stationSeen.clear();
    state.lyrics = const [];
    state.lyricsLoading = false;
    state.lyricsPureMusic = false;
    state.lyricsImported = false;
    state.lyricsError = null;
    state._lyricsTrackId = null;
    state._metadataLoaded.clear();
    await state._saveQueue();
  }

  void _activate(String key) {
    state.catalog.selectConnection(key);
    final gateway = state.catalog.activeGateway;
    final user = gateway.user;
    state._user = gateway.provider.id == 'netease'
        ? neteaseUser
        : user == null
        ? SessionUser.guest
        : SessionUser(
            name: user.name,
            handle: user.id.cacheKey,
            method: AuthMethod.password,
            detail: 'Navidrome',
            userId: 1,
          );
    state.collections = UserCollections.empty;
    state.collectionsLoading = false;
    state.collectionsError = null;
    state._collectionsPending = null;
    state.playStats = const [];
    state._playStatsUid = null;
    state.playStatsLoading = false;
    state.discoveryCharts = const [];
    state.discoveryChartsError = null;
    state.playbackError = null;
    state.likeError = null;
    state.notifyListeners();
  }

  Future<void> restore() async {
    neteaseUser = state.user;
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = jsonDecode(prefs.getString(_configKey) ?? '[]');
      if (saved is List) {
        for (final config in saved.whereType<Map<String, dynamic>>()) {
          try {
            final gateway =
                state.navidromeFactory?.call(
                  config['server'] as String,
                  config['username'] as String,
                  config['http'] == true,
                ) ??
                NavidromeGateway(
                  serverUrl: config['server'] as String,
                  username: config['username'] as String,
                  allowInsecureHttp: config['http'] == true,
                );
            state.catalog.connections.add(gateway);
          } catch (_) {
            // A malformed saved connection must not hide the working account.
          }
        }
      }
      final selected = prefs.getString(_selectedKey);
      if (selected != null &&
          state.musicConnections.any(
            (gateway) => GatewayRegistry.keyOf(gateway) == selected,
          )) {
        _activate(selected);
      }
    } catch (_) {}
  }

  Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _configKey,
        jsonEncode([
          for (final gateway
              in state.musicConnections.whereType<NavidromeGateway>())
            {
              'server': gateway.server.toString(),
              'username': gateway.username,
              'http': gateway.server.scheme == 'http',
            },
        ]),
      );
      await prefs.setString(_selectedKey, state.activeConnectionKey);
    } catch (_) {}
  }

  Future<Playlist> createPlaylist(String name, bool privacy) async {
    final gateway = state.catalog.activeGateway;
    final created = await gateway.createPlaylist(name, isPublic: !privacy);
    final playlist = state.catalog.playlistFromMusicPlaylist(created);
    if (identical(state.catalog.activeGateway, gateway)) {
      await state.refreshCollections(force: true);
    }
    return playlist;
  }

  Future<void> addSong(String playlistKey, String songKey) async {
    final playlist = MusicId.tryParse(playlistKey);
    final song = MusicId.tryParse(songKey);
    if (playlist == null ||
        song == null ||
        playlist.connection != song.connection ||
        playlist.provider != song.provider) {
      throw ArgumentError('歌曲和歌单必须属于同一个音乐平台账号。');
    }
    final gateway = state.catalog.connections.resolve(playlist);
    if (playlist.value == '__lazer_favorites__') {
      await gateway.setFavorite(song, true);
      liked.add(song.cacheKey);
    } else {
      await gateway.addToPlaylist(playlist, [song]);
    }
    await state.refreshCollections(force: true);
  }

  Future<void> toggleLike() async {
    final key = state.current?.id;
    final id = MusicId.tryParse(key ?? '');
    if (id == null) return;
    final gateway = state.catalog.connections.resolve(id);
    if (gateway.user == null) return;
    final favorite = !liked.contains(key);
    try {
      await gateway.setFavorite(id, favorite);
      favorite ? liked.add(key!) : liked.remove(key);
      state.likeError = null;
      await state.refreshCollections(force: true);
    } catch (_) {
      state.likeError = '收藏失败，请稍后重试。';
    }
    if (!state._presentationDisposed) state.notifyListeners();
  }

  Future<void> hydrate(Track track, MusicId id) async {
    final request = _request;
    state._metadataPending.add(track.id);
    try {
      final value = await state.catalog.connections.resolve(id).song(id);
      if (state._presentationDisposed || request != _request) return;
      final updated = state.catalog.trackFromMusicSong(value);
      state._queue = [
        for (final entry in state._queue)
          if (entry.id == track.id)
            updated.copyWith(localPath: entry.localPath)
          else
            entry,
      ];
      state._metadataLoaded.add(track.id);
      state._markQueueChanged();
      unawaited(state.refreshArtworkSeed());
      unawaited(state._saveQueue());
      if (!state._presentationDisposed) state.notifyListeners();
    } catch (_) {
      // Metadata can retry when the account is reconnected.
    } finally {
      state._metadataPending.remove(track.id);
    }
  }

  Future<void> report(Track track, Duration played, bool submission) async {
    try {
      final id = MusicId.tryParse(track.id)!;
      await state.catalog.connections
          .resolve(id)
          .scrobble(id, played: played, submission: submission);
    } catch (_) {
      // Playback remains available when the server cannot record a listen.
    }
  }
}
