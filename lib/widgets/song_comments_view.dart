import 'dart:async';

import 'package:flutter/material.dart';

import '../data/models.dart';
import '../data/song_comments.dart';
import '../l10n/app_localizations.dart';
import '../legacy/legacy_login.dart';
import '../state/app_state.dart';
import '../state/song_comments_controller.dart';
import '../theme/tokens.dart';
import '../utils/artwork.dart';
import 'accessible_controls.dart';
import 'animated_notice.dart';
import 'artwork_image.dart';
import 'interaction_feedback.dart';

/// Lazy rows, pagination and reactions listen only to the comment controller.
class SongCommentsView extends StatefulWidget {
  const SongCommentsView({
    super.key,
    required this.state,
    required this.track,
    required this.controller,
  });

  final AppState state;
  final Track track;
  final SongCommentsController controller;

  @override
  State<SongCommentsView> createState() => _SongCommentsViewState();
}

class _SongCommentsViewState extends State<SongCommentsView> {
  final ScrollController _scroll = ScrollController();
  late int _accountId;
  SongCommentsController get _comments => widget.controller;

  @override
  void initState() {
    super.initState();
    _accountId = widget.state.user.userId;
    widget.state.addListener(_accountChanged);
    _scroll.addListener(_maybeLoadMore);
    _scheduleBind();
  }

  void _scheduleBind() => WidgetsBinding.instance.addPostFrameCallback((_) {
    if (!mounted) return;
    if (_scroll.hasClients) _scroll.jumpTo(0);
    unawaited(
      _comments.openSong(widget.track.id, accountId: widget.state.user.userId),
    );
  });

