part of 'app_state.dart';

class _MusicPlatformState {
  _MusicPlatformState(this.state);
  final AppState state;
  // A selected connection is a content source, not a global logout. Keep the
  // account snapshot for every connection so local playback can coexist with
  // signed-in platform accounts.
  final Map<String, SessionUser> _sessions = <String, SessionUser>{};
  final Map<String, UserCollections> _collectionsByAccount = {};
  final Map<String, Set<String>> _likesByAccount = {};
  final Set<String> _likesHydrating = <String>{};
  final Set<String> _likesHydrated = <String>{};
  String? _lastSessionKey;
  Set<String> get liked => likesFor(state.catalog.activeGateway);
  Set<String> likesFor(MusicGateway gateway) =>
      _likesByAccount.putIfAbsent(gateway.cacheNamespace, () => <String>{});
  void rememberCollections(MusicGateway gateway, UserCollections value) {
    _collectionsByAccount[gateway.cacheNamespace] = value;
    // The collections snapshot only carries the first page of likes so the
    // library paints immediately. Add instead of replacing, then fill the rest
    // of the liked set in the background — otherwise every song past that page
    // plays without a lit heart.
    likesFor(gateway).addAll(value.liked?.trackIds ?? const <String>[]);
    unawaited(hydrateLikes(gateway));
  }

  /// Walks every favorites page and adds the ids to the liked set. Runs after
  /// the visible library has painted, so a large account never blocks login.
  Future<void> hydrateLikes(MusicGateway gateway) async {
    if (!gateway.supports(MusicCapability.favorites) || gateway.user == null) {
      return;
    }
    final String namespace = gateway.cacheNamespace;
    if (_likesHydrated.contains(namespace) ||
        !_likesHydrating.add(namespace)) {
      return;
    }
    try {
      var offset = 0;
      while (true) {
        if (state._presentationDisposed ||
            gateway.cacheNamespace != namespace ||
            gateway.user == null) {
          return;
        }
        final MusicPage<MusicSong> page = await gateway.favorites(
          limit: 100,
          offset: offset,
        );
        if (state._presentationDisposed ||
            gateway.cacheNamespace != namespace) {
          return;
        }
        final Set<String> likes = likesFor(gateway);
        var changed = false;
        for (final MusicSong song in page.items) {
          if (likes.add(song.id.cacheKey)) changed = true;
        }
        if (changed && !state._presentationDisposed) state.notifyListeners();
        if (!page.hasMore || page.items.isEmpty) {
          _likesHydrated.add(namespace);
          return;
        }
        offset += page.items.length;
      }
    } catch (_) {
      // Leave the first-page snapshot in place; the next refresh retries.
    } finally {
      _likesHydrating.remove(namespace);
    }
  }

  /// A forced refresh must re-walk the likes so a change made elsewhere lands.
  void resetLikesHydration(MusicGateway gateway) {
    final namespace = gateway.cacheNamespace;
    _likesHydrated.remove(namespace);
    _likesHydrating.remove(namespace);
    likesFor(gateway).clear();
  }

  bool isLiked(String key) {
    final id = MusicId.tryParse(key);
    if (id == null) return false;
    try {
      return likesFor(state.catalog.connections.resolve(id)).contains(key);
    } catch (_) {
      return false;
    }
  }

  bool busy = false;
  int _request = 0;
  static const _selectedKey = 'lazer_music_connection';
  static const _lastAccountKey = 'lazer_last_music_account';

  void cancelPending() {
    _request++;
  }

  MusicGateway? get lastSessionGateway {
    final key = _lastSessionKey;
    if (key == null) return null;
    for (final gateway in state.musicConnections) {
      if (GatewayRegistry.keyOf(gateway) == key &&
          _sessionFor(key, gateway) != null) {
        return gateway;
      }
    }
    return null;
  }

  void rememberActiveSession() {
    final current = state.user;
    if (current.isGuest || state.catalog.activeGateway is LocalMusicGateway) {
      return;
    }
    final key = state.activeConnectionKey;
    _sessions[key] = current;
    _lastSessionKey = key;
  }

