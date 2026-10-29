import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/widgets/song_comments_view.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:lazer_nextgen/data/song_comments.dart';
import 'package:lazer_nextgen/gateway/gateway.dart';
import 'package:lazer_nextgen/gateway/transport.dart';
import 'package:lazer_nextgen/state/song_comments_controller.dart';

Map<String, dynamic> _comment(int id, {bool liked = false, int count = 10}) => {
  'commentId': id,
  'content': 'Comment $id · 在音乐里留下一点今天的心情。',
  'time': 1792080000000,
  'liked': liked,
  'likedCount': count,
  'user': {'userId': id + 100, 'nickname': 'Listener $id'},
};
Map<String, dynamic> _page({
  List<int> hot = const [1],
  List<int> latest = const [2],
  bool more = false,
}) => {
  'code': 200,
  'total': 120,
  'more': more,
  'hotComments': hot.map(_comment).toList(),
  'comments': latest.map(_comment).toList(),
};

class _Gateway extends NeteaseGateway {
  final reads = <(int, int)>[];
  final likes = <(int, int, bool)>[];
  Future<Map<String, dynamic>> Function(int, int) read = (_, _) async =>
      _page();
  Future<void> Function(int, int, bool) react = (_, _, _) async {};
  @override
  Future<Map<String, dynamic>> songComments(
    int songId, {
    int limit = 20,
    int offset = 0,
  }) {
    reads.add((songId, offset));
    return read(songId, offset);
  }

  @override
  Future<void> setSongCommentLiked(int songId, int commentId, bool liked) {
    likes.add((songId, commentId, liked));
    return react(songId, commentId, liked);
  }

