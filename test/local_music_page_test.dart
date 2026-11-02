import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/theme/apple_design.dart';
import 'package:lazer_nextgen/local/local_music_page.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  testWidgets('the local music page offers files, folders and a scan', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1100, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final AppState state = AppState();
    addTearDown(state.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppleTheme(brightness: Brightness.dark),
        home: Scaffold(body: LocalMusicPage(state: state)),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('local-music-import')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('local-music-scan-empty')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('local-music-import-menu')));
    await tester.pumpAndSettle();
    expect(find.text('扫描系统音乐'), findsOneWidget);
    expect(find.text('选择文件夹…'), findsOneWidget);
  });

  testWidgets('the library card imports files and scans the system folder', (
    tester,
  ) async {
    final AppState state = AppState();
    addTearDown(state.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppleTheme(brightness: Brightness.dark),
        home: Scaffold(
          body: LocalMusicCard(state: state, onOpen: () {}),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('import-local-music')), findsOneWidget);
    expect(find.byKey(const ValueKey('scan-local-music')), findsOneWidget);
    expect(find.byKey(const ValueKey('open-local-music')), findsOneWidget);
  });
}
