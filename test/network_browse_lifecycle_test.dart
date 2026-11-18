import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/network/network_browse_page.dart';
import 'package:lazer_nextgen/network/network_source.dart';
import 'package:lazer_nextgen/network/network_sources_controller.dart';
import 'package:lazer_nextgen/network/remote_source.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/theme/apple_design.dart';

class _Network extends NetworkSourcesController {
  _Network() : super(persist: false);
  final requests = <String>[];
  Future<RemoteListing> Function(String, String)? listing;
  Future<List<Track>> Function()? indexing;

  @override
  NetworkSource sourceById(String id) => NetworkSource(
    id: id,
    kind: NetworkSourceKind.webdav,
    name: 'Source $id',
    host: 'example.test',
    port: 80,
  );

  @override
  Future<RemoteListing> list(String sourceId, String path) {
    requests.add(sourceId);
    return listing?.call(sourceId, path) ?? Future.value(_audio(path));
  }

  @override
  Future<List<Track>> indexFolder(String sourceId, List<RemoteEntry> entries) =>
      indexing?.call() ?? Future.value([]);
}

RemoteListing _audio(String path) => RemoteListing(
  path: path,
  entries: const [
    RemoteEntry(name: 'song.mp3', path: '/song.mp3', isDirectory: false),
  ],
);

class _Playback extends AppState {
  int playRequests = 0;
  @override
  void playQueue(List<Track> tracks, {int startIndex = 0}) => playRequests++;
}

Future<void> _show(
  WidgetTester tester,
  _Playback state,
  _Network network, {
  String source = 'a',
  double scale = 1,
}) => tester.pumpWidget(
  MaterialApp(
    theme: buildAppleTheme(),
    home: MediaQuery(
      data: MediaQueryData(textScaler: TextScaler.linear(scale)),
      child: Scaffold(
        body: NetworkBrowsePage(
          state: state,
          controller: network,
          sourceId: source,
          embedded: true,
        ),
      ),
    ),
  ),
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('changing source reloads and ignores the old pending listing', (
    tester,
  ) async {
    final state = _Playback();
    final network = _Network();
    addTearDown(state.dispose);
    addTearDown(network.dispose);
    final first = Completer<RemoteListing>();
    network.listing = (id, path) => id == 'a'
        ? first.future
        : Future.value(const RemoteListing(path: '/new', entries: []));
    await _show(tester, state, network);
    await _show(tester, state, network, source: 'b');
    await tester.pump();
    expect(network.requests, ['a', 'b']);
    first.complete(_audio('/old'));
    await tester.pump();
    expect(find.byKey(const ValueKey('network-file-/song.mp3')), findsNothing);
    expect(find.textContaining('example.test · new'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('stale indexing cannot start playback on a replacement source', (
    tester,
  ) async {
    final state = _Playback();
    final network = _Network();
    addTearDown(state.dispose);
    addTearDown(network.dispose);
    final pending = Completer<List<Track>>();
    network.indexing = () => pending.future;
    await _show(tester, state, network);
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('network-browse-play-all')));
    await _show(tester, state, network, source: 'b');
    pending.complete([]);
    await tester.pump();
    expect(state.playRequests, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('large network directories only mount visible folder rows', (
    tester,
  ) async {
    final state = _Playback();
    final network = _Network();
    addTearDown(state.dispose);
    addTearDown(network.dispose);
    network.listing = (_, path) async => RemoteListing(
      path: path,
      entries: [
        for (var i = 0; i < 500; i++)
          RemoteEntry(name: 'Folder $i', path: '/$i', isDirectory: true),
      ],
    );
    await _show(tester, state, network);
    await tester.pump();
    final rows = find.byWidgetPredicate(
      (widget) => widget.key.toString().startsWith("[<'network-folder-/"),
    );
    expect(rows.evaluate().length, inInclusiveRange(1, 30));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('folder actions wrap at phone width with large text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final state = _Playback();
    final network = _Network();
    addTearDown(state.dispose);
    addTearDown(network.dispose);
    await _show(tester, state, network, scale: 1.6);
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(
      find.byKey(const ValueKey('network-browse-scan')).hitTestable(),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