  @override
  void didUpdateWidget(covariant SongCommentsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.state != widget.state) {
      oldWidget.state.removeListener(_accountChanged);
      widget.state.addListener(_accountChanged);
    }
    if (oldWidget.track.id != widget.track.id ||
        oldWidget.controller != widget.controller) {
      _scheduleBind();
    }
    _accountChanged();
  }

  void _accountChanged() {
    final int id = widget.state.user.userId;
    if (id == _accountId) return;
    _accountId = id;
    _scheduleBind();
  }

  void _maybeLoadMore() {
    if (_scroll.positions.length == 1 &&
        _scroll.position.extentAfter < 320 &&
        _comments.trackId == widget.track.id &&
        _comments.error == null) {
      unawaited(_comments.loadMore());
    }
  }

  Future<void> _like(int id) async {
    if (!widget.state.signedIn) {
      await showLegacyLoginDialog(context, widget.state);
      if (!mounted || !widget.state.signedIn) return;
      await _comments.openSong(
        widget.track.id,
        accountId: widget.state.user.userId,
      );
      if (!mounted) return;
    }
    await _comments.toggleLike(id);
  }

  Future<void> _loginAgain() async {
    final SessionUser previous = widget.state.user;
    await showLegacyLoginDialog(context, widget.state);
    if (!mounted ||
        !widget.state.signedIn ||
        identical(previous, widget.state.user)) {
      return;
    }
    _comments.dismissActionError();
    await _comments.refresh();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return AnimatedBuilder(
      animation: _comments,
      builder: (BuildContext context, _) {
        final bool bound = _comments.trackId == widget.track.id;
        final List<SongComment> hot = bound
            ? _comments.hot
            : const <SongComment>[];
        final List<SongComment> latest = bound
            ? _comments.latest
            : const <SongComment>[];
        final bool initialLoading =
            !bound || _comments.loading && _comments.isEmpty;
        final bool empty = bound && _comments.isEmpty;
        return Column(
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 10, 10, 2),
              child: Row(
                children: <Widget>[
                  // The count lives in the tab label elsewhere; repeating it
                  // here only added a header row above the wall.
                  const Spacer(),
                  AccessibleIconButton(
                    tooltip: '刷新评论',
                    onPressed:
                        !bound ||
                            _comments.loading ||
                            _comments.loadingMore ||
                            _comments.reacting ||
                            _comments.unsupported
                        ? null
                        : () => unawaited(_comments.refresh()),
                    icon: const Icon(Icons.refresh_rounded, size: 20),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: AnimatedNotice(
                message: _comments.actionError,
                onDismiss: _comments.dismissActionError,
              ),
            ),
            AnimatedSize(
              duration: AppMotion.standard,
              alignment: Alignment.topLeft,
              child: _comments.loginRequired
                  ? Align(
                      alignment: Alignment.centerLeft,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: TextButton(
                          onPressed: () => unawaited(_loginAgain()),
                          child: const TrText('重新登录'),
                        ),
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
            Expanded(
              child: TweenAnimationBuilder<double>(
                key: ValueKey<(String, bool, bool)>((
                  widget.track.id,
                  initialLoading,
                  empty,
                )),
                tween: Tween<double>(begin: 0, end: 1),
                duration: MediaQuery.disableAnimationsOf(context)
                    ? Duration.zero
                    : const Duration(milliseconds: 240),
                curve: AppMotion.emphasizedDecelerate,
                builder: (BuildContext context, double value, Widget? child) =>
                    Opacity(
                      opacity: value,
                      child: Transform.translate(
                        offset: Offset(0, (1 - value) * 10),
                        child: child,
                      ),
                    ),
                child: initialLoading
                    ? const Center(
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : empty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: <Widget>[
                              Icon(
                                Icons.forum_outlined,
                                size: 36,
                                color: scheme.onSurfaceVariant,
                              ),
                              const SizedBox(height: 16),
                              Text(
                                context.tr(
                                  _comments.unsupported
                                      ? '这首歌暂不支持查看评论'
                                      : _comments.error ?? '这首歌还没有评论',
                                ),
                                textAlign: TextAlign.center,
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  color: scheme.onSurfaceVariant,
                                ),
                              ),
                              if (_comments.error != null)
                                TextButton(
                                  onPressed: () => unawaited(_comments.retry()),
                                  child: const TrText('重试'),
                                ),
                            ],
                          ),
                        ),
                      )
                    : LayoutBuilder(
                        builder: (BuildContext context, BoxConstraints box) {
                          final int columns = ((box.maxWidth - 40) / 320)
                              .floor()
                              .clamp(1, 4);
                          return CustomScrollView(
                            controller: _scroll,
                            key: const PageStorageKey<String>('song-comments'),
                            slivers: <Widget>[
                              if (hot.isNotEmpty) ...<Widget>[
                                const SliverPadding(
                                  padding: EdgeInsets.fromLTRB(20, 16, 20, 4),
                                  sliver: SliverToBoxAdapter(
                                    child: _CommentsSectionLabel('热门评论'),
                                  ),
                                ),
                                _rows(hot, columns),
                              ],
                              if (latest.isNotEmpty) ...<Widget>[
                                const SliverPadding(
                                  padding: EdgeInsets.fromLTRB(20, 22, 20, 4),
                                  sliver: SliverToBoxAdapter(
                                    child: _CommentsSectionLabel('最新评论'),
                                  ),
                                ),
                                _rows(latest, columns),
                              ],
                              SliverToBoxAdapter(
                                child: Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    20,
                                    16,
                                    20,
                                    32,
                                  ),
                                  child: Center(
                                    child: _comments.loadingMore
                                        ? const SizedBox.square(
                                            dimension: 20,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 2,
                                            ),
                                          )
                                        : _comments.error != null
                                        ? Column(
                                            children: <Widget>[
                                              TrText(
                                                _comments.error!,
                                                style: theme.textTheme.bodySmall
                                                    ?.copyWith(
                                                      color: scheme
                                                          .onSurfaceVariant,
                                                    ),
                                              ),
                                              TextButton(
                                                onPressed: () => unawaited(
                                                  _comments.retry(),
                                                ),
                                                child: const TrText('重试'),
                                              ),
                                            ],
                                          )
                                        : _comments.hasMore
                                        ? TextButton(
                                            onPressed: () =>
                                                unawaited(_comments.loadMore()),
                                            child: const TrText('加载更多评论'),
                                          )
                                        : Text(
                                            context.tr('已显示全部评论'),
                                            style: theme.textTheme.labelMedium
                                                ?.copyWith(
                                                  color:
                                                      scheme.onSurfaceVariant,
                                                ),
                                          ),
                                  ),
                                ),
                              ),
                            ],
                          );
                        },
                      ),
              ),
            ),
          ],
        );
      },
    );
  }

  /// Build only the rows near the viewport as more comment pages arrive.
  /// Cards in a row can have different heights; the next row starts after the
  /// tallest one so no comment is clipped at large text scales.
  Widget _rows(List<SongComment> comments, int columns) => SliverPadding(
    padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
    sliver: SliverList.builder(
      itemCount: (comments.length + columns - 1) ~/ columns,
      itemBuilder: (BuildContext context, int row) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          for (int column = 0; column < columns; column++) ...<Widget>[
            if (column > 0) const SizedBox(width: 12),
            Expanded(
              child: row * columns + column < comments.length
                  ? _commentCard(comments[row * columns + column])
                  : const SizedBox.shrink(),
            ),
          ],
        ],
      ),
    ),
  );

  Widget _commentCard(SongComment comment) => RepaintBoundary(
    key: ValueKey<String>('comment-${comment.id}'),
    child: _CommentRow(
      comment: comment,
      pending: _comments.isLiking(comment.id),
      signedIn: widget.state.signedIn,
      onLike: () => unawaited(_like(comment.id)),
    ),
  );

  @override
  void dispose() {
    widget.state.removeListener(_accountChanged);
    _scroll.dispose();
    super.dispose();
  }
}

