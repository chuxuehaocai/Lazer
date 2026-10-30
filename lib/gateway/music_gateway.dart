import 'music_models.dart';

export 'music_models.dart';

/// Protocol-free boundary for catalogue, playback and account features.
/// Authentication belongs to each adapter; no cookie concept leaks here.
abstract class MusicGateway {
  MusicProvider get provider;
  String get connectionId;
  MusicUser? get user;
  Set<MusicCapability> get capabilities;

  bool supports(MusicCapability capability) =>
      capabilities.contains(capability);

  /// Includes account identity. Never use a bare remote ID as a cache key.
  String get cacheNamespace => [
    provider.id,
    connectionId,
    user?.id.value ?? 'guest',
  ].map(Uri.encodeComponent).join(':');

  MusicId id(MusicEntityKind kind, String value) => MusicId(
    provider: provider.id,
    connection: connectionId,
    kind: kind,
    value: value,
  );

  String remoteId(MusicId id, MusicEntityKind kind) {
    if (id.provider != provider.id ||
        id.connection != connectionId ||
        id.kind != kind ||
        id.value.isEmpty) {
      throw ArgumentError(
        'Music reference does not belong to this connection.',
      );
    }
    return id.value;
  }

  void validatePage(int limit, int offset) {
    if (limit < 1 || limit > 500 || offset < 0) {
      throw ArgumentError('Page size must be 1..500 and offset non-negative.');
    }
  }

  Future<MusicUser?> checkSession();
  void clearSession();
  void close();

  Future<MusicSearchResult> search(
    String query, {
    int limit = 30,
    int offset = 0,
  });
  Future<MusicSong> song(MusicId id);
  Future<MusicAlbum> album(MusicId id);
  Future<MusicPage<MusicAlbum>> albums({
    MusicAlbumSort sort = MusicAlbumSort.newest,
    int limit = 30,
    int offset = 0,
  }) => Future.error(MusicUnsupportedException(provider.id, 'browseAlbums'));
  Future<MusicPage<MusicSong>> albumSongs(
    MusicId id, {
    int limit = 100,
    int offset = 0,
  });
  Future<MusicArtist> artist(MusicId id);
  Future<MusicPage<MusicAlbum>> artistAlbums(
    MusicId id, {
    int limit = 30,
    int offset = 0,
  });
  Future<MusicPage<MusicPlaylist>> playlists({int limit = 30, int offset = 0});
  Future<MusicPlaylist> playlist(MusicId id);
  Future<MusicPage<MusicSong>> playlistSongs(
    MusicId id, {
    int limit = 100,
    int offset = 0,
  });
  Future<MusicPlaylist> createPlaylist(String name, {bool isPublic = false});
  Future<void> addToPlaylist(MusicId playlist, List<MusicId> songs);

  /// Positional removal preserves duplicate songs in a playlist.
  /// Throws [MusicUnsupportedException] before mutating if an upstream only
  /// supports deletion by song ID and cannot preserve duplicate occurrences.
  Future<void> removeFromPlaylist(MusicId playlist, List<int> indexes);
  Future<MusicPage<MusicSong>> favorites({int limit = 100, int offset = 0});
  Future<void> setFavorite(MusicId song, bool favorite);
  Future<MusicStream> stream(
    MusicId song, {
    MusicStreamQuality quality = MusicStreamQuality.original,
  });
  Future<List<MusicLyrics>> lyrics(MusicId song);
  Future<void> scrobble(
    MusicId song, {
    required Duration played,
    bool submission = true,
    DateTime? time,
  });

  Future<MusicPage<MusicSong>> recommendations({int limit = 30}) =>
      Future.error(MusicUnsupportedException(provider.id, 'recommendations'));
}

class MusicUnsupportedException implements Exception {
  const MusicUnsupportedException(this.provider, this.feature);
  final String provider;
  final String feature;
  @override
  String toString() => '$provider does not support $feature.';
}

/// Contains only an endpoint name and safe status/code, never a signed URL,
/// server body, username, password or token.
class MusicGatewayException implements Exception {
  const MusicGatewayException(
    this.provider,
    this.endpoint, {
    this.code,
    this.httpStatus,
    this.reason = 'Request failed',
  });
  final String provider;
  final String endpoint;
  final int? code;
  final int? httpStatus;
  final String reason;
  bool get authenticationFailure =>
      code == 40 || code == 41 || code == 44 || httpStatus == 401;
  @override
  String toString() =>
      '$provider/$endpoint: $reason (code: $code, HTTP: $httpStatus).';
}