  void forgetActiveSession() {
    final key = state.catalog.activeGateway is LocalMusicGateway
        ? _lastSessionKey
        : state.activeConnectionKey;
    if (key == null) return;
    _sessions.remove(key);
    if (_lastSessionKey == key) _lastSessionKey = _sessions.keys.lastOrNull;
  }

  SessionUser? _sessionFor(String key, MusicGateway gateway) {
    final account = gateway.user;
    if (account == null) {
      _sessions.remove(key);
      return null;
    }
    final remembered = _sessions[key];
    if (remembered?.handle == account.id.cacheKey) return remembered;
    return SessionUser(
      name: account.name,
      handle: account.id.cacheKey,
      method: AuthMethod.password,
      detail: gateway.provider.name,
      userId: int.tryParse(account.id.value) ?? 1,
      avatarUrl: account.avatarUrl,
      signature: account.signature,
      membership: account.membership,
    );
  }

  Map<String, SessionUser> get accounts {
    final result = <String, SessionUser>{};
    for (final gateway in state.musicConnections) {
      final key = GatewayRegistry.keyOf(gateway);
      final account = _sessionFor(key, gateway);
      if (account != null) result[key] = account;
    }
    return Map.unmodifiable(result);
  }

  void adoptLogin(MusicGateway gateway, SessionUser account) {
    final key = GatewayRegistry.keyOf(gateway);
    _sessions[key] = account;
    _lastSessionKey = key;
    if (identical(gateway, state.catalog.activeGateway) ||
        state.catalog.activeGateway is LocalMusicGateway) {
      state.catalog.selectConnection(state.activeConnectionKey);
      state._user = account;
      state.collections = UserCollections.empty;
      state._collectionsPending = null;
      state._collectionsGeneration++;
      unawaited(state.refreshHome());
    }
    unawaited(state._refreshMissingArtwork());
    unawaited(_save());
    state.notifyListeners();
  }

  Future<void> signOut(MusicGateway owner) async {
    final key = GatewayRegistry.keyOf(owner);
    final namespace = owner.cacheNamespace;
    cancelPending();
    _sessions.remove(key);
    _collectionsByAccount.remove(namespace);
    _likesByAccount.remove(namespace);
    _likesHydrated.remove(namespace);
    _likesHydrating.remove(namespace);
    if (_lastSessionKey == key) _lastSessionKey = null;
    await removeConnectionPlayback(owner);
    try {
      if (owner is MusicAccountGateway) {
        await owner.logout();
      } else {
        owner.clearSession();
      }
    } catch (_) {
      owner.clearSession();
    }
    if (state._presentationDisposed) return;
    if (identical(state.catalog.activeGateway, owner) ||
        state.catalog.activeGateway is LocalMusicGateway) {
      _activate(state.activeConnectionKey);
      unawaited(state.refreshHome());
    }
    await _save();
    state.notifyListeners();
  }

