/// Models presented by the player, mapped from the gateway response.
library;

import '../gateway/music_models.dart';

/// One row of the listener's play record, as returned by the gateway.
///
/// [playCount] is the number of plays the official app shows in 听歌排行;
/// [duration] lets a list turn it into the accumulated listening time.
class TrackPlayStat {
  const TrackPlayStat({
    required this.songId,
    required this.playCount,
    required this.duration,
  });

  final String songId;
  final int playCount;
  final Duration duration;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'songId': songId,
    'playCount': playCount,
    'duration': duration.inMilliseconds,
  };

  factory TrackPlayStat.fromJson(Map<String, dynamic> json) => TrackPlayStat(
    songId: json['songId'] as String? ?? '',
    playCount: (json['playCount'] as num?)?.toInt() ?? 0,
    duration: Duration(milliseconds: (json['duration'] as num?)?.toInt() ?? 0),
  );
}

class ArtistRef {
  const ArtistRef({
    required this.id,
    required this.name,
    this.coverUrl,
    this.platformKey,
  });
  final int id;
  final String name;
  final String? coverUrl;
  final String? platformKey;
  String get key => platformKey ?? '$id';
  bool get hasIdentity =>
      id > 0 || MusicId.tryParse(key)?.kind == MusicEntityKind.artist;
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'coverUrl': platformKey == null ? coverUrl : null,
    if (platformKey != null) 'platformKey': platformKey,
  };
  factory ArtistRef.fromJson(Map<String, dynamic> json) => ArtistRef(
    id: (json['id'] as num?)?.toInt() ?? 0,
    name: json['name'] as String? ?? '',
    coverUrl: json['coverUrl'] as String?,
    platformKey: json['platformKey'] as String?,
  );
  static List<ArtistRef> list(Object? values) => values is List
      ? [
          for (final value in values)
            if (value is Map<String, dynamic>) ArtistRef.fromJson(value),
        ]
      : const [];
}

class Track {
  const Track({
    required this.id,
    required this.title,
    required this.artist,
    required this.album,
    required this.duration,
    required this.coverSeed,
    this.accent = 0,
    this.coverUrl,
    this.albumId = 0,
    this.albumKey,
    this.translatedTitle,
    this.artists = const [],
    this.localPath,
  });

  final String id;
  final String title;
  final String artist;
  final String album;
  final Duration duration;

  /// Seed for the generative field-plate cover illustration.
  final int coverSeed;

  /// Index into the cover palette family (0 = ivory, 1 = manilla, 2 = oat).
  final int accent;
  final String? coverUrl;
  final int albumId;
  final String? albumKey;
  String get albumIdentity => albumKey ?? '$albumId';
  bool get hasAlbum =>
      albumId > 0 ||
      MusicId.tryParse(albumIdentity)?.kind == MusicEntityKind.album;
  String? get persistedCoverUrl =>
      MusicId.tryParse(id) == null ? coverUrl : null;
  bool get isServiceTrack =>
      int.tryParse(id) != null ||
      MusicId.tryParse(id)?.kind == MusicEntityKind.song;
  final String? translatedTitle;
  final List<ArtistRef> artists;

  /// Absolute path of a downloaded or scanned file. When set the player reads
  /// this file directly instead of resolving a stream from the service.
  final String? localPath;

  Track copyWith({String? localPath, int? coverSeed, String? coverUrl}) =>
      Track(
        id: id,
        title: title,
        artist: artist,
        album: album,
        duration: duration,
        coverSeed: coverSeed ?? this.coverSeed,
        accent: accent,
        coverUrl: coverUrl ?? this.coverUrl,
        albumId: albumId,
        albumKey: albumKey,
        translatedTitle: translatedTitle,
        artists: artists,
        localPath: localPath ?? this.localPath,
      );

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'artist': artist,
    'album': album,
    'durationMs': duration.inMilliseconds,
    'coverSeed': coverSeed,
    'accent': accent,
    'coverUrl': persistedCoverUrl,
    'albumId': albumId,
    if (albumKey != null) 'albumKey': albumKey,
    'translatedTitle': translatedTitle,
    'artists': artists.map((artist) => artist.toJson()).toList(),
    'localPath': localPath,
  };

  factory Track.fromJson(Map<String, dynamic> json) => Track(
    id: json['id'] as String,
    title: json['title'] as String,
    artist: json['artist'] as String,
    album: json['album'] as String,
    duration: Duration(milliseconds: json['durationMs'] as int),
    coverSeed: json['coverSeed'] as int,
    accent: json['accent'] as int? ?? 0,
    coverUrl: json['coverUrl'] as String?,
    albumId: json['albumId'] as int? ?? 0,
    albumKey: json['albumKey'] as String?,
    translatedTitle: json['translatedTitle'] as String?,
    artists: ArtistRef.list(json['artists']),
    localPath: json['localPath'] as String?,
  );
}

