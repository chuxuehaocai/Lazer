import '../utils/artwork.dart';

int _number(Object? value) =>
    value is num ? value.toInt() : int.tryParse('$value') ?? 0;

class CommentReply {
  const CommentReply({required this.author, required this.content});
  final String author, content;
  factory CommentReply.fromJson(Map<String, dynamic> json) => CommentReply(
    author: '${json['author'] ?? ''}',
    content: '${json['content'] ?? ''}',
  );
}

class SongComment {
  const SongComment({
    required this.id,
    required this.content,
    required this.author,
    this.userId = '',
    this.avatarUrl,
    this.time = 0,
    this.location,
    this.liked = false,
    this.likedCount = 0,
    this.replies = const [],
  });
  final String id, userId;
  final int time, likedCount;
  final String content, author;
  final String? avatarUrl, location;
  final bool liked;
  final List<CommentReply> replies;

  factory SongComment.fromJson(Map<String, dynamic> json) {
    return SongComment(
      id: '${json['id'] ?? ''}',
      content: '${json['content'] ?? ''}',
      author: '${json['author'] ?? ''}',
      userId: '${json['authorId'] ?? ''}',
      avatarUrl: normalizedArtworkUrl(json['avatarUrl'] as String?),
      time: _number(json['time']),
      location: json['location'] as String?,
      liked: json['liked'] == true,
      likedCount: _number(json['likedCount']).clamp(0, 1 << 53),
      replies: [
        for (final reply
            in json['replies'] is List ? json['replies'] as List : const [])
          if (reply is Map<String, dynamic> &&
              '${reply['content'] ?? ''}'.isNotEmpty)
            CommentReply.fromJson(reply),
      ],
    );
  }

  SongComment withLike(bool value, int count) => SongComment(
    id: id,
    content: content,
    author: author,
    userId: userId,
    avatarUrl: avatarUrl,
    time: time,
    location: location,
    liked: value,
    likedCount: count.clamp(0, 1 << 53),
    replies: replies,
  );
}

class SongCommentPage {
  const SongCommentPage({
    required this.total,
    required this.more,
    required this.hot,
    required this.latest,
    required this.receivedCount,
  });
  final int total, receivedCount;
  final bool more;
  final List<SongComment> hot, latest;

  factory SongCommentPage.fromJson(Map<String, dynamic> json) {
    List<SongComment> comments(Object? values) => values is List
        ? [
            for (final value in values)
              if (value is Map<String, dynamic> &&
                  '${value['id'] ?? ''}'.isNotEmpty)
                SongComment.fromJson(value),
          ]
        : const [];
    final latest = json['latest'];
    return SongCommentPage(
      total: _number(json['total']),
      more: json['hasMore'] == true,
      hot: comments(json['hot']),
      latest: comments(latest),
      receivedCount: latest is List ? latest.length : 0,
    );
  }
}
