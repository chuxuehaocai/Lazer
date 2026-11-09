// i18n:data — interface strings declared here are translated at their render sites.
import 'dart:convert';

import '../data/models.dart';
import 'network_source.dart';
import 'remote_source.dart';

/// One file the app has indexed from a network source.
///
/// The track carries no `localPath`: the player resolves `network:` ids through
/// [NetworkSourcesController] every time it opens them, so the loopback gate's
/// token and port can change between launches.
class NetworkTrackEntry {
  const NetworkTrackEntry({
    required this.id,
    required this.sourceId,
    required this.path,
    required this.title,
    required this.artist,
    required this.album,
    required this.duration,
    required this.addedAt,
    this.bytes,
    this.modifiedAt,
  });

  factory NetworkTrackEntry.fromRemote(
    String sourceId,
    RemoteEntry entry, {
    required String albumFallback,
    DateTime? now,
  }) {
    final String fileName = remoteName(entry.path);
    final String base = fileName.contains('.')
        ? fileName.substring(0, fileName.lastIndexOf('.'))
        : fileName;
    String title = base;
    String artist = '';
    final int separator = base.indexOf(' - ');
    if (separator > 0) {
      artist = base.substring(0, separator).trim();
      title = base.substring(separator + 3).trim();
    } else if (base.contains('-') &&
        !RegExp(r'^\d+-\d+$').hasMatch(base)) {
      final int dash = base.indexOf('-');
      if (dash > 0) {
        artist = base.substring(0, dash).trim();
        title = base.substring(dash + 1).trim();
      }
    }
    if (title.trim().isEmpty) title = fileName;
    final String folder = remoteName(remoteParent(entry.path));
    final String album = folder.isEmpty || folder == '/' || folder == '.'
        ? albumFallback
        : folder;
    return NetworkTrackEntry(
      id: networkTrackId(sourceId, entry.path),
      sourceId: sourceId,
      path: entry.path,
      title: title,
      artist: artist.isEmpty ? '未知歌手' : artist,
      album: album.isEmpty ? '网络音乐' : album,
      duration: Duration.zero,
      addedAt: now ?? DateTime.now(),
      bytes: entry.size,
      modifiedAt: entry.modifiedAt,
    );
  }

  final String id;
  final String sourceId;
  final String path;
  final String title;
  final String artist;
  final String album;
  final Duration duration;
  final DateTime addedAt;
  final int? bytes;
  final DateTime? modifiedAt;

  /// Stable generative cover seed, so a file keeps the same illustration.
  int get coverSeed {
    var hash = 2166136261;
    for (final int unit in utf8.encode(path)) {
      hash ^= unit;
      hash = (hash * 16777619) & 0xffffffff;
    }
    return hash & 0xffffff;
  }

  Track toTrack() => Track(
    id: id,
    title: title,
    artist: artist,
    album: album,
    duration: duration,
    coverSeed: coverSeed,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'sourceId': sourceId,
    'path': path,
    'title': title,
    'artist': artist,
    'album': album,
    'durationMs': duration.inMilliseconds,
    'addedAt': addedAt.millisecondsSinceEpoch,
    'bytes': bytes,
    'modifiedAt': modifiedAt?.millisecondsSinceEpoch,
  };

  factory NetworkTrackEntry.fromJson(Map<String, dynamic> json) =>
      NetworkTrackEntry(
        id: json['id'] as String? ?? '',
        sourceId: json['sourceId'] as String? ?? '',
        path: json['path'] as String? ?? '/',
        title: json['title'] as String? ?? '',
        artist: json['artist'] as String? ?? '',
        album: json['album'] as String? ?? '',
        duration: Duration(
          milliseconds: (json['durationMs'] as num?)?.toInt() ?? 0,
        ),
        addedAt: DateTime.fromMillisecondsSinceEpoch(
          (json['addedAt'] as num?)?.toInt() ?? 0,
        ),
        bytes: (json['bytes'] as num?)?.toInt(),
        modifiedAt: json['modifiedAt'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(
                (json['modifiedAt'] as num).toInt(),
              ),
      );
}

/// What one scan pass indexed.
class NetworkScanResult {
  const NetworkScanResult({
    this.added = 0,
    this.updated = 0,
    this.skipped = 0,
    this.failed = 0,
    this.cancelled = false,
  });

  static const NetworkScanResult empty = NetworkScanResult();

  final int added;
  final int updated;
  final int skipped;
  final int failed;
  final bool cancelled;

  int get total => added + updated + skipped + failed;

  NetworkScanResult copyWith({
    int? added,
    int? updated,
    int? skipped,
    int? failed,
    bool? cancelled,
  }) => NetworkScanResult(
    added: added ?? this.added,
    updated: updated ?? this.updated,
    skipped: skipped ?? this.skipped,
    failed: failed ?? this.failed,
    cancelled: cancelled ?? this.cancelled,
  );

  NetworkScanResult merge(NetworkScanResult other) => NetworkScanResult(
    added: added + other.added,
    updated: updated + other.updated,
    skipped: skipped + other.skipped,
    failed: failed + other.failed,
    cancelled: cancelled || other.cancelled,
  );
}

/// Cooperative cancellation for a long folder walk.
class NetworkScanCancel {
  bool _cancelled = false;
  bool get cancelled => _cancelled;
  void cancel() => _cancelled = true;
}
