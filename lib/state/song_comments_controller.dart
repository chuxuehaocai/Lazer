// i18n:data — interface strings declared here are translated at their render sites.
import 'package:flutter/foundation.dart';

import '../data/song_comments.dart';
import '../gateway/gateway.dart';
import '../gateway/transport.dart';
import '../plugins/plugin_manifest.dart';
import 'build_safe_notifier.dart';

/// Comment requests and optimistic likes have their own notification lane.
/// Paging and reactions never rebuild playback or depend on its clock.
class SongCommentsController extends ChangeNotifier with BuildSafeNotifier {
  SongCommentsController(NeteaseGateway gateway)
    : _legacyGateway = gateway,
      _musicGateway = null;
  SongCommentsController.forMusicGateway(MusicGateway? gateway)
    : _musicGateway = gateway,
      _legacyGateway = null;
  final NeteaseGateway? _legacyGateway;
  final MusicGateway? _musicGateway;
  MusicGateway? get musicGateway => _musicGateway;
  MusicId _song(String key) =>
      MusicId.tryParse(key) ?? _musicGateway!.id(MusicEntityKind.song, key);
  static const pageSize = 20;
  String? trackId;
  int _accountId = 0, _generation = 0, _offset = 0;
  bool _disposed = false, _loaded = false;
  Future<void>? _opening;
  bool _retryMore = false;
  final Map<int, SongComment> _comments = {};
  final List<int> _hot = [], _latest = [];
  final Set<int> _pendingLikes = {}, _overriddenLikes = {};
  bool loading = false,
      loadingMore = false,
      hasMore = false,
      unsupported = false;
  int total = 0;
  String? error, actionError;
  bool loginRequired = false;

  List<SongComment> get hot => [for (final id in _hot) _comments[id]!];
  List<SongComment> get latest {
    final hotIds = _hot.toSet();
    return [
      for (final id in _latest)
        if (!hotIds.contains(id)) _comments[id]!,
    ];
  }

  bool get isEmpty => _hot.isEmpty && _latest.isEmpty;
  bool isLiking(int id) => _pendingLikes.contains(id);
  bool get reacting => _pendingLikes.isNotEmpty;
  bool _current(int generation) => !_disposed && generation == _generation;

  Future<void> openSong(String id, {required int accountId}) {
    if (_disposed) return Future.value();
    if (trackId == id && _accountId == accountId) {
      if (_opening != null) return _opening!;
      if (_loaded) return Future.value();
    }
    trackId = id;
    _accountId = accountId;
    ++_generation;
    _offset = 0;
    total = 0;
    _loaded = false;
    _opening = null;
    _retryMore = false;
    _comments.clear();
    _hot.clear();
    _latest.clear();
    _pendingLikes.clear();
    _overriddenLikes.clear();
    error = null;
    actionError = null;
    loginRequired = false;
    loadingMore = false;
    hasMore = false;
    unsupported = _legacyGateway != null
        ? (int.tryParse(id) ?? 0) <= 0
        : _musicGateway == null ||
              !_musicGateway.supports(MusicCapability.comments);
    if (unsupported) {
      loading = false;
      _loaded = true;
      notifyListeners();
      return Future.value();
    }
    return _opening = _load(first: true);
  }

  Future<void> refresh() async {
    if (loading || loadingMore || unsupported || trackId == null) return;
    // Do not allow a refresh to replace in-flight optimistic reactions.
    if (_pendingLikes.isNotEmpty) return;
    ++_generation;
    _overriddenLikes.clear();
    await _load(first: true);
  }

  Future<void> loadMore() async {
    if (loading || loadingMore || !hasMore || unsupported) return;
    await _load(first: false);
  }

  Future<void> retry() => _retryMore ? loadMore() : refresh();

  Future<void> _load({required bool first}) async {
    final generation = _generation;
    final songId = trackId!;
    if (first) {
      loading = true;
    } else {
      loadingMore = true;
    }
    error = null;
    notifyListeners();
    try {
      final page = _musicGateway != null
          ? await _musicGateway.comments(
              _song(songId),
              limit: pageSize,
              offset: first ? 0 : _offset,
            )
          : SongCommentPage.fromJson(
              await _legacyGateway!.songComments(
                int.parse(songId),
                limit: pageSize,
                offset: first ? 0 : _offset,
              ),
            );
      if (!_current(generation)) return;
      if (first) {
        _hot.clear();
        _latest.clear();
      }
      for (final comment in [...page.hot, ...page.latest]) {
        if (!_overriddenLikes.contains(comment.id)) {
          _comments[comment.id] = comment;
        }
      }
      if (first) _hot.addAll(page.hot.map((comment) => comment.id).toSet());
      final existing = _latest.toSet();
      _latest.addAll(
        page.latest.map((comment) => comment.id).where(existing.add),
      );
      if (first) {
        final visible = {..._hot, ..._latest};
        _comments.removeWhere((id, _) => !visible.contains(id));
        _overriddenLikes.retainAll(visible);
      }
      _offset = (first ? 0 : _offset) + page.receivedCount;
      total = page.total;
      hasMore = page.more && page.receivedCount > 0;
      _loaded = true;
    } catch (_) {
      if (_current(generation)) {
        _retryMore = !first;
        error = '评论加载失败，请重试。';
      }
    } finally {
      if (_current(generation)) {
        loading = false;
        loadingMore = false;
        _opening = null;
        notifyListeners();
      }
    }
  }

  Future<void> toggleLike(int id) async {
    final previous = _comments[id];
    if (previous == null || _accountId <= 0 || _pendingLikes.contains(id)) {
      return;
    }
    final generation = _generation;
    final wanted = !previous.liked;
    final wasOverridden = _overriddenLikes.contains(id);
    _pendingLikes.add(id);
    _overriddenLikes.add(id);
    _comments[id] = previous.withLike(
      wanted,
      previous.likedCount + (wanted ? 1 : -1),
    );
    actionError = null;
    loginRequired = false;
    notifyListeners();
    try {
      if (_musicGateway != null) {
        await _musicGateway.setCommentLiked(_song(trackId!), id, wanted);
      } else {
        await _legacyGateway!.setSongCommentLiked(
          int.parse(trackId!),
          id,
          wanted,
        );
      }
    } catch (error) {
      if (_current(generation)) {
        _comments[id] = previous;
        if (!wasOverridden) _overriddenLikes.remove(id);
        loginRequired =
            error is GatewayServiceException && error.code == 301 ||
            error is PluginException && error.code == 301;
        actionError = loginRequired ? '登录已失效，请重新登录后点赞。' : '点赞失败，请稍后重试。';
      }
    } finally {
      if (_current(generation)) {
        _pendingLikes.remove(id);
        notifyListeners();
      }
    }
  }

  void dismissActionError() {
    actionError = null;
    loginRequired = false;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    ++_generation;
    super.dispose();
  }
}