class Playlist {
  const Playlist({
    required this.id,
    required this.name,
    required this.trackIds,
    required this.coverSeed,
    this.description = '',
    this.coverUrl,
    this.trackCount = 0,
  });

  final String id;
  final String name;
  final List<String> trackIds;
  final int coverSeed;
  final String description;
  final String? coverUrl;
  final int trackCount;

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'trackIds': trackIds,
    'coverSeed': coverSeed,
    'description': description,
    'coverUrl': MusicId.tryParse(id) == null ? coverUrl : null,
    'trackCount': trackCount,
  };

  factory Playlist.fromJson(Map<String, dynamic> json) => Playlist(
    id: json['id'] as String,
    name: json['name'] as String,
    trackIds: (json['trackIds'] as List).cast<String>(),
    coverSeed: json['coverSeed'] as int,
    description: json['description'] as String? ?? '',
    coverUrl: json['coverUrl'] as String?,
    trackCount: json['trackCount'] as int? ?? 0,
  );
}

/// One published chart issue from an external editorial source.
///
/// Chart entries deliberately remain independent from [Track]: an external
/// ranking can still be presented when NetEase does not carry a safe match.
class MusicChart {
  const MusicChart({
    required this.id,
    required this.title,
    required this.source,
    required this.issueLabel,
    required this.entries,
    this.accent = 0xFF356EFF,
    this.providerKey,
    this.logoUrl,
    this.issues = const <ChartIssue>[],
    this.selectedIssueId,
  });

  final String id;
  final String title;
  final String source;
  final String issueLabel;
  final List<ChartEntry> entries;
  final int accent;
  final String? providerKey;
  final String? logoUrl;
  final List<ChartIssue> issues;
  final int? selectedIssueId;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'title': title,
    'source': source,
    'issueLabel': issueLabel,
    'entries': entries.map((entry) => entry.toJson()).toList(),
    'accent': accent,
    'providerKey': providerKey,
    'logoUrl': logoUrl,
    'issues': issues.map((issue) => issue.toJson()).toList(),
    'selectedIssueId': selectedIssueId,
  };

  factory MusicChart.fromJson(Map<String, dynamic> json) => MusicChart(
    id: json['id'] as String? ?? '',
    title: json['title'] as String? ?? '',
    source: json['source'] as String? ?? '',
    issueLabel: json['issueLabel'] as String? ?? '',
    entries: (json['entries'] as List? ?? const <Object>[])
        .whereType<Map<String, dynamic>>()
        .map(ChartEntry.fromJson)
        .toList(),
    accent: (json['accent'] as num?)?.toInt() ?? 0xFF356EFF,
    providerKey: json['providerKey'] as String?,
    logoUrl: json['logoUrl'] as String?,
    issues: (json['issues'] as List? ?? const <Object>[])
        .whereType<Map<String, dynamic>>()
        .map(ChartIssue.fromJson)
        .toList(),
    selectedIssueId: (json['selectedIssueId'] as num?)?.toInt(),
  );
}

class ChartIssue {
  const ChartIssue({required this.id, required this.label});
  final int id;
  final String label;

  Map<String, dynamic> toJson() => <String, dynamic>{'id': id, 'label': label};
  factory ChartIssue.fromJson(Map<String, dynamic> json) => ChartIssue(
    id: (json['id'] as num?)?.toInt() ?? 0,
    label: json['label'] as String? ?? '',
  );
}

class ChartEntry {
  const ChartEntry({
    required this.rank,
    required this.title,
    required this.artist,
    this.translatedTitle,
    this.coverUrl,
    this.sourceUrl,
    this.previousRank,
    this.peakRank,
    this.weeksOnChart,
    this.score,
    this.trend = const <double>[],
    this.changeLabel,
    this.track,
  });

