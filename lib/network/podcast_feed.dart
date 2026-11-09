// i18n:data — interface strings declared here are translated at their render sites.
import 'dart:convert';

import 'package:xml/xml.dart';

import '../data/models.dart';

/// One episode of a subscribed podcast.
class PodcastEpisode {
  const PodcastEpisode({
    required this.id,
    required this.title,
    required this.audioUrl,
    this.description = '',
    this.publishedAt,
    this.duration,
    this.bytes,
  });

  final String id;
  final String title;
  final String audioUrl;
  final String description;
  final DateTime? publishedAt;
  final Duration? duration;
  final int? bytes;

  Duration get playableDuration => duration ?? Duration.zero;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'title': title,
    'audioUrl': audioUrl,
    'description': description,
    'publishedAt': publishedAt?.millisecondsSinceEpoch,
    'durationMs': duration?.inMilliseconds,
    'bytes': bytes,
  };

  factory PodcastEpisode.fromJson(Map<String, dynamic> json) => PodcastEpisode(
    id: json['id'] as String? ?? '',
    title: json['title'] as String? ?? '',
    audioUrl: json['audioUrl'] as String? ?? '',
    description: json['description'] as String? ?? '',
    publishedAt: json['publishedAt'] == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(
            (json['publishedAt'] as num).toInt(),
          ),
    duration: json['durationMs'] == null
        ? null
        : Duration(milliseconds: (json['durationMs'] as num).toInt()),
    bytes: (json['bytes'] as num?)?.toInt(),
  );
}

/// How far the listener got in one episode.
class PodcastProgress {
  const PodcastProgress({
    this.position = Duration.zero,
    this.played = false,
    this.updatedAt,
  });

  final Duration position;
  final bool played;
  final DateTime? updatedAt;

  bool get started => position > Duration.zero;

  PodcastProgress copyWith({
    Duration? position,
    bool? played,
    DateTime? updatedAt,
  }) => PodcastProgress(
    position: position ?? this.position,
    played: played ?? this.played,
    updatedAt: updatedAt ?? this.updatedAt,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'positionMs': position.inMilliseconds,
    'played': played,
    'updatedAt': updatedAt?.millisecondsSinceEpoch,
  };

  factory PodcastProgress.fromJson(Map<String, dynamic> json) =>
      PodcastProgress(
        position: Duration(
          milliseconds: (json['positionMs'] as num?)?.toInt() ?? 0,
        ),
        played: json['played'] == true,
        updatedAt: json['updatedAt'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(
                (json['updatedAt'] as num).toInt(),
              ),
      );
}

/// A parsed RSS/Atom podcast feed.
class PodcastFeed {
  const PodcastFeed({
    required this.url,
    required this.title,
    this.description = '',
    this.imageUrl = '',
    this.author = '',
    this.episodes = const <PodcastEpisode>[],
  });

  final String url;
  final String title;
  final String description;
  final String imageUrl;
  final String author;
  final List<PodcastEpisode> episodes;
}

/// One subscription: the feed's shape at the last refresh plus the listener's
/// progress through each episode.
class PodcastSubscription {
  const PodcastSubscription({
    required this.id,
    required this.feedUrl,
    required this.title,
    this.description = '',
    this.imageUrl = '',
    this.author = '',
    this.lastFetchedAt,
    this.error,
    this.episodes = const <PodcastEpisode>[],
    this.progress = const <String, PodcastProgress>{},
  });

  final String id;
  final String feedUrl;
  final String title;
  final String description;
  final String imageUrl;
  final String author;
  final DateTime? lastFetchedAt;
  final String? error;
  final List<PodcastEpisode> episodes;
  final Map<String, PodcastProgress> progress;

  String get displayTitle => title.trim().isEmpty ? feedUrl : title.trim();

  PodcastEpisode? episode(String episodeId) {
    for (final PodcastEpisode episode in episodes) {
      if (episode.id == episodeId) return episode;
    }
    return null;
  }

  PodcastProgress progressOf(String episodeId) =>
      progress[episodeId] ?? const PodcastProgress();