class _CommentsSectionLabel extends StatelessWidget {
  const _CommentsSectionLabel(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return Row(
      children: <Widget>[
        Text(
          context.tr(label),
          style: theme.textTheme.titleSmall?.copyWith(color: scheme.onSurface),
        ),
        const SizedBox(width: 12),
        Expanded(child: Divider(color: scheme.outlineVariant, height: 1)),
      ],
    );
  }
}

class _CommentRow extends StatelessWidget {
  const _CommentRow({
    required this.comment,
    required this.pending,
    required this.signedIn,
    required this.onLike,
  });

  final SongComment comment;
  final bool pending;
  final bool signedIn;
  final VoidCallback onLike;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final Color accent = comment.liked
        ? scheme.primary
        : scheme.onSurfaceVariant;
    final String? avatar = enlargedArtworkUrl(comment.avatarUrl, sizePx: 96);
    final Widget fallback = ColoredBox(
      color: scheme.surfaceContainerHighest,
      child: Icon(
        Icons.person_outline_rounded,
        color: scheme.onSurfaceVariant,
        size: 20,
      ),
    );
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.surface.withValues(alpha: .55),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              ExcludeSemantics(
                child: ClipOval(
                  child: SizedBox.square(
                    dimension: 36,
                    child: avatar == null
                        ? fallback
                        : Image(
                            image: ResizeImage(
                              ArtworkImage(avatar),
                              width: 96,
                              height: 96,
                            ),
                            fit: BoxFit.cover,
                            errorBuilder:
                                (
                                  BuildContext context,
                                  Object error,
                                  StackTrace? _,
                                ) => fallback,
                          ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      comment.author.isEmpty
                          ? context.tr('匿名用户')
                          : comment.author,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: scheme.onSurface,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (comment.time > 0) ...<Widget>[
                      const SizedBox(height: 2),
                      Text(
                        <String>[
                          MaterialLocalizations.of(context).formatMediumDate(
                            DateTime.fromMillisecondsSinceEpoch(comment.time),
                          ),
                          if (comment.location?.isNotEmpty ?? false)
                            comment.location!,
                        ].join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              AccessibleTooltip(
                message: comment.liked
                    ? '取消点赞'
                    : signedIn
                    ? '点赞'
                    : '登录后点赞',
                child: Semantics(
                  toggled: comment.liked,
                  child: IconButton(
                    onPressed: pending ? null : feedbackAction(context, onLike),
                    style: IconButton.styleFrom(
                      foregroundColor: accent,
                      disabledForegroundColor: accent.withValues(alpha: .65),
                      minimumSize: const Size(48, 48),
                    ),
                    icon: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        AnimatedSwitcher(
                          duration: AppMotion.quick,
                          transitionBuilder:
                              (Widget child, Animation<double> animation) =>
                                  ScaleTransition(
                                    scale: animation,
                                    child: FadeTransition(
                                      opacity: animation,
                                      child: child,
                                    ),
                                  ),
                          child: Icon(
                            comment.liked
                                ? Icons.thumb_up_rounded
                                : Icons.thumb_up_outlined,
                            key: ValueKey<bool>(comment.liked),
                            size: 18,
                          ),
                        ),
                        const SizedBox(width: 6),
                        AnimatedSwitcher(
                          duration: AppMotion.quick,
                          child: Text(
                            MaterialLocalizations.of(
                              context,
                            ).formatDecimal(comment.likedCount),
                            key: ValueKey<int>(comment.likedCount),
                            style: theme.textTheme.labelMedium?.copyWith(
                              color: accent,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          SelectableText(
            comment.content,
            style: theme.textTheme.bodyMedium?.copyWith(
              height: 1.7,
              color: scheme.onSurface,
            ),
          ),
          for (final CommentReply reply in comment.replies)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainer,
                  borderRadius: AppShape.mdRadius,
                ),
                child: Text(
                  _replyLine(reply),
                  style: theme.textTheme.bodySmall?.copyWith(
                    height: 1.6,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          const SizedBox(height: 18),
          Divider(height: 1, color: scheme.outlineVariant),
        ],
      ),
    );
  }
}

/// Author and content are user data; keep the full-width colon in the join
/// instead of passing the line through the translation table.
String _replyLine(CommentReply reply) => '${reply.author}：${reply.content}';