  @override
  Future<List<GatewaySong>> songDetails(List<int> ids) async => [];
  @override
  Future<String> createQrKey() async => 'fixture-key';
  @override
  Future<String> createQrCodeUrl(String key) async =>
      'https://music.163.com/login?codekey=$key';
  @override
  Future<GatewayQrCheck> checkQrCode(
    String key, {
    String secureCaptcha = '',
  }) async => const GatewayQrCheck(code: 801);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('long comment pages build lazily and retain the last card', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final gateway = _Gateway();
    gateway.read = (_, _) async =>
        _page(hot: [], latest: List<int>.generate(500, (i) => i + 1));
    final controller = SongCommentsController(gateway);
    final state = AppState();
    addTearDown(controller.dispose);
    addTearDown(state.dispose);
    const track = Track(
      id: '42',
      title: 'Song',
      artist: 'Artist',
      album: 'Album',
      duration: Duration(minutes: 3),
      coverSeed: 1,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SongCommentsView(
            state: state,
            track: track,
            controller: controller,
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('comment-1')), findsOneWidget);
    expect(find.byKey(const ValueKey('comment-500')), findsNothing);
    final scroll = tester.state<ScrollableState>(find.byType(Scrollable).first);
    scroll.position.jumpTo(scroll.position.maxScrollExtent);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('comment-500')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test(
    'parses service comment IDs, nullable metadata, avatars and quoted replies',
    () {
      final comment = SongComment.fromJson({
        ..._comment(9646640244),
        'likedCount': '120',
        'user': {
          'userId': 7,
          'nickname': '名字',
          'avatarUrl': 'http://p1.music.126.net/a.jpg',
        },
        'ipLocation': null,
        'beReplied': [
          {
            'content': 'Earlier comment',
            'user': {'nickname': 'Other'},
          },
        ],
      });
      expect(comment.id, 9646640244);
      expect(comment.likedCount, 120);
      expect(comment.avatarUrl, 'https://p1.music.126.net/a.jpg');
      expect(comment.replies.single.author, 'Other');
      expect(comment.location, isNull);
    },
  );

  test(
    'paging uses received offsets, deduplicates rows and stops on an empty page',
    () async {
      final gateway = _Gateway();
      gateway.read = (_, offset) async => offset == 0
          ? _page(latest: [1, 2], more: true)
          : offset == 2
          ? _page(hot: [], latest: [2, 3], more: true)
          : _page(hot: [], latest: [], more: true);
      final controller = SongCommentsController(gateway);
      addTearDown(controller.dispose);
      await controller.openSong('42', accountId: 0);
      expect(controller.hot.map((c) => c.id), [1]);
      expect(controller.latest.map((c) => c.id), [2]);
      await controller.loadMore();
      expect(controller.latest.map((c) => c.id), [2, 3]);
      await controller.loadMore();
      await controller.loadMore();
      expect(controller.hasMore, false);
      expect(gateway.reads, [(42, 0), (42, 2), (42, 4)]);
      await controller.toggleLike(1);
      expect(gateway.likes, isEmpty);
    },
  );

  test('late pages cannot replace a newer song or disposed state', () async {
    final gateway = _Gateway();
    final old = Completer<Map<String, dynamic>>(),
        newer = Completer<Map<String, dynamic>>();
    gateway.read = (song, _) => song == 42 ? old.future : newer.future;
    final controller = SongCommentsController(gateway);
    final first = controller.openSong('42', accountId: 7);
    final second = controller.openSong('43', accountId: 7);
    newer.complete(_page(hot: [], latest: [43]));
    await second;
    old.complete(_page(latest: [42]));
    await first;
    expect(controller.trackId, '43');
    expect(controller.latest.single.id, 43);
    final pending = Completer<Map<String, dynamic>>();
    gateway.read = (_, _) => pending.future;
    final last = controller.openSong('44', accountId: 7);
    controller.dispose();
    pending.complete(_page());
    await last;
  });

  test(
    'likes update immediately, serialize each comment and roll back on failure',
    () async {
      final gateway = _Gateway();
      var reaction = Completer<void>();
      gateway.react = (_, _, _) => reaction.future;
      final controller = SongCommentsController(gateway);
      addTearDown(controller.dispose);
      await controller.openSong('42', accountId: 7);
      final like = controller.toggleLike(1);
      expect(controller.hot.single.liked, true);
      expect(controller.hot.single.likedCount, 11);
      await controller.toggleLike(1);
      await controller.refresh();
      expect(gateway.likes, [(42, 1, true)]);
      expect(gateway.reads, [(42, 0)]);
      reaction.completeError(GatewayServiceException(500, '/comment/like'));
      await like;
      expect(controller.hot.single.liked, false);
      expect(controller.hot.single.likedCount, 10);
      expect(controller.actionError, isNotNull);
      reaction = Completer<void>();
      final retry = controller.toggleLike(1);
      reaction.complete();
      await retry;
      expect(controller.hot.single.liked, true);
      final unlike = controller.toggleLike(1);
      await unlike;
      expect(controller.hot.single.liked, false);
      expect(controller.hot.single.likedCount, 10);
      expect(controller.isLiking(1), false);
      gateway.read = (_, _) async => {
        ..._page(),
        'hotComments': [_comment(1, count: 50)],
      };
      await controller.refresh();
      expect(
        controller.hot.single.likedCount,
        50,
        reason: 'refresh re-reads server counts after completed reactions',
      );
      gateway.react = (_, _, _) async {
        throw GatewayServiceException(301, '/comment/like');
      };
      await controller.toggleLike(1);
      expect(controller.loginRequired, true);
      expect(controller.hot.single.liked, false);
      controller.dismissActionError();
      expect(controller.loginRequired, false);
    },
  );

  test(
    'session changes clear reactions and old reaction failures stay on their song',
    () async {
      final gateway = _Gateway();
      final reaction = Completer<void>();
      gateway.react = (_, _, _) => reaction.future;
      final controller = SongCommentsController(gateway);
      addTearDown(controller.dispose);
      await controller.openSong('42', accountId: 7);
      final like = controller.toggleLike(1);
      await controller.openSong('43', accountId: 8);
      reaction.completeError(GatewayServiceException(301, '/comment/like'));
      await like;
      expect(controller.actionError, isNull);
      expect(controller.hot.single.liked, false);
      expect(controller.isLiking(1), false);
      await controller.openSong('43', accountId: 0);
      expect(gateway.reads.last, (43, 0));
      expect(gateway.reads, hasLength(3));
    },
  );

  test(
    'a failed next page retains rows and retries exactly that offset',
    () async {
      final gateway = _Gateway();
      var failed = false;
      gateway.read = (_, offset) async {
        if (offset == 0) return _page(more: true);
        if (!failed) {
          failed = true;
          throw StateError('offline');
        }
        return _page(hot: [], latest: [3]);
      };
      final controller = SongCommentsController(gateway);
      addTearDown(controller.dispose);
      await controller.openSong('42', accountId: 7);
      await controller.loadMore();
      expect(controller.latest.single.id, 2);
      expect(controller.error, isNotNull);
      await controller.retry();
      expect(controller.error, isNull);
      expect(controller.latest.map((c) => c.id), [2, 3]);
      expect(gateway.reads, [(42, 0), (42, 1), (42, 1)]);
    },
  );
}