  final int rank;
  final String title;
  final String artist;
  final String? translatedTitle;
  final String? coverUrl;
  final String? sourceUrl;
  final int? previousRank;
  final int? peakRank;
  final int? weeksOnChart;
  final int? score;
  final List<double> trend;
  final String? changeLabel;
  final Track? track;

  ChartEntry copyWith({Track? track, List<double>? trend}) => ChartEntry(
    rank: rank,
    title: title,
    artist: artist,
    translatedTitle: translatedTitle,
    coverUrl: coverUrl,
    sourceUrl: sourceUrl,
    previousRank: previousRank,
    peakRank: peakRank,
    weeksOnChart: weeksOnChart,
    score: score,
    trend: trend ?? this.trend,
    changeLabel: changeLabel,
    track: track ?? this.track,
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'rank': rank,
    'title': title,
    'artist': artist,
    'translatedTitle': translatedTitle,
    'coverUrl': coverUrl,
    'sourceUrl': sourceUrl,
    'previousRank': previousRank,
    'peakRank': peakRank,
    'weeksOnChart': weeksOnChart,
    'score': score,
    'trend': trend,
    'changeLabel': changeLabel,
    'track': track?.toJson(),
  };

  factory ChartEntry.fromJson(Map<String, dynamic> json) => ChartEntry(
    rank: (json['rank'] as num?)?.toInt() ?? 0,
    title: json['title'] as String? ?? '',
    artist: json['artist'] as String? ?? '',
    translatedTitle: json['translatedTitle'] as String?,
    coverUrl: json['coverUrl'] as String?,
    sourceUrl: json['sourceUrl'] as String?,
    previousRank: (json['previousRank'] as num?)?.toInt(),
    peakRank: (json['peakRank'] as num?)?.toInt(),
    weeksOnChart: (json['weeksOnChart'] as num?)?.toInt(),
    score: (json['score'] as num?)?.toInt(),
    trend: (json['trend'] as List? ?? const <Object>[])
        .whereType<num>()
        .map((value) => value.toDouble())
        .toList(),
    changeLabel: json['changeLabel'] as String?,
    track: json['track'] is Map<String, dynamic>
        ? Track.fromJson(json['track'] as Map<String, dynamic>)
        : null,
  );
}

class Album {
  const Album({
    required this.id,
    required this.title,
    required this.artist,
    required this.year,
    required this.coverSeed,
    required this.note,
    this.accent = 0,
    this.trackCount,
    this.coverUrl,
    this.artists = const [],
    this.releaseType = '',
    this.subType = '',
  });

  final String id;
  final String title;
  final String artist;
  final String year;
  final int coverSeed;
  final String note;
  final int accent;

  final int? trackCount;
  final String? coverUrl;
  final List<ArtistRef> artists;

  /// NetEase exposes values such as `专辑` and `EP/Single` here.
  final String releaseType;
  final String subType;

  AlbumReleaseGroup get releaseGroup {
    final String value = '$releaseType $subType'.toLowerCase();
    if (value.contains('single') ||
        value.contains('ep') ||
        value.contains('单曲')) {
      return AlbumReleaseGroup.singleEp;
    }
    if (value.contains('album') || value.contains('专辑')) {
      return AlbumReleaseGroup.album;
    }
    final int? count = trackCount;
    if (count != null && count > 0) {
      return count <= 6 ? AlbumReleaseGroup.singleEp : AlbumReleaseGroup.album;
    }
    return AlbumReleaseGroup.unknown;
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'artist': artist,
    'year': year,
    'coverSeed': coverSeed,
    'note': note,
    'accent': accent,
    'trackCount': trackCount,
    'coverUrl': MusicId.tryParse(id) == null ? coverUrl : null,
    'artists': artists.map((artist) => artist.toJson()).toList(),
    'releaseType': releaseType,
    'subType': subType,
  };

  factory Album.fromJson(Map<String, dynamic> json) => Album(
    id: json['id'] as String,
    title: json['title'] as String,
    artist: json['artist'] as String,
    year: json['year'] as String,
    coverSeed: json['coverSeed'] as int,
    note: json['note'] as String,
    accent: json['accent'] as int? ?? 0,
    trackCount: json['trackCount'] as int?,
    coverUrl: json['coverUrl'] as String?,
    artists: ArtistRef.list(json['artists']),
    releaseType: json['releaseType'] as String? ?? '',
    subType: json['subType'] as String? ?? '',
  );
}

enum AlbumReleaseGroup { album, singleEp, unknown }
