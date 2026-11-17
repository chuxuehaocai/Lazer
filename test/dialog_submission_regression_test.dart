import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lazer_nextgen/data/audio_quality.dart';
import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/data/song_comments.dart';
import 'package:lazer_nextgen/downloads/download_dialog.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/state/song_comments_controller.dart';
import 'package:lazer_nextgen/theme/apple_design.dart';
import 'package:lazer_nextgen/ui/login.dart';
import 'package:lazer_nextgen/widgets/playlist_picker_dialog.dart';
import 'package:lazer_nextgen/widgets/song_comments_view.dart';

import 'support/music_gateway.dart';

const _track = Track(
  id: 'fixture-song',
  title: 'Song',
  artist: 'Artist',
  album: 'Album',
  duration: Duration(minutes: 3),
  coverSeed: 1,
);
const _created = Playlist(
  id: 'created',
  name: 'New playlist',
  trackIds: [],
  coverSeed: 1,
);

class _State extends AppState {
  _State() : super(catalog: Catalog(gateway: TestMusicGateway())) {
    collections = const UserCollections(created: [_created]);
  }
  bool authenticated = true;
  int creations = 0, additions = 0, qualityWrites = 0, directoryWrites = 0;
  bool failFirstAddition = false,
      failStorage = false,
      failAuthentication = false;
  Completer<Playlist?>? creation;
  Duration qualityDelay = Duration.zero;
  Completer<AuthOutcome>? authentication;
  Set<String> methods = {'password', 'cookie'};
  Completer<String?>? qrStart;
  Completer<int>? qrPoll;
  int qrPolls = 0;

  @override
  bool get signedIn => authenticated;
  @override
  SessionUser get user => authenticated
      ? const SessionUser(
          name: 'User',
          handle: 'user',
          method: AuthMethod.cookie,
          detail: '',
          userId: 7,
        )
      : SessionUser.guest;
  @override
  Set<String> get musicAuthenticationMethods => methods;
  @override
  Future<String?> beginQrLogin() async =>
      qrStart?.future ?? 'https://example.com/qr';
  @override
  Future<int> pollQrLogin(String url) async {
    qrPolls++;
    return qrPoll?.future ?? 801;
  }

  @override
  Future<Playlist?> createCloudPlaylist(
    String name, {
    bool privacy = false,
  }) async {
    creations++;
    return creation == null ? _created : creation!.future;
  }

  @override
  Future<void> addSongToCloudPlaylist(String playlistId, String trackId) async {
    additions++;
    if (failFirstAddition && additions == 1) {
      throw StateError('temporary add failure');
    }
  }

  @override
  Future<void> setDownloadQuality(AudioQuality value) async {
    qualityWrites++;
    if (qualityDelay > Duration.zero) await Future<void>.delayed(qualityDelay);
  }

  @override
  Future<void> setDownloadDirectory(String? value) async {
    directoryWrites++;
    if (failStorage) throw StateError('preference write failed');
  }

  @override
  Future<AuthOutcome> signInWithPassword(
    String account,
    String password, {
    String countryCode = '86',
  }) async {
    if (failAuthentication) throw StateError('authentication unavailable');
    return authentication?.future ?? const AuthOutcome(false);
  }
}

class _Comments extends SongCommentsController {
  _Comments() : super(GatewayRegistry());
  final List<String> likedIds = [];
  @override
  bool get isEmpty => false;
  @override
  List<SongComment> get hot => const [
    SongComment(id: 'old-comment', content: 'A comment', author: 'Listener'),
  ];
  @override
  List<SongComment> get latest => const [];
  @override
  Future<void> openSong(String id, {required int accountId}) async {
    trackId = id;
    notifyListeners();
  }

  @override
  Future<void> toggleLike(String id) async {
    likedIds.add(id);
  }
}

Future<void> _open(
  WidgetTester tester,
  Future<void> Function(BuildContext) action, {
  bool disableAnimations = true,
  bool settle = true,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppleTheme(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(disableAnimations: disableAnimations),
        child: child!,
      ),
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => unawaited(action(context)),
            child: const Text('Open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open'));
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
}

Future<void> _waitUntil(bool Function() ready) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    if (ready()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  throw StateError('dialog did not finish its operation');
}

_State _state(WidgetTester tester) {
  final state = _State();
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
    state.localLibrary.dispose();
  });
  return state;
}

