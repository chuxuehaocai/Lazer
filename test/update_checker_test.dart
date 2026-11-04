import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/updates/release_version.dart';
import 'package:lazer_nextgen/updates/update_checker.dart';
import 'package:lazer_nextgen/updates/update_dialog.dart';
import 'package:lazer_nextgen/ui/shell.dart';
import 'package:lazer_nextgen/theme/apple_design.dart';

http.Response _releases(List<Map<String, Object?>> releases) =>
    http.Response.bytes(
      utf8.encode(jsonEncode(releases)),
      200,
      headers: <String, String>{
        'content-type': 'application/json; charset=utf-8',
      },
    );

Map<String, Object?> _release(
  String tag, {
  bool prerelease = false,
  bool draft = false,
  String? body,
}) => <String, Object?>{
  'tag_name': tag,
  'name': 'Lazer $tag',
  'body': body ?? 'Changes in $tag',
  'html_url': 'https://github.com/chuxuehaocai/Lazer/releases/tag/$tag',
  'prerelease': prerelease,
  'draft': draft,
  'published_at': '2026-10-20T12:00:00Z',
};

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  group('release versions', () {
    test('accepts tags, short versions and build suffixes', () {
      expect(ReleaseVersion.parse('v2.0.0-beta.2')?.normalized, '2.0.0-beta.2');
      expect(ReleaseVersion.parse('1.5')?.normalized, '1.5.0');
      expect(ReleaseVersion.parse('2.0.0+5')?.normalized, '2.0.0');
      expect(
        ReleaseVersion.parse('2.0.0-beta.2+5')?.normalized,
        '2.0.0-beta.2',
      );
    });

    test('rejects branch names and malformed tags', () {
      expect(ReleaseVersion.parse('nextgen'), isNull);
      expect(ReleaseVersion.parse(''), isNull);
      expect(ReleaseVersion.parse('v2.0-beta..1'), isNull);
      expect(ReleaseVersion.parse('v2.x.0'), isNull);
    });

    test('compares numeric pre-release identifiers and final releases', () {
      final ReleaseVersion beta2 = ReleaseVersion.parse('2.0.0-beta.2')!;
      final ReleaseVersion beta10 = ReleaseVersion.parse('2.0.0-beta.10')!;
      final ReleaseVersion stable = ReleaseVersion.parse('2.0.0')!;
      expect(beta2.compareTo(beta10), lessThan(0));
      expect(beta10.compareTo(stable), lessThan(0));
      expect(stable.compareTo(beta2), greaterThan(0));
      expect(
        ReleaseVersion.parse('2.0.0-beta.2') ==
            ReleaseVersion.parse('v2.0.0-beta.2+9'),
        isTrue,
      );
    });
  });

  group('update checker', () {
    test('offers the newest release newer than a pre-release build', () async {
      final UpdateChecker checker = UpdateChecker(
        fetch: (Uri _) async => _releases(<Map<String, Object?>>[
          _release('v2.0.0-beta.3', prerelease: true),
          _release('v2.0.0-beta.2', prerelease: true),
          _release('v1.5'),
        ]),
      );
      final AppRelease? release = await checker.findUpdate(
        ReleaseVersion.parse('2.0.0-beta.2')!,
        includePrerelease: true,
      );
      expect(release, isNotNull);
      expect(release!.version.normalized, '2.0.0-beta.3');
      expect(release.prerelease, isTrue);
      expect(release.url, contains('/releases/tag/v2.0.0-beta.3'));
    });

    test('does not push a stable build onto a pre-release', () async {
      final UpdateChecker checker = UpdateChecker(
        fetch: (Uri _) async => _releases(<Map<String, Object?>>[
          _release('v2.0.0', prerelease: false),
          _release('v2.1.0-beta.1', prerelease: true),
        ]),
      );
      final AppRelease? release = await checker.findUpdate(
        ReleaseVersion.parse('2.0.0')!,
      );
      expect(release, isNull, reason: '2.1.0-beta.1 is a pre-release');
    });

    test('a stable build still receives a newer final release', () async {
      final UpdateChecker checker = UpdateChecker(
        fetch: (Uri _) async => _releases(<Map<String, Object?>>[
          _release('v2.0.0'),
          _release('v2.1.0'),
        ]),
      );
      final AppRelease? release = await checker.findUpdate(
        ReleaseVersion.parse('2.0.0')!,
      );
      expect(release?.version.normalized, '2.1.0');
    });

    test('skips drafts and malformed tags instead of failing', () async {
      final UpdateChecker checker = UpdateChecker(
        fetch: (Uri _) async => _releases(<Map<String, Object?>>[
          _release('v3.0.0', draft: true),
          _release('nightly'),
          _release('v2.0.0-beta.3', prerelease: true),
        ]),
      );
      final List<AppRelease> all = await checker.releases();
      expect(all.map((AppRelease r) => r.tag), <String>['v2.0.0-beta.3']);
    });

    test('reports an HTTP failure', () async {
      final UpdateChecker checker = UpdateChecker(
        fetch: (Uri _) async => http.Response('rate limited', 403),
      );
      await expectLater(
        checker.releases(),
        throwsA(isA<UpdateCheckException>()),
      );
    });
  });

  group('AppState update flow', () {
    test('a future check timestamp does not suppress updates', () {
      final state = AppState();
      addTearDown(state.dispose);
      final now = DateTime(2026, 11, 4);
      state.updateCheckedAt = now
          .add(const Duration(days: 30))
          .millisecondsSinceEpoch;
      expect(state.autoUpdateCheckDue(now: now), isTrue);
    });
    test('a skip silences automatic checks but not the manual button', () async {
      int calls = 0;
      final UpdateChecker checker = UpdateChecker(
        fetch: (Uri _) async {
          calls++;
          return _releases(<Map<String, Object?>>[_release('v2.1.0')]);
        },
      );
      final AppState state = AppState(updateChecker: checker);
      addTearDown(state.dispose);

      final AppRelease? release = await state.checkForUpdates();
      expect(release?.version.normalized, '2.1.0');
      expect(state.updateError, isNull);
      await state.skipUpdate(release!);
      expect(state.skippedUpdateVersion, '2.1.0');
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('lazer_skipped_update'), '2.1.0');

      // Pretend the daily interval elapsed so the cadence is not what filters.
      state.updateCheckedAt = 0;
      expect(await state.checkForUpdates(), isNull);
      expect(await state.checkForUpdates(manual: true), isNotNull);
      expect(calls, 3);
    });

    test('the daily cadence prevents repeat requests', () async {
      int calls = 0;
      final UpdateChecker checker = UpdateChecker(
        fetch: (Uri _) async {
          calls++;
          return _releases(<Map<String, Object?>>[_release('v2.1.0')]);
        },
      );
      final AppState state = AppState(updateChecker: checker);
      addTearDown(state.dispose);
      expect(state.autoUpdateCheckDue(), isTrue);
      expect(await state.checkForUpdates(), isNotNull);
      expect(state.autoUpdateCheckDue(), isFalse);
      expect(await state.checkForUpdates(), isNull);
      expect(calls, 1);
      // A manual check always reaches the network.
      expect(await state.checkForUpdates(manual: true), isNotNull);
      expect(calls, 2);
    });

    test('a network failure is recorded without throwing', () async {
      final UpdateChecker checker = UpdateChecker(
        fetch: (Uri _) async => http.Response('no', 500),
      );
      final AppState state = AppState(updateChecker: checker);
      addTearDown(state.dispose);
      expect(await state.checkForUpdates(), isNull);
      expect(state.updateError, isNotNull);
      expect(state.updateChecking, isFalse);
      // A failed check stays due, so the next launch retries.
      expect(state.autoUpdateCheckDue(), isTrue);
    });
  });

  testWidgets('startup retains an update found behind another dialog', (
    tester,
  ) async {
    var calls = 0;
    final state = AppState(
      updateChecker: UpdateChecker(
        fetch: (_) async {
          calls++;
          return _releases([_release('v2.1.0')]);
        },
      ),
    );
    addTearDown(state.dispose);
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        theme: buildAppleTheme(),
        home: AppShell(state: state, autoCheckUpdates: true),
      ),
    );
    showDialog<void>(
      context: navigator.currentContext!,
      builder: (_) => const AlertDialog(content: Text('Existing dialog')),
    );
    await tester.pump(const Duration(seconds: 4));
    await tester.pump();
    expect(calls, 1);
    expect(find.text('发现新版本'), findsNothing);
    navigator.currentState!.pop();
    await tester.pump(const Duration(seconds: 5));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('发现新版本'), findsOneWidget);
    expect(calls, 1, reason: 'the successful response is retained');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('manually skipping a deferred update prevents its later prompt', (
    tester,
  ) async {
    var calls = 0;
    final state = AppState(
      updateChecker: UpdateChecker(
        fetch: (_) async {
          calls++;
          return _releases([_release('v2.1.0')]);
        },
      ),
    );
    addTearDown(state.dispose);
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        theme: buildAppleTheme(),
        home: AppShell(state: state, autoCheckUpdates: true),
      ),
    );
    showDialog<void>(
      context: navigator.currentContext!,
      builder: (_) => const AlertDialog(content: Text('Existing dialog')),
    );
    await tester.pump(const Duration(seconds: 4));
    await tester.pump();
    expect(calls, 1);
    expect(find.text('发现新版本'), findsNothing);

    final release = (await state.checkForUpdates(manual: true))!;
    showUpdateDialog(navigator.currentContext!, state, release);
    await tester.pumpAndSettle();
    await tester.tap(find.text('跳过此版本'));
    await tester.pumpAndSettle();
    expect(state.skippedUpdateVersion, '2.1.0');
    navigator.currentState!.pop();
    await tester.pump(const Duration(seconds: 5));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('发现新版本'), findsNothing);
    expect(
      calls,
      2,
      reason: 'discarding the deferred release needs no new request',
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('failed startup check retries during the same session', (
    tester,
  ) async {
    var calls = 0;
    final state = AppState(
      updateChecker: UpdateChecker(
        fetch: (_) async {
          calls++;
          return calls == 1
              ? http.Response('unavailable', 503)
              : _releases([_release('v2.1.0')]);
        },
      ),
    );
    addTearDown(state.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppleTheme(),
        home: AppShell(state: state, autoCheckUpdates: true),
      ),
    );
    await tester.pump(const Duration(seconds: 4));
    await tester.pump();
    expect(calls, 1);
    expect(state.updateError, isNotNull);
    await tester.pump(const Duration(minutes: 5));
    await tester.pump(const Duration(seconds: 1));
    expect(calls, 2);
    expect(find.text('发现新版本'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('the update prompt can skip a release', (tester) async {
    final UpdateChecker checker = UpdateChecker(
      fetch: (Uri _) async => _releases(<Map<String, Object?>>[
        _release('v2.1.0', body: '新内容\n第二行'),
      ]),
    );
    final AppState state = AppState(updateChecker: checker);
    addTearDown(state.dispose);
    final AppRelease release = (await state.checkForUpdates(manual: true))!;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (BuildContext context) => TextButton(
              onPressed: () => showUpdateDialog(context, state, release),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('发现新版本'), findsOneWidget);
    expect(find.text('前往下载'), findsOneWidget);
    expect(find.text('跳过此版本'), findsOneWidget);
    expect(find.textContaining('2.1.0'), findsWidgets);

    await tester.tap(find.text('跳过此版本'));
    await tester.pumpAndSettle();
    expect(state.skippedUpdateVersion, '2.1.0');
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('lazer_skipped_update'), '2.1.0');
    expect(find.textContaining('已跳过'), findsOneWidget);
  });
}
