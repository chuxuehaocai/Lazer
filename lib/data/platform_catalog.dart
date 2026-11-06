part of 'catalog.dart';

/// Maps provider-neutral values into the shared UI without coercing remote IDs.
class _PlatformCatalog {
  _PlatformCatalog(this.catalog);
  final Catalog catalog;
  static const favoritesKey = '__lazer_favorites__';

  MusicId reference(String key, MusicEntityKind kind) {
    final id = MusicId.tryParse(key);
    if (id == null || id.kind != kind) {
      throw ArgumentError('Invalid music reference.');
    }
    return id;
  }

  MusicGateway owner(MusicId id) => catalog.connections.resolve(id);

  ArtistRef artist(MusicArtist value) => ArtistRef(
    id: 0,
    name: value.name,
    coverUrl: value.coverUrl,
    platformKey: value.id.value.isEmpty ? null : value.id.cacheKey,
  );

  Track track(MusicSong value) => Track(
    id: value.id.cacheKey,
    title: value.title,
    artist: value.artists.map((artist) => artist.name).join(' / '),
    artists: value.artists.map(artist).toList(),
    album: value.albumName,
    albumKey: value.albumId?.cacheKey,
    duration: value.duration,
    coverSeed: value.id.cacheKey.hashCode & 0x7fffffff,
    coverUrl: value.coverUrl,
  );

  Album album(MusicAlbum value) => Album(
    id: value.id.cacheKey,
    title: value.title,
    artist: value.artists.map((artist) => artist.name).join(' / '),
    artists: value.artists.map(artist).toList(),
    year: value.year?.toString() ?? '',
    coverSeed: value.id.cacheKey.hashCode & 0x7fffffff,
    note: '',
    coverUrl: value.coverUrl,
    trackCount: value.songCount,
  );

  Playlist playlist(MusicPlaylist value) => Playlist(
    id: value.id.cacheKey,
    name: value.name,
    description: value.description,
    trackIds: const [],
    coverSeed: value.id.cacheKey.hashCode & 0x7fffffff,
    coverUrl: value.coverUrl,
    trackCount: value.songCount,
  );

  Future<List<T>> all<T>(Future<MusicPage<T>> Function(int offset) load) async {
    final items = <T>[];
    var offset = 0;
    while (true) {
      final page = await load(offset);
      items.addAll(page.items);
      if (!page.hasMore || page.items.isEmpty || page.nextOffset <= offset) {
        return items;
      }
      offset = page.nextOffset;
    }
  }

  Future<HomeFeed> home(MusicGateway gateway) async {
    if (gateway.user == null) {
      throw MusicGatewayException(gateway.provider.id, 'session', code: 40);
    }
    final values = await Future.wait<Object>([
      gateway.supports(MusicCapability.browseAlbums)
          ? gateway.albums(limit: 18)
          : Future.value(
              MusicPage<MusicAlbum>(const [], offset: 0, hasMore: false),
            ),
      gateway.supports(MusicCapability.recommendations)
          ? gateway.recommendations(limit: 16)
          : Future.value(
              MusicPage<MusicSong>(const [], offset: 0, hasMore: false),
            ),
      gateway.supports(MusicCapability.playlists)
          ? gateway.playlists(limit: 18)
          : Future.value(
              MusicPage<MusicPlaylist>(const [], offset: 0, hasMore: false),
            ),
    ]);
    final albums = (values[0] as MusicPage<MusicAlbum>).items
        .map(album)
        .toList();
    final songs = (values[1] as MusicPage<MusicSong>).items.map(track).toList();
    final lists = (values[2] as MusicPage<MusicPlaylist>).items
        .map(playlist)
        .toList();
    final featuredTracks = albums.isEmpty
        ? <Track>[]
        : (await gateway.albumSongs(
            (values[0] as MusicPage<MusicAlbum>).items.first.id,
            limit: 8,
          )).items.map(track).toList();
    return HomeFeed(
      featured: albums.firstOrNull,
      featuredTracks: featuredTracks,
      quick: songs,
      playlists: lists,
      albums: albums,
    );
  }

  Future<SearchResults> search(MusicGateway gateway, String query) async {
    final result = await gateway.search(query);
    return SearchResults(
      tracks: result.songs.items.map(track).toList(),
      albums: result.albums.items.map(album).toList(),
      artists: result.artists.items.map(artist).toList(),
      playlists: result.playlists.items.map(playlist).toList(),
    );
  }

  Future<UserCollections> collections(MusicGateway gateway) async {
    final account = gateway.user;
    if (account == null) return UserCollections.empty;
    final lists = !gateway.supports(MusicCapability.playlists)
        ? <MusicPlaylist>[]
        : await all((offset) => gateway.playlists(limit: 100, offset: offset));
    final favorites = !gateway.supports(MusicCapability.favorites)
        ? <MusicSong>[]
        : await all((offset) => gateway.favorites(limit: 100, offset: offset));
    if (gateway.user?.id != account.id) {
      throw StateError('Music account changed.');
    }
    final unique = {for (final list in lists) list.id: list};
    final personal = unique.values
        .where(
          (list) =>
              list.isFavorites &&
              (list.writable || list.owner == account.id.value),
        )
        .firstOrNull;
    final favoriteIds = favorites.map((song) => song.id.cacheKey).toList();
    final liked = personal == null ? null : playlist(personal);
    return UserCollections(
      liked: liked == null && !gateway.supports(MusicCapability.favorites)
          ? null
          : Playlist(
              id:
                  liked?.id ??
                  gateway.id(MusicEntityKind.playlist, favoritesKey).cacheKey,
              name: liked?.name ?? '${account.name}喜欢的音乐',
              description: liked?.description ?? '',
              trackIds: favoriteIds,
              coverSeed: liked?.coverSeed ?? 0,
              coverUrl: liked?.coverUrl ?? favorites.firstOrNull?.coverUrl,
              trackCount: gateway.supports(MusicCapability.favorites)
                  ? favorites.length
                  : liked!.trackCount,
            ),
      created: unique.values
          .where((list) => list.writable && list.id != personal?.id)
          .map(playlist)
          .toList(),
      subscribed: unique.values
          .where((list) => !list.writable && list.id != personal?.id)
          .map(playlist)
          .toList(),
    );
  }