VoidCallback _downloadConfirm(WidgetTester tester) => tester
    .widget<FilledButton>(
      find.descendant(
        of: find.byKey(const ValueKey('download-confirm')),
        matching: find.byType(FilledButton),
      ),
    )
    .onPressed!;

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
    'download write probe preserves an existing same-name user file',
    (tester) async {
      final state = _state(tester);
      final root = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('lazer-dialog-'),
      ))!;
      addTearDown(() => root.delete(recursive: true));
      state.downloadDirectory = root.path;
      final existing = File(
        '${root.path}${Platform.pathSeparator}.lazer_write_test',
      );
      await tester.runAsync(() => existing.writeAsString('user data'));
      await _open(tester, (context) async {
        await showDownloadDialog(context, state, tracks: [_track]);
      });
      final confirm = _downloadConfirm(tester);
      await tester.runAsync(() async {
        confirm();
        await _waitUntil(() => state.directoryWrites == 1);
      });
      await tester.pumpAndSettle();
      final preserved = await tester.runAsync(
        () async => await existing.exists() ? existing.readAsString() : null,
      );
      expect(preserved, 'user data');
    },
  );

  testWidgets(
    'download confirm rejects a second submission before the next frame',
    (tester) async {
      final state = _state(tester)
        ..qualityDelay = const Duration(milliseconds: 80);
      final root = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('lazer-dialog-'),
      ))!;
      addTearDown(() => root.delete(recursive: true));
      state.downloadDirectory = root.path;
      await _open(tester, (context) async {
        await showDownloadDialog(context, state, tracks: [_track]);
      });
      final confirm = _downloadConfirm(tester);
      await tester.runAsync(() async {
        confirm();
        await _waitUntil(() => state.qualityWrites == 1);
        confirm();
        await Future<void>.delayed(const Duration(milliseconds: 30));
        await _waitUntil(() => state.directoryWrites >= 1);
        await Future<void>.delayed(const Duration(milliseconds: 80));
      });
      await tester.pumpAndSettle();
      expect(state.qualityWrites, 1);
      expect(state.directoryWrites, 1);
    },
  );

  testWidgets(
    'playlist retry reuses the created playlist after adding the song fails',
    (tester) async {
      final state = _state(tester)..failFirstAddition = true;
      await _open(
        tester,
        (context) => showAddToPlaylistDialog(context, state, track: _track),
      );
      await tester.tap(find.text('新建歌单'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'New playlist');
      await tester.tap(find.text('创建'));
      await tester.pumpAndSettle();
      expect(find.text('添加失败，请稍后重试。'), findsOneWidget);
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
      expect(state.creations, 1);
      expect(state.additions, 2);
      expect(find.byType(AlertDialog), findsNothing);
    },
  );

  testWidgets(
    'download preference errors restore the submit button and allow retry',
    (tester) async {
      final state = _state(tester)..failStorage = true;
      final root = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('lazer-dialog-'),
      ))!;
      addTearDown(() => root.delete(recursive: true));
      state.downloadDirectory = root.path;
      await _open(tester, (context) async {
        await showDownloadDialog(context, state, tracks: [_track]);
      });
      final confirm = _downloadConfirm(tester);
      await tester.runAsync(() async {
        confirm();
        await _waitUntil(() => state.directoryWrites == 1);
      });
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('操作失败，请稍后重试。'), findsOneWidget);
      state.failStorage = false;
      final retry = _downloadConfirm(tester);
      await tester.runAsync(() async {
        retry();
        await _waitUntil(() => state.directoryWrites == 2);
      });
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
    },
  );

  testWidgets(
    'cancelling a pending playlist creation prevents the later add step',
    (tester) async {
      final state = _state(tester)..creation = Completer<Playlist?>();
      await _open(
        tester,
        (context) => showAddToPlaylistDialog(context, state, track: _track),
      );
      await tester.tap(find.text('新建歌单'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'New playlist');
      await tester.tap(find.text('创建'));
      await tester.pump();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      final stillVisible = find.byType(AlertDialog).evaluate().isNotEmpty;
      state.creation!.complete(_created);
      await tester.pumpAndSettle();
      expect(stillVisible, isFalse);
      expect(state.creations, 1);
      expect(state.additions, 0);
    },
  );

  testWidgets(
    'login can close while pending without a late response closing the next route',
    (tester) async {
      final state = _state(tester)..authenticated = false;
      state.authentication = Completer<AuthOutcome>();
      await _open(tester, (context) => showAppLoginDialog(context, state));
      await tester.enterText(
        find.byKey(const ValueKey('login-password-account')),
        'user@example.com',
      );
      await tester.enterText(
        find.byKey(const ValueKey('login-password-password')),
        'password',
      );
      await tester.tap(find.widgetWithText(FilledButton, '登录'));
      await tester.pump();
      await tester.tap(find.byTooltip('取消'));
      await tester.pumpAndSettle();
      final stillVisible = find
          .byKey(const ValueKey('login-password-account'))
          .evaluate()
          .isNotEmpty;
      final context = tester.element(find.text('Open'));
      unawaited(
        showDialog<void>(
          context: context,
          builder: (_) => const AlertDialog(title: Text('Next route')),
        ),
      );
      await tester.pumpAndSettle();
      state.authentication!.complete(const AuthOutcome(true));
      await tester.pumpAndSettle();
      expect(stillVisible, isFalse);
      expect(find.text('Next route'), findsOneWidget);
    },
  );

  testWidgets(
    'playlist privacy choices remain usable with a narrow screen and keyboard',
    (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      tester.view.viewInsets = const FakeViewPadding(bottom: 260);
      addTearDown(tester.view.reset);
      final state = _state(tester);
      await _open(
        tester,
        (context) => showCreateCloudPlaylistDialog(context, state),
      );
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.text('仅自己可见'));
      await tester.tap(find.text('仅自己可见'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  for (final systemBack in [false, true]) {
    final dismissal = systemBack ? 'system back' : 'close button';
    testWidgets('playlist $dismissal blocks add during the exit animation', (
      tester,
    ) async {
      final state = _state(tester)..creation = Completer<Playlist?>();
      await _open(
        tester,
        (context) => showAddToPlaylistDialog(context, state, track: _track),
        disableAnimations: false,
      );
      await tester.tap(find.text('新建歌单'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'New playlist');
      await tester.tap(find.text('创建'));
      await tester.pump();
      final dialog = tester.element(find.byType(AlertDialog));
      if (systemBack) {
        await tester.binding.handlePopRoute();
      } else {
        await tester.tap(find.text('取消'));
      }
      await tester.pump(const Duration(milliseconds: 16));
      expect(
        dialog.mounted,
        isTrue,
        reason: 'The response must arrive before route disposal.',
      );
      state.creation!.complete(_created);
      await tester.pump();
      expect(state.additions, 0);
      await tester.pumpAndSettle();
    });

    testWidgets(
      'login $dismissal protects the next route during the exit animation',
      (tester) async {
        final state = _state(tester)..authenticated = false;
        state.authentication = Completer<AuthOutcome>();
        await _open(
          tester,
          (context) => showAppLoginDialog(context, state),
          disableAnimations: false,
        );
        await tester.enterText(
          find.byKey(const ValueKey('login-password-account')),
          'user@example.com',
        );
        await tester.enterText(
          find.byKey(const ValueKey('login-password-password')),
          'password',
        );
        await tester.tap(find.widgetWithText(FilledButton, '登录'));
        await tester.pump();
        final dialog = tester.element(find.byType(Dialog));
        final navigator = Navigator.of(dialog);
        if (systemBack) {
          await tester.binding.handlePopRoute();
        } else {
          await tester.tap(find.byTooltip('取消'));
        }
        await tester.pump(const Duration(milliseconds: 16));
        expect(
          dialog.mounted,
          isTrue,
          reason: 'The response must arrive before route disposal.',
        );
        unawaited(
          showDialog<void>(
            context: navigator.context,
            builder: (_) =>
                const AlertDialog(title: Text('Next route during exit')),
          ),
        );
        await tester.pump();
        state.authentication!.complete(const AuthOutcome(true));
        await tester.pump();
        await tester.pumpAndSettle();
        expect(find.text('Next route during exit'), findsOneWidget);
      },
    );

    testWidgets(
      'QR $dismissal protects the next route during the exit animation',
      (tester) async {
        final state = _state(tester)..authenticated = false;
        state.methods = {'qr'};
        state.qrPoll = Completer<int>();
        await _open(
          tester,
          (context) => showAppLoginDialog(context, state),
          disableAnimations: false,
          settle: false,
        );
        await tester.pump(const Duration(seconds: 1));
        final dialog = tester.element(find.byType(Dialog));
        final navigator = Navigator.of(dialog);
        expect(state.qrPolls, 1);
        if (systemBack) {
          await tester.binding.handlePopRoute();
        } else {
          await tester.tap(find.byTooltip('取消'));
        }
        await tester.pump(const Duration(milliseconds: 16));
        expect(dialog.mounted, isTrue);
        unawaited(
          showDialog<void>(
            context: navigator.context,
            builder: (_) => const AlertDialog(title: Text('Next QR route')),
          ),
        );
        await tester.pump();
        state.qrPoll!.complete(803);
        await tester.pump();
        await tester.pumpAndSettle();
        expect(find.text('Next QR route'), findsOneWidget);
      },
    );
  }

  testWidgets('QR creation cannot install polling during its exit animation', (
    tester,
  ) async {
    final state = _state(tester)..authenticated = false;
    state.methods = {'qr'};
    state.qrStart = Completer<String?>();
    await _open(
      tester,
      (context) => showAppLoginDialog(context, state),
      disableAnimations: false,
      settle: false,
    );
    await tester.pump(const Duration(seconds: 1));
    final dialog = tester.element(find.byType(Dialog));
    await tester.tap(find.byTooltip('取消'));
    await tester.pump(const Duration(milliseconds: 16));
    expect(dialog.mounted, isTrue);
    state.qrStart!.complete('https://example.com/qr');
    await tester.pump();
    expect(state.qrPolls, 0);
    await tester.pumpAndSettle();
  });

  for (final qr in [false, true]) {
    testWidgets(
      '${qr ? 'QR' : 'password'} success closes only its own covered dialog',
      (tester) async {
        final state = _state(tester)..authenticated = false;
        if (qr) {
          state.methods = {'qr'};
          state.qrPoll = Completer<int>();
        } else {
          state.authentication = Completer<AuthOutcome>();
        }
        await _open(
          tester,
          (context) => showAppLoginDialog(context, state),
          settle: !qr,
        );
        if (qr) {
          await tester.pump();
        } else {
          await tester.enterText(
            find.byKey(const ValueKey('login-password-account')),
            'user@example.com',
          );
          await tester.enterText(
            find.byKey(const ValueKey('login-password-password')),
            'password',
          );
          await tester.tap(find.widgetWithText(FilledButton, '登录'));
          await tester.pump();
        }
        final dialog = tester.element(find.byType(Dialog));
        final route = ModalRoute.of(dialog)!;
        unawaited(
          showDialog<void>(
            context: Navigator.of(dialog).context,
            builder: (_) => const AlertDialog(title: Text('Covering route')),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(route.isActive, isTrue);
        expect(route.isCurrent, isFalse);
        if (qr) {
          state.qrPoll!.complete(803);
        } else {
          state.authentication!.complete(const AuthOutcome(true));
        }
        await tester.pumpAndSettle();
        expect(route.isActive, isFalse);
        expect(find.text('Covering route'), findsOneWidget);
      },
    );
  }

  testWidgets(
    'a thrown password authentication error leaves the form retryable',
    (tester) async {
      final state = _state(tester)..authenticated = false;
      state.failAuthentication = true;
      await _open(tester, (context) => showAppLoginDialog(context, state));
      await tester.enterText(
        find.byKey(const ValueKey('login-password-account')),
        'user@example.com',
      );
      await tester.enterText(
        find.byKey(const ValueKey('login-password-password')),
        'password',
      );
      await tester.tap(find.widgetWithText(FilledButton, '登录'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('登录失败，请稍后再试。'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '登录'))
            .onPressed,
        isNotNull,
      );
    },
  );

  testWidgets('authentication disables mode changes until its result arrives', (
    tester,
  ) async {
    final state = _state(tester)..authenticated = false;
    state.authentication = Completer<AuthOutcome>();
    await _open(tester, (context) => showAppLoginDialog(context, state));
    await tester.enterText(
      find.byKey(const ValueKey('login-password-account')),
      'user@example.com',
    );
    await tester.enterText(
      find.byKey(const ValueKey('login-password-password')),
      'password',
    );
    await tester.tap(find.widgetWithText(FilledButton, '登录'));
    await tester.pump();
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, '使用 Cookie 登录'))
          .onPressed,
      isNull,
    );
    state.authentication!.complete(const AuthOutcome(false));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, '使用 Cookie 登录'))
          .onPressed,
      isNotNull,
    );
  });

  testWidgets(
    'comment login is single-flight and does not like an old song after switching',
    (tester) async {
      final state = _state(tester)..authenticated = false;
      final comments = _Comments();
      final track = ValueNotifier<Track>(_track);
      addTearDown(comments.dispose);
      addTearDown(track.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppleTheme(),
          home: Scaffold(
            body: ValueListenableBuilder<Track>(
              valueListenable: track,
              builder: (_, song, _) => SongCommentsView(
                state: state,
                track: song,
                controller: comments,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final like = tester
          .widget<IconButton>(
            find.ancestor(
              of: find.byIcon(Icons.thumb_up_outlined),
              matching: find.byType(IconButton),
            ),
          )
          .onPressed!;
      like();
      like();
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsOneWidget);
      track.value = const Track(
        id: 'other-song',
        title: 'Other',
        artist: 'Artist',
        album: 'Album',
        duration: Duration(minutes: 3),
        coverSeed: 2,
      );
      await tester.pumpAndSettle();
      state.authenticated = true;
      Navigator.of(tester.element(find.byType(Dialog))).pop();
      await tester.pumpAndSettle();
      expect(comments.likedIds, isEmpty);
      expect(comments.trackId, 'other-song');
    },
  );
}