  /// The episode the listener was last inside, if any.
  PodcastEpisode? get continueEpisode {
    PodcastEpisode? chosen;
    DateTime? latest;
    for (final PodcastEpisode episode in episodes) {
      final PodcastProgress entry = progressOf(episode.id);
      if (entry.played || !entry.started) continue;
      final DateTime stamp = entry.updatedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      if (latest == null || stamp.isAfter(latest)) {
        latest = stamp;
        chosen = episode;
      }
    }
    return chosen;
  }

  int get unplayedCount =>
      episodes.where((PodcastEpisode episode) {
        return !progressOf(episode.id).played;
      }).length;

  PodcastSubscription copyWith({
    String? feedUrl,
    String? title,
    String? description,
    String? imageUrl,
    String? author,
    DateTime? lastFetchedAt,
    String? error,
    bool clearError = false,
    List<PodcastEpisode>? episodes,
    Map<String, PodcastProgress>? progress,
  }) => PodcastSubscription(
    id: id,
    feedUrl: feedUrl ?? this.feedUrl,
    title: title ?? this.title,
    description: description ?? this.description,
    imageUrl: imageUrl ?? this.imageUrl,
    author: author ?? this.author,
    lastFetchedAt: lastFetchedAt ?? this.lastFetchedAt,
    error: clearError ? null : (error ?? this.error),
    episodes: episodes ?? this.episodes,
    progress: progress ?? this.progress,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'feedUrl': feedUrl,
    'title': title,
    'description': description,
    'imageUrl': imageUrl,
    'author': author,
    'lastFetchedAt': lastFetchedAt?.millisecondsSinceEpoch,
    'error': error,
    'episodes': <Map<String, Object?>>[
      for (final PodcastEpisode episode in episodes) episode.toJson(),
    ],
    'progress': <String, Object?>{
      for (final MapEntry<String, PodcastProgress> entry in progress.entries)
        entry.key: entry.value.toJson(),
    },
  };

  factory PodcastSubscription.fromJson(Map<String, dynamic> json) =>
      PodcastSubscription(
        id: json['id'] as String? ?? '',
        feedUrl: json['feedUrl'] as String? ?? '',
        title: json['title'] as String? ?? '',
        description: json['description'] as String? ?? '',
        imageUrl: json['imageUrl'] as String? ?? '',
        author: json['author'] as String? ?? '',
        lastFetchedAt: json['lastFetchedAt'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(
                (json['lastFetchedAt'] as num).toInt(),
              ),
        error: json['error'] as String?,
        episodes: <PodcastEpisode>[
          for (final Object? item in json['episodes'] as List<Object?>? ?? const [])
            if (item is Map<String, dynamic>) PodcastEpisode.fromJson(item),
        ],
        progress: <String, PodcastProgress>{
          for (final MapEntry<String, dynamic> entry
              in (json['progress'] as Map<String, dynamic>? ?? const {}).entries)
            if (entry.value is Map<String, dynamic>)
              entry.key: PodcastProgress.fromJson(entry.value as Map<String, dynamic>),
        },
      );
}

/// Episode identity: the feed's own GUID when it has one, otherwise a hash of
/// the enclosure URL. Stable across refreshes, so progress survives them.
String podcastEpisodeId(String guid, String audioUrl) {
  final String seed = guid.trim().isNotEmpty ? guid.trim() : audioUrl.trim();
  var hash = 2166136261;
  for (final int unit in utf8.encode(seed)) {
    hash ^= unit;
    hash = (hash * 16777619) & 0xffffffff;
  }
  return 'pe-${hash.toRadixString(16).padLeft(8, '0')}';
}

String podcastTrackIdOf(String episodeId) => 'podcast:$episodeId';

String? podcastEpisodeIdOf(String trackId) {
  if (!trackId.startsWith('podcast:')) return null;
  final String value = trackId.substring(8);
  return value.isEmpty ? null : value;
}

String newPodcastSubscriptionId(String feedUrl) {
  var hash = 2166136261;
  for (final int unit in utf8.encode(feedUrl.trim())) {
    hash ^= unit;
    hash = (hash * 16777619) & 0xffffffff;
  }
  return 'pod-${hash.toRadixString(16)}';
}

/// A track for the queue. Podcasts keep their own artist label so they never
/// look like a catalogue song.
Track podcastTrack(
  PodcastSubscription subscription,
  PodcastEpisode episode,
) => Track(
  id: podcastTrackIdOf(episode.id),
  title: episode.title,
  artist: subscription.displayTitle,
  album: '播客',
  duration: episode.playableDuration,
  coverSeed: _seed(episode.id),
);

int _seed(String value) {
  var hash = 0;
  for (final int unit in utf8.encode(value)) {
    hash = (hash * 31 + unit) & 0xffffff;
  }
  return hash;
}

/// Parses an RSS 2.0 or Atom podcast feed.
///
/// Namespace prefixes are ignored (elements are matched by local name), which
/// covers iTunes (`itunes:duration`), Podcast 2.0 and the handful of publishers
/// that emit no namespace at all.
class PodcastFeedParser {
  const PodcastFeedParser();

