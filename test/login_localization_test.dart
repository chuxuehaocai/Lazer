import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/gateway/local_music_gateway.dart';
import 'package:lazer_nextgen/l10n/app_localizations.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/theme/apple_design.dart';
import 'package:lazer_nextgen/ui/login.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final locale in AppLocalizations.supportedLocales) {
    testWidgets('local platform is translated in the card and menu: $locale', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(360, 780);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final strings = await tester.runAsync(
        () => AppLocalizations.delegate.load(locale),
      );
      final state = AppState(catalog: Catalog(gateway: LocalMusicGateway()));
      addTearDown(state.dispose);
      await tester.pumpWidget(
        MaterialApp(
          locale: locale,
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: const [
            AppLocalizations.delegate,
            ...GlobalMaterialLocalizations.delegates,
          ],
          theme: buildAppleTheme(),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showAppLoginDialog(context, state),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      final label = strings!.text('本地音乐');
      expect(find.text(label), findsOneWidget);
      if (locale.languageCode == 'en' || locale.languageCode == 'ja') {
        expect(find.text('本地音乐'), findsNothing);
      }
      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      expect(find.text(label), findsNWidgets(2));
      expect(tester.takeException(), isNull);
      await tester.tap(find.text(label).last);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip(strings.text('取消')));
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsNothing);
    });
  }
}
