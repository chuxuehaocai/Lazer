import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/theme/apple_design.dart';
import 'package:lazer_nextgen/ui/playlist_page.dart';

void main() {
  testWidgets('a very long playlist name does not overflow the header', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    const Playlist playlist = Playlist(
      id: 'long-name',
      name: '这是一张名字非常非常长的歌单，用来确认标题换成两行以后不会把下方的播放全部按钮挤出固定高度的封面区域',
      description: '说明文字也可能很长，用来模拟歌单详情接口返回的完整简介，确保标题和简介同时占据多行时布局仍然稳定。',
      trackIds: <String>[],
      trackCount: 128,
      coverSeed: 1,
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppleTheme(),
        home: Scaffold(
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: AppPlaylistHeader(
              playlist: playlist,
              compact: false,
              onPlay: () {},
              onDownload: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('播放全部'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