  Future<void> removeConnectionPlayback(MusicGateway owner) async {
    bool owned(Track track) {
      if (track.localPath != null) return false;
      final id = MusicId.tryParse(track.id);
      return id != null &&
          id.provider == owner.provider.id &&
          id.connection == owner.connectionId;
    }

    final retained = state._queue.where((track) => !owned(track)).toList();
    if (retained.length == state._queue.length) return;
    final playing = state.current;
    final position = state.precisePosition;
    if (playing == null || owned(playing)) {
      await _resetPlayback();
      state._queue = retained;
      state._queueIndex = 0;
    } else {
      final removedBefore = state._queue
          .take(state._queueIndex)
          .where(owned)
          .length;
      state._queue = retained;
      state._queueIndex -= removedBefore;
      state._queuedNextIndex = null;
      if (state._realActive && state._playing) {
        unawaited(state._startAudio(resumeAt: position));
      }
    }
    state._markQueueChanged();
    await state._saveQueue();
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
      rememberActiveSession();
      await state.listenTogether.leave();
      final target = state.musicConnections.firstWhere(
        (value) => GatewayRegistry.keyOf(value) == key,
      );
      if (target is LuaMusicGateway && target.user == null) {
        try {
          await target.checkSession();
        } catch (_) {
          /* Preserve the last known account while offline. */
        }
      }
      if (request != _request || state._presentationDisposed) return;
      _activate(key);
      await _save();
      unawaited(state._refreshMissingArtwork());
      unawaited(state.refreshHome());
    } finally {
      busy = false;
      if (!state._presentationDisposed) state.notifyListeners();
    }
  }

  Future<void> beforePluginChange(String pluginId) async {
    final registry = state.catalog.connections;
    final owned = registry.connections
        .where(
          (gateway) =>
              gateway is LuaMusicGateway && gateway.pluginId == pluginId,
        )
        .toList();
    final wasActive = owned.contains(registry.active);
    final keys = owned.map(GatewayRegistry.keyOf).toSet();
    final ownsPlayback = state._queue.any((track) {
      final id = MusicId.tryParse(track.id);
      return id != null &&
          keys.contains(
            '${Uri.encodeComponent(id.provider)}:${Uri.encodeComponent(id.connection)}',
          );
    });
    cancelPending();
    for (final gateway in owned) {
      final key = GatewayRegistry.keyOf(gateway);
      _sessions.remove(key);
      if (_lastSessionKey == key) _lastSessionKey = null;
    }
    if (ownsPlayback) {
      for (final gateway in owned) {
        await removeConnectionPlayback(gateway);
      }
    }
    for (final gateway in owned) {
      registry.remove(GatewayRegistry.keyOf(gateway), close: false);
    }
    if ((wasActive || state.catalog.activeGateway is LocalMusicGateway) &&
        registry.active != null) {
      _activate(GatewayRegistry.keyOf(registry.active!));
    }
  }

  Future<void> synchronizePlugins({bool refresh = true}) async {
    if (state._presentationDisposed) return;
    final registry = state.catalog.connections;
    final activeKey = state.activeConnectionKey;
    final fresh = <MusicGateway>[];
    for (final gateway in state.pluginManager.gateways) {
      final previous = registry.connections
          .where(
            (value) =>
                GatewayRegistry.keyOf(value) == GatewayRegistry.keyOf(gateway),
          )
          .firstOrNull;
      if (identical(previous, gateway)) continue;
      if (previous != null) {
        registry.remove(GatewayRegistry.keyOf(previous), close: false);
      }
      registry.add(gateway);
      fresh.add(gateway);
    }
    await Future.wait([
      for (final gateway in fresh)
        () async {
          try {
            await gateway.checkSession();
          } catch (_) {
            /* Offline credentials remain in plugin storage. */
          }
        }(),
    ]);
    if (state._presentationDisposed) return;
    var selected = activeKey;
    if (refresh &&
        fresh.isNotEmpty &&
        state.catalog.activeGateway is LocalMusicGateway) {
      selected = GatewayRegistry.keyOf(fresh.first);
    }
    if (registry.connections.any(
      (value) => GatewayRegistry.keyOf(value) == selected,
    )) {
      _activate(selected);
    }
    if (refresh) {
      await _save();
      unawaited(state._refreshMissingArtwork());
      unawaited(state.refreshHome());
    }
  }

  Future<void> saveSelection() => _save();

  Future<void> _resetPlayback() async {
    state._finishPlaySession();
    await state._flushPlayUploads();
    await state.listenTogether.leave();
    state._finishListening();
    state.pause();
    state._realActive = false;
    state._clearQueuedNext();
    state._queueId = null;
    state._generation++;
    state._lyricGeneration++;
    await state.audioEngine?.stop();
    state._queue = [];
    state.currentArtwork.update(null);
    state._lyricSnapshots.clear();
    state._lyricRequest = null;
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
    SessionUser? session;
    if (gateway is LocalMusicGateway) {
      // Local playback has no account, but selecting it must not turn the
      // application-wide account into a logout. Keep the last signed-in
      // account visible until the user explicitly signs out.
      final last = lastSessionGateway;
      session = last == null
          ? null
          : _sessionFor(GatewayRegistry.keyOf(last), last);
      if (session == null) {
        for (final candidate in state.musicConnections) {
          if (candidate is LocalMusicGateway) continue;
          final candidateKey = GatewayRegistry.keyOf(candidate);
          final restored = _sessionFor(candidateKey, candidate);
          if (restored != null && !restored.isGuest) {
            _sessions[candidateKey] = restored;
            _lastSessionKey = candidateKey;
            session = restored;
            break;
          }
        }
      }
    } else {
      session = _sessionFor(key, gateway);
    }
    if (session != null && !session.isGuest) {
      state._user = session;
      if (gateway is! LocalMusicGateway) {
        _sessions[key] = session;
        _lastSessionKey = key;
      }
    } else {
      state._user = SessionUser.guest;
    }
    state.collections =
        _collectionsByAccount[gateway.cacheNamespace] ?? UserCollections.empty;
    state._qrConfirmed = false;
    state._collectionsGeneration++;
    state.collectionsLoading = false;
    state.collectionsError = null;
    state._collectionsPending = null;
    state.playStats = const [];
    state._playStatsUid = null;
    state.playStatsLoading = false;
    state.discoveryCharts = const [];
    state.discoveryChartsError = null;
    state.notifyListeners();
  }

  Future<void> restore() async {
    try {
      for (final gateway
          in state.musicConnections.whereType<MusicAccountGateway>()) {
        if (gateway.user != null) continue;
        try {
          await gateway.checkSession();
        } catch (_) {}
      }
      final prefs = await SharedPreferences.getInstance();
      _lastSessionKey = prefs.getString(_lastAccountKey);
      final selected =
          prefs.getString(_selectedKey) ??
          (state.pluginManager.gateways.isEmpty
              ? null
              : GatewayRegistry.keyOf(state.pluginManager.gateways.first));
      if (selected != null &&
          state.musicConnections.any(
            (gateway) => GatewayRegistry.keyOf(gateway) == selected,
          )) {
        _activate(selected);
      } else {
        _activate(state.activeConnectionKey);
      }
    } catch (_) {}
  }

  Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_selectedKey, state.activeConnectionKey);
      if (_lastSessionKey != null) {
        await prefs.setString(_lastAccountKey, _lastSessionKey!);
      } else {
        await prefs.remove(_lastAccountKey);
      }
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
      throw ArgumentError('歌曲和歌单必须属于同一个音乐平台账号。'); // i18n:key
    }
    final gateway = state.catalog.connections.resolve(playlist);
    if (gateway.user == null) {
      throw StateError('Sign in to add songs to a playlist.');
    }
    final namespace = gateway.cacheNamespace;
    final favorites = _collectionsByAccount[namespace]?.liked;
    if (playlist.value == '__lazer_favorites__' ||
        favorites?.id == playlistKey) {
      await gateway.setFavorite(song, true);
      likesFor(gateway).add(song.cacheKey);
      await state.catalog.invalidatePlatformFavorites(
        gateway,
        playlistId: playlistKey,
      );
    } else {
      await gateway.addToPlaylist(playlist, [song]);
      await state.catalog.invalidatePlaylist(playlistKey);
      await state.catalog.invalidatePlatformCollections(gateway);
    }
    await _reloadCollections(gateway, namespace);
  }

  Future<void> _reloadCollections(
    MusicGateway gateway,
    String namespace,
  ) async {
    _collectionsByAccount.remove(namespace);
    if (gateway.cacheNamespace != namespace || state._presentationDisposed) {
      return;
    }
    if (identical(state.catalog.activeGateway, gateway)) {
      await state.refreshCollections();
    } else {
      final value = await state.catalog.platformCollections(gateway);
      if (gateway.cacheNamespace == namespace) {
        rememberCollections(gateway, value);
      }
    }
  }

  Future<void> toggleLike() async {
    final key = state.current?.id;
    final id = MusicId.tryParse(key ?? '');
    if (id == null) return;
    try {
      final gateway = state.catalog.connections.resolve(id);
      if (gateway.user == null) return;
      final namespace = gateway.cacheNamespace;
      final favorites = likesFor(gateway);
      final favorite = !favorites.contains(key);
      await gateway.setFavorite(id, favorite);
      if (gateway.cacheNamespace != namespace) return;
      favorite ? favorites.add(key!) : favorites.remove(key);
      state.likeError = null;
      await state.catalog.invalidatePlatformFavorites(
        gateway,
        playlistId: _collectionsByAccount[namespace]?.liked?.id,
      );
      await _reloadCollections(gateway, namespace);
    } catch (_) {
      state.likeError = '收藏失败，请稍后重试。'; // i18n:key
    }
    if (!state._presentationDisposed) state.notifyListeners();
  }

  Future<void> hydrate(Track track, MusicId id) async {
    if (state._presentationDisposed ||
        state._metadataPending.contains(track.id)) {
      return;
    }
    state._metadataPending.add(track.id);
    var retryForAccount = false;
    try {
      final owner = state.catalog.connections.resolve(id);
      final namespace = owner.cacheNamespace;
      final value = await owner.song(id);
      if (state._presentationDisposed ||
          owner.cacheNamespace != namespace ||
          !identical(state.catalog.connections.resolve(id), owner)) {
        retryForAccount =
            !state._presentationDisposed && owner.cacheNamespace != namespace;
        return;
      }
      final updated = state.catalog.trackFromMusicSong(value);
      Track merge(Track entry) => Track(
        id: entry.id,
        title: entry.title.isEmpty ? updated.title : entry.title,
        artist: entry.artist.isEmpty ? updated.artist : entry.artist,
        artists: updated.artists.isEmpty ? entry.artists : updated.artists,
        album: entry.album.isEmpty ? updated.album : entry.album,
        albumId: updated.albumId > 0 ? updated.albumId : entry.albumId,
        albumKey: updated.albumKey ?? entry.albumKey,
        duration: entry.duration > Duration.zero
            ? entry.duration
            : updated.duration,
        coverSeed: entry.coverSeed,
        accent: entry.accent,
        coverUrl: updated.coverUrl ?? entry.coverUrl,
        translatedTitle: updated.translatedTitle ?? entry.translatedTitle,
        localPath: entry.localPath,
      );
      final queueChanged = state._queue.any((entry) => entry.id == track.id);
      final recentChanged = state._recentTracks.any(
        (entry) => entry.id == track.id,
      );
      state._queue = [
        for (final entry in state._queue)
          if (entry.id == track.id) merge(entry) else entry,
      ];
      state._recentTracks = [
        for (final entry in state._recentTracks)
          if (entry.id == track.id) merge(entry) else entry,
      ];
      state._metadataLoaded.add(track.id);
      if (queueChanged) {
        state._markQueueChanged();
        unawaited(state.refreshArtworkSeed());
        unawaited(state._saveQueue());
      }
      if (recentChanged) unawaited(state._saveRecentTracks());
      if (queueChanged || recentChanged) state.notifyListeners();
    } catch (_) {
      // Metadata can retry when the account is reconnected.
    } finally {
      state._metadataPending.remove(track.id);
      if (retryForAccount) unawaited(state._refreshMissingArtwork());
    }
  }

  Future<void> report(Track track, Duration played, bool submission) async {
    try {
      final id = MusicId.tryParse(track.id);
      if (id == null) return;
      final gateway = state.catalog.connections.resolve(id);
      if (gateway.user == null || !gateway.supports(MusicCapability.scrobble)) {
        return;
      }
      state._enqueuePlay(
        _PlayReport(
          songId: id.cacheKey,
          account: gateway.cacheNamespace,
          kind: submission ? _PlayLogKind.play : _PlayLogKind.start,
          seconds: played.inSeconds,
        ),
      );
    } catch (_) {
      // A removed plugin must not interrupt local listening.
    }
  }
}
