import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/l10n/app_localizations.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/theme/apple_design.dart';
import 'package:lazer_nextgen/watch/watch_shell.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _track = Track(
  id: 'watch-locale-fixture',
  // Match real UI keys deliberately: catalogue values must remain untouched.
  title: '设置',
  artist: '播放',
  album: '音乐',
  duration: Duration(minutes: 3),
  coverSeed: 1,
);

class _State extends AppState {
  _State() : super(deviceIsWatch: true);
  @override
  Track get current => _track;
  @override
  List<Track> get queue => const [_track];
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  for (final (locale, musicLabel, queueLabel) in [
    (
      const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hans'),
      '音乐',
      '播放队列',
    ),
    (
      const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant'),
      '音樂',
      '播放佇列',
    ),
    (const Locale('en'), 'Music', 'Play queue'),
    (const Locale('ja'), '音楽', '再生キュー'),
  ]) {
    testWidgets(
      'watch translates ${locale.toLanguageTag()} but keeps song data',
      (tester) async {
        tester.view.physicalSize = const Size(240, 280);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final state = _State();
        await tester.runAsync(() => AppLocalizations.delegate.load(locale));
        await tester.pumpWidget(
          MaterialApp(
            locale: locale,
            supportedLocales: AppLocalizations.supportedLocales,
            localizationsDelegates: const [
              AppLocalizations.delegate,
              ...GlobalMaterialLocalizations.delegates,
            ],
            theme: buildAppleTheme(),
            home: WatchShell(state: state, round: false),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.byTooltip(musicLabel),
          findsOneWidget,
          reason: tester
              .widgetList<Tooltip>(find.byType(Tooltip))
              .map((tooltip) => tooltip.message)
              .join(', '),
        );
        expect(find.text(_track.title), findsOneWidget);
        expect(find.text(_track.artist), findsOneWidget);
        expect(find.byTooltip(queueLabel), findsOneWidget);
        await tester.tap(find.byTooltip(queueLabel));
        await tester.pumpAndSettle();
        expect(find.text(queueLabel), findsOneWidget);
        expect(find.text(_track.title), findsOneWidget);
        expect(find.text(_track.artist), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        state.dispose();
      },
    );
  }
}