  Future<List<Track>> playlistTracks(String key) async {
    final id = reference(key, MusicEntityKind.playlist);
    final gateway = owner(id);
    final account = gateway.user?.id;
    final songs = await all(
      (offset) => id.value == favoritesKey
          ? gateway.favorites(limit: 100, offset: offset)
          : gateway.playlistSongs(id, limit: 100, offset: offset),
    );
    if (gateway.user?.id != account) throw StateError('Music account changed.');
    return songs.map(track).toList();
  }

  Future<AlbumDetails> albumDetails(String key) async {
    final id = reference(key, MusicEntityKind.album);
    final gateway = owner(id);
    final data = await gateway.album(id);
    final songs = await all(
      (offset) => gateway.albumSongs(id, limit: 100, offset: offset),
    );
    return AlbumDetails(
      album: album(data),
      tracks: songs.map(track).toList(),
      description: data.description,
    );
  }

  /// Starred albums as the album library shows them: one page at a time, with
  /// the provider's own "there is more" answer preserved.
  Future<AlbumPage> savedAlbums(MusicGateway gateway, int offset) async {
    final page = await gateway.savedAlbums(limit: 100, offset: offset);
    return AlbumPage(
      albums: page.items.map(album).toList(),
      more: page.hasMore,
      receivedCount: page.items.length,
    );
  }

  Future<ArtistAlbumPage> artistAlbumPage(ArtistRef seed, int offset) async {
    final id = reference(seed.key, MusicEntityKind.artist);
    final page = await owner(id).artistAlbums(id, limit: 100, offset: offset);
    return ArtistAlbumPage(
      albums: page.items.map(album).toList(),
      more: page.hasMore,
      receivedCount: page.items.length,
    );
  }

  Future<List<Track>> artistSongs(ArtistRef seed) async {
    final id = reference(seed.key, MusicEntityKind.artist);
    final gateway = owner(id);
    final albums = await all(
      (offset) => gateway.artistAlbums(id, limit: 100, offset: offset),
    );
    final songs = <String, Track>{};
    for (final album in albums) {
      for (final song in await all(
        (offset) => gateway.albumSongs(album.id, limit: 100, offset: offset),
      )) {
        songs.putIfAbsent(song.id.cacheKey, () => track(song));
      }
    }
    return songs.values.toList();
  }

  Future<ArtistDetails> artistDetails(ArtistRef seed) async {
    final id = reference(seed.key, MusicEntityKind.artist);
    final value = await owner(id).artist(id);
    final tracks = await artistSongs(seed);
    return ArtistDetails(
      artist: artist(value),
      tracks: tracks,
      description: value.description,
      musicCount: tracks.length,
      albumCount: value.albumCount ?? 0,
    );
  }

  Future<AudioSource?> audioSource(
    MusicId id,
    AudioQuality quality,
    bool useCache,
  ) async {
    if (useCache) {
      final cached = await catalog.audioCache.find(
        id.cacheKey,
        quality: quality,
      );
      if (cached != null) {
        return AudioSource(
          url: cached.uri.toString(),
          quality: quality,
          format: Catalog._audioFormat(null, cached.path),
        );
      }
    }
    final source = await owner(id).stream(
      id,
      quality: switch (quality) {
        AudioQuality.lossless => MusicStreamQuality.original,
        AudioQuality.exhigh => MusicStreamQuality.high,
        AudioQuality.higher => MusicStreamQuality.medium,
        AudioQuality.standard => MusicStreamQuality.low,
      },
    );
    if (useCache) {
      unawaited(
        catalog.audioCache.store(
          id.cacheKey,
          source.uri.toString(),
          quality: quality,
          format: source.suffix,
        ),
      );
    }
    return AudioSource(
      url: source.uri.toString(),
      quality: quality,
      format: source.suffix,
      bytes: source.size,
    );
  }

  Future<GatewayLyrics> lyrics(String key) async {
    final id = reference(key, MusicEntityKind.song);
    final values = await owner(id).lyrics(id);
    if (values.isEmpty) return const GatewayLyrics(pureMusic: true);
    final value =
        values.where((lyrics) => lyrics.synced).firstOrNull ?? values.first;
    final buffer = StringBuffer();
    for (final line in value.lines) {
      if (line.start case final start?) {
        final ms = math.max(0, (start + value.offset).inMilliseconds);
        buffer.write(
          '[${(ms ~/ 60000).toString().padLeft(2, '0')}:${(ms ~/ 1000 % 60).toString().padLeft(2, '0')}.${(ms % 1000).toString().padLeft(3, '0')}]',
        );
      }
      buffer.writeln(line.text);
    }
    return GatewayLyrics(
      lrc: value.lrc ?? buffer.toString(),
      yrc: value.wordByWord,
      tlyric: value.translation,
    );
  }
}