  /// Caps how many episodes are kept: a daily show with a decade of archives
  /// would otherwise turn the subscription JSON into megabytes.
  static const int maxEpisodes = 300;

  PodcastFeed parse(String text, {required String feedUrl}) {
    final XmlDocument document;
    try {
      document = XmlDocument.parse(text);
    } catch (error) {
      throw PodcastFeedException(
        '播客订阅地址没有返回可解析的 RSS 或 Atom。',
        detail: '$error',
      );
    }
    final XmlElement? channel = _first(document, 'channel');
    final XmlElement? feed = _first(document, 'feed');
    if (channel != null) return _rssFeed(channel, feedUrl);
    if (feed != null) return _atomFeed(feed, feedUrl);
    throw const PodcastFeedException('播客订阅地址里没有找到任何节目。');
  }

  PodcastFeed _rssFeed(XmlElement channel, String feedUrl) {
    final String title = _text(channel, 'title');
    final String description = _clean(
      '${_text(channel, 'description')} ${_text(channel, 'summary')}',
    );
    final String image = _imageOf(channel);
    final String author = _text(channel, 'author');
    final List<PodcastEpisode> episodes = <PodcastEpisode>[];
    for (final XmlElement item in channel.children.whereType<XmlElement>()) {
      if (item.name.local.toLowerCase() != 'item') continue;
      final PodcastEpisode? episode = _rssItem(item);
      if (episode != null) episodes.add(episode);
    }
    return PodcastFeed(
      url: feedUrl,
      title: title.isEmpty ? feedUrl : title,
      description: _trim(description, 600),
      imageUrl: image,
      author: author,
      episodes: _ordered(episodes),
    );
  }

  PodcastEpisode? _rssItem(XmlElement item) {
    final String title = _text(item, 'title');
    String audio = '';
    int? bytes;
    for (final XmlElement child in item.children.whereType<XmlElement>()) {
      if (child.name.local.toLowerCase() == 'enclosure') {
        final String? url = child.getAttribute('url');
        if (url != null && url.trim().isNotEmpty) {
          audio = url.trim();
          bytes = int.tryParse(child.getAttribute('length') ?? '');
          break;
        }
      }
    }
    if (audio.isEmpty) {
      // Podcast 2.0 and some publishers use media:content or a plain link.
      for (final XmlElement child in item.descendants.whereType<XmlElement>()) {
        final String local = child.name.local.toLowerCase();
        if (local == 'content' || local == 'link') {
          final String? url = child.getAttribute('url') ?? child.getAttribute('href');
          final String? type = child.getAttribute('type');
          if (url == null || url.isEmpty) continue;
          if (type != null && !type.toLowerCase().startsWith('audio') && local == 'link') {
            continue;
          }
          audio = url;
          break;
        }
      }
    }
    if (audio.isEmpty) return null;
    final String guid = _text(item, 'guid');
    final String description = _clean(
      '${_text(item, 'description')} ${_text(item, 'summary')} '
      '${_text(item, 'encoded')}',
    );
    return PodcastEpisode(
      id: podcastEpisodeId(guid, audio),
      title: title.trim().isEmpty ? _tailOf(audio) : title.trim(),
      audioUrl: audio,
      description: _trim(description, 800),
      publishedAt: _date(_text(item, 'pubDate')) ?? _date(_text(item, 'published')),
      duration: parsePodcastDuration(_text(item, 'duration')),
      bytes: bytes,
    );
  }

