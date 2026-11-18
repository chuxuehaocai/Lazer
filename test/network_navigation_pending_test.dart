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
  final folder = Completer<RemoteListing>();
  int indexRequests = 0;

  @override
  NetworkSource sourceById(String id) => NetworkSource(
    id: id,
    kind: NetworkSourceKind.webdav,
    name: 'Fixture',
    host: 'example.test',
    port: 80,
  );

  @override
  Future<RemoteListing> list(String sourceId, String path) => path == '/next'
      ? folder.future
      : Future.value(
          const RemoteListing(
            path: '/',
            entries: [
              RemoteEntry(name: 'Next', path: '/next', isDirectory: true),
              RemoteEntry(
                name: 'old.mp3',
                path: '/old.mp3',
                isDirectory: false,
              ),
            ],
          ),
        );

  @override
  Future<List<Track>> indexFolder(
    String sourceId,
    List<RemoteEntry> entries,
  ) async {
    indexRequests++;
    return [];
  }
}

class _Playback extends AppState {
  @override
  void playQueue(List<Track> tracks, {int startIndex = 0}) {}
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('opening a folder retires the previous listing before loading', (
    tester,
  ) async {
    final state = _Playback();
    final network = _Network();
    addTearDown(state.dispose);
    addTearDown(network.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppleTheme(),
        home: Scaffold(
          body: NetworkBrowsePage(
            state: state,
            controller: network,
            sourceId: 'source',
            embedded: true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Next'));
    await tester.pump();
    final oldFile = find.byKey(const ValueKey('network-file-/old.mp3'));
    final staleFileVisible = oldFile.hitTestable().evaluate().isNotEmpty;
    if (staleFileVisible) await tester.tap(oldFile);
    await tester.pump();
    network.folder.complete(const RemoteListing(path: '/next', entries: []));
    await tester.pumpAndSettle();
    expect(network.indexRequests, 0);
    expect(staleFileVisible, isFalse);
    expect(find.byKey(const ValueKey('network-file-/old.mp3')), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
