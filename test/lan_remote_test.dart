import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/state/ui_preferences.dart';
import 'package:lazer_nextgen/tv/lan_remote.dart';
import 'package:lazer_nextgen/tv/tv_mode.dart';

class _LoopbackHttp extends HttpOverrides {}

Future<void> _ready(LanRemoteController remote) async {
  if (remote.urls.isNotEmpty) return;
  final completer = Completer<void>();
  void changed() {
    if ((remote.urls.isNotEmpty || remote.error != null) &&
        !completer.isCompleted) {
      completer.complete();
    }
  }

  remote.addListener(changed);
  try {
    await completer.future.timeout(const Duration(seconds: 5));
  } finally {
    remote.removeListener(changed);
  }
  expect(remote.error, isNull);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'remote is opt-in, authenticates commands and stops outside TV',
    () async {
      // This integration test talks only to its own loopback HTTP server.
      HttpOverrides.global = null;
      final state = AppState()..surface = AppSurface.tv;
      final remote = LanRemoteController(
        state,
        bindAddress: InternetAddress.loopbackIPv4,
      );
      final client = HttpClient();
      addTearDown(() {
        client.close(force: true);
        remote.dispose();
        state.dispose();
      });
      await remote.initialize();
      expect(remote.running, isFalse);
      await remote.setEnabled(true);
      await _ready(remote);
      final uri = Uri.parse(remote.urls.single);

      final forbidden = await (await client.getUrl(
        uri.replace(path: '/state', query: ''),
      )).close();
      expect(forbidden.statusCode, HttpStatus.forbidden);
      await forbidden.drain<void>();

      final request = await client.postUrl(uri.replace(path: '/command'));
      request.headers.set('origin', uri.origin);
      request.write(jsonEncode({'action': 'volume', 'value': .32}));
      final response = await request.close();
      expect(response.statusCode, HttpStatus.ok);
      expect(
        (jsonDecode(await utf8.decoder.bind(response).join()) as Map)['volume'],
        .32,
      );
      expect(state.volume, .32);

      final crossSite = await client.postUrl(uri.replace(path: '/command'));
      crossSite.headers.set('origin', 'http://unrelated.example');
      crossSite.write(jsonEncode({'action': 'volume', 'value': .9}));
      final rejected = await crossSite.close();
      expect(rejected.statusCode, HttpStatus.forbidden);
      await rejected.drain<void>();
      expect(state.volume, .32);

      await state.setSurface(AppSurface.standard);
      expect(remote.running, isFalse);
      expect(remote.urls, isEmpty);
    },
  );

  test(
    'a television keeps the remote when its density profile is not tv',
    () async {
      // The large-screen UI follows the hardware, not the density preference; the
      // remote must use the same definition or it switches itself off while the
      // TV layout is still on screen.
      HttpOverrides.global = null;
      final state = AppState(deviceIsTelevision: true);
      await state.setSurface(AppSurface.standard);
      final remote = LanRemoteController(
        state,
        bindAddress: InternetAddress.loopbackIPv4,
      );
      addTearDown(() {
        remote.dispose();
        state.dispose();
      });
      await remote.initialize();
      await remote.setEnabled(true);
      await _ready(remote);
      expect(remote.running, isTrue);
      expect(state.surface, AppSurface.standard);
    },
  );

  test('restarts after TV mode changes during address discovery', () async {
    HttpOverrides.global = null;
    final state = AppState()..surface = AppSurface.tv;
    final discovering = Completer<void>();
    final continueDiscovery = Completer<void>();
    var discoveries = 0;
    final remote = LanRemoteController(
      state,
      interfaceAddresses: () async {
        if (discoveries++ == 0) {
          discovering.complete();
          await continueDiscovery.future;
        }
        return [InternetAddress.loopbackIPv4];
      },
    );
    final client = HttpClient();
    addTearDown(() {
      if (!continueDiscovery.isCompleted) continueDiscovery.complete();
      client.close(force: true);
      remote.dispose();
      state.dispose();
    });
    await remote.initialize();
    await remote.setEnabled(true);
    await discovering.future.timeout(const Duration(seconds: 5));
    expect(remote.running, isTrue);
    expect(remote.urls, isEmpty);

    await state.setSurface(AppSurface.standard);
    await state.setSurface(AppSurface.tv);
    continueDiscovery.complete();
    await _ready(remote);
    expect(discoveries, 2);
    final response = await (await client.getUrl(
      Uri.parse(remote.urls.single).replace(path: '/state'),
    )).close();
    expect(response.statusCode, HttpStatus.ok);
    await response.drain<void>();
  });

  testWidgets('browser requests update and submit the focused field', (
    tester,
  ) async {
    final state = AppState()..surface = AppSurface.tv;
    final remote = LanRemoteController(
      state,
      bindAddress: InternetAddress.loopbackIPv4,
    );
    final controller = TextEditingController();
    final focus = FocusNode();
    String? submitted;
    addTearDown(() {
      remote.dispose();
      state.dispose();
      controller.dispose();
      focus.dispose();
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TextField(
            focusNode: focus,
            controller: controller,
            textInputAction: TextInputAction.search,
            onSubmitted: (text) => submitted = text,
          ),
        ),
      ),
    );
    focus.requestFocus();
    await tester.pump();
    await tester.runAsync(() async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final client = HttpClient();
        try {
          await remote.initialize();
          await remote.setEnabled(true);
          await _ready(remote);
          final uri = Uri.parse(remote.urls.single);
          final page = await (await client.getUrl(uri)).close();
          expect(page.statusCode, HttpStatus.ok);
          expect(await utf8.decoder.bind(page).join(), contains('Lazer 遥控器'));
          for (final action in [
            {'action': 'text', 'text': '手机输入 中文 / OTF'},
            {'action': 'submit', 'text': '确认时直接发送的新文字'},
          ]) {
            final request = await client.postUrl(uri.replace(path: '/command'));
            request.headers.contentType = ContentType.json;
            request.headers.set('origin', uri.origin);
            request.write(jsonEncode(action));
            final response = await request.close();
            expect(response.statusCode, HttpStatus.ok);
            await response.drain<void>();
          }
        } finally {
          client.close(force: true);
        }
      }, _LoopbackHttp());
    });
    await tester.pump();
    expect(controller.text, '确认时直接发送的新文字');
    expect(submitted, controller.text);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'remote navigates controls, edits and submits the focused input',
    (tester) async {
      final state = AppState();
      final remote = LanRemoteController(state);
      final controller = TextEditingController();
      final input = FocusNode();
      final button = FocusNode();
      var submissions = 0, taps = 0;
      addTearDown(() {
        remote.dispose();
        state.dispose();
        controller.dispose();
        input.dispose();
        button.dispose();
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TvScope(
              active: true,
              child: Column(
                children: [
                  TextField(
                    controller: controller,
                    focusNode: input,
                    onSubmitted: (_) => submissions++,
                  ),
                  TextButton(
                    focusNode: button,
                    onPressed: () => taps++,
                    child: const Text('button'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      input.requestFocus();
      await tester.pump();
      expect(remote.snapshot['input'], isTrue);
      await remote.command({'action': 'text', 'text': '测试 input'});
      await tester.pump();
      expect(controller.text, '测试 input');
      await remote.command({'action': 'submit'});
      expect(submissions, 1);
      button.requestFocus();
      await tester.pump();
      await remote.command({'action': 'key', 'key': 'select'});
      await tester.pump();
      expect(taps, 1);
      expect(tester.takeException(), isNull);
    },
  );
}