  PodcastFeed _atomFeed(XmlElement feed, String feedUrl) {
    final String title = _text(feed, 'title');
    final String description = _clean(
      '${_text(feed, 'subtitle')} ${_text(feed, 'summary')}',
    );
    final String image = _imageOf(feed);
    final String author = _authorOf(feed);
    final List<PodcastEpisode> episodes = <PodcastEpisode>[];
    for (final XmlElement entry in feed.children.whereType<XmlElement>()) {
      if (entry.name.local.toLowerCase() != 'entry') continue;
      final PodcastEpisode? episode = _atomEntry(entry);
      if (episode != null) episodes.add(episode);
    }
    return PodcastFeed(
      url: feedUrl,
      title: title.isEmpty ? feedUrl : title,
      description: _trim(description, 600),
      imageUrl: image,
      author: author,
      episodes: _ordered(episodes),
    );
  }

  PodcastEpisode? _atomEntry(XmlElement entry) {
    final String title = _text(entry, 'title');
    String audio = '';
    String link = '';
    for (final XmlElement child in entry.children.whereType<XmlElement>()) {
      if (child.name.local.toLowerCase() != 'link') continue;
      final String? href = child.getAttribute('href');
      if (href == null || href.isEmpty) continue;
      final String rel = (child.getAttribute('rel') ?? 'alternate').toLowerCase();
      final String type = (child.getAttribute('type') ?? '').toLowerCase();
      if (rel == 'enclosure' || type.startsWith('audio/')) {
        audio = href;
      } else if (rel == 'alternate' && link.isEmpty) {
        link = href;
      }
    }
    if (audio.isEmpty) return null;
    final String guid = _text(entry, 'id');
    final String description = _clean(
      '${_text(entry, 'summary')} ${_text(entry, 'content')}',
    );
    return PodcastEpisode(
      id: podcastEpisodeId(guid, audio),
      title: title.trim().isEmpty ? _tailOf(audio) : title.trim(),
      audioUrl: audio,
      description: _trim(description, 800),
      publishedAt:
          _date(_text(entry, 'published')) ?? _date(_text(entry, 'updated')),
      duration: parsePodcastDuration(_text(entry, 'duration')),
    );
  }

  static List<PodcastEpisode> _ordered(List<PodcastEpisode> episodes) {
    final List<PodcastEpisode> sorted = <PodcastEpisode>[...episodes];
    sorted.sort((PodcastEpisode a, PodcastEpisode b) {
      final DateTime left =
          a.publishedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      final DateTime right =
          b.publishedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      return right.compareTo(left);
    });
    return sorted.length <= maxEpisodes
        ? sorted
        : sorted.sublist(0, maxEpisodes);
  }

  static XmlElement? _first(XmlDocument document, String localName) {
    for (final XmlElement element in document.descendants.whereType<XmlElement>()) {
      if (element.name.local.toLowerCase() == localName) return element;
    }
    return null;
  }

  /// First direct child with [localName]'s text (case-insensitive, so
  /// `pubDate` and `pubdate` both match).
  static String _text(XmlElement parent, String localName) {
    final String wanted = localName.toLowerCase();
    for (final XmlElement child in parent.children.whereType<XmlElement>()) {
      if (child.name.local.toLowerCase() == wanted) {
        return child.innerText.trim();
      }
    }
    return '';
  }

  /// Atom puts the name inside `<author><name>`.
  static String _authorOf(XmlElement parent) {
    final String direct = _text(parent, 'author');
    if (direct.isNotEmpty) return direct;
    for (final XmlElement element in parent.descendants.whereType<XmlElement>()) {
      if (element.name.local.toLowerCase() == 'author') {
        final String name = _text(element, 'name');
        if (name.isNotEmpty) return name;
      }
    }
    return '';
  }

  static String _imageOf(XmlElement parent) {
    for (final XmlElement element in parent.descendants.whereType<XmlElement>()) {
      final String local = element.name.local.toLowerCase();
      if (local == 'image') {
        final String href = element.getAttribute('href') ?? '';
        if (href.isNotEmpty) return href;
        final String url = _text(element, 'url');
        if (url.isNotEmpty) return url;
      }
      if (local == 'url' &&
          element.parentElement?.name.local.toLowerCase() == 'image') {
        return element.innerText.trim();
      }
    }
    return '';
  }

  static String _clean(String html) {
    final String withoutTags = html.replaceAll(
      RegExp(r'<[^>]*>'),
      ' ',
    );
    final String decoded = withoutTags
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&apos;', "'")
        .replaceAllMapped(
          RegExp(r'&#(\d+);'),
          (Match match) => String.fromCharCode(
            int.tryParse(match.group(1)!) ?? 32,
          ),
        );
    return decoded.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  static String _trim(String value, int length) =>
      value.length <= length ? value : '${value.substring(0, length)}…';

  static String _tailOf(String url) {
    final Uri? uri = Uri.tryParse(url);
    final String path = uri?.path ?? url;
    final int slash = path.lastIndexOf('/');
    final String tail = slash < 0 ? path : path.substring(slash + 1);
    return tail.isEmpty ? url : tail;
  }

  static DateTime? _date(String value) {
    final String text = value.trim();
    if (text.isEmpty) return null;
    final DateTime? iso = DateTime.tryParse(text);
    if (iso != null) return iso;
    // RFC 1123 (`Wed, 02 Oct 2002 13:00:00 GMT`), the format feeds use.
    final match = RegExp(
      r'^[A-Za-z]{3},\s+(\d{1,2})\s+([A-Za-z]{3})\s+(\d{2,4})\s+'
      r'(\d{2}):(\d{2})(?::(\d{2}))?\s+(?:GMT|UTC|[+-]0000)$',
    ).firstMatch(text);
    if (match == null) return null;
    const months = <String, int>{
      'jan': 1, 'feb': 2, 'mar': 3, 'apr': 4, 'may': 5, 'jun': 6,
      'jul': 7, 'aug': 8, 'sep': 9, 'oct': 10, 'nov': 11, 'dec': 12,
    };
    final int? month = months[match.group(2)!.toLowerCase()];
    if (month == null) return null;
    int year = int.parse(match.group(3)!);
    if (year < 100) year += year < 50 ? 2000 : 1900;
    return DateTime.utc(
      year,
      month,
      int.parse(match.group(1)!),
      int.parse(match.group(4)!),
      int.parse(match.group(5)!),
      int.tryParse(match.group(6) ?? '') ?? 0,
    );
  }
}

/// `1:02:03`, `62:03`, `3723` and `3723.5` are all durations in the wild.
Duration? parsePodcastDuration(String raw) {
  final String value = raw.trim();
  if (value.isEmpty) return null;
  final List<String> parts = value.split(':');
  try {
    if (parts.length == 1) {
      final double? seconds = double.tryParse(parts.first);
      if (seconds == null || seconds < 0) return null;
      return Duration(milliseconds: (seconds * 1000).round());
    }
    if (parts.length == 2) {
      final int minutes = int.parse(parts[0].trim());
      final Duration seconds = Duration(
        milliseconds: ((double.tryParse(parts[1].trim()) ?? 0) * 1000).round(),
      );
      return Duration(minutes: minutes) + seconds;
    }
    final int hours = int.parse(parts[0].trim());
    final int minutes = int.parse(parts[1].trim());
    final Duration seconds = Duration(
      milliseconds: ((double.tryParse(parts[2].trim()) ?? 0) * 1000).round(),
    );
    return Duration(hours: hours, minutes: minutes) + seconds;
  } catch (_) {
    return null;
  }
}

/// A parse failure with the sentence the interface shows.
class PodcastFeedException implements Exception {
  const PodcastFeedException(this.message, {this.detail});

  final String message;
  final String? detail;

  @override
  String toString() => 'PodcastFeedException: $message';
}
