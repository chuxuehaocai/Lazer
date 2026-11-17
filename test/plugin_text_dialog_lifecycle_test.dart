import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lazer_nextgen/plugins/plugin_extensions.dart';
import 'package:lazer_nextgen/plugins/plugin_manager.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/theme/apple_design.dart';
import 'package:lazer_nextgen/ui/plugin_settings.dart';

class _Plugins extends PluginManager {
  final writes = <Object?>[];
  @override
  List<LuaPluginSetting> get pluginSettings => [
    LuaPluginSetting.fromSpec(
      pluginId: 'fixture',
      pluginName: 'Fixture',
      spec: {
        'id': 'setting',
        'type': 'text',
        'title': 'Text setting',
        'value': 'before',
        'default': 'before',
      },
    ),
  ];
  @override
  List<LuaPluginPage> get pluginPages => [
    LuaPluginPage.fromSpec(
      pluginId: 'fixture',
      pluginName: 'Fixture',
      spec: {
        'id': 'page',
        'title': 'Fixture page',
        'elements': [
          {
            'id': 'input',
            'type': 'text_field',
            'title': 'Text input',
            'value': 'before',
            'maxLines': 2,
          },
        ],
      },
    ),
  ];
  @override
  Future<void> setPluginSetting(
    String pluginId,
    String settingId,
    Object? value,
  ) async => writes.add(value);
  @override
  Future<void> invokePluginPageEvent(
    String pluginId,
    String pageId,
    String elementId,
    Object? value,
  ) async => writes.add(value);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final page in [false, true]) {
    for (final close in ['cancel', 'save', 'back']) {
      testWidgets(
        '${page ? 'page input' : 'setting'} controller lives through $close exit animation',
        (tester) async {
          final plugins = _Plugins();
          final state = AppState(pluginManager: plugins);
          addTearDown(state.dispose);
          final navigator = GlobalKey<NavigatorState>();
          await tester.pumpWidget(
            MaterialApp(
              navigatorKey: navigator,
              theme: buildAppleTheme(),
              home: Scaffold(
                body: page
                    ? LuaPluginPageView(
                        state: state,
                        pluginId: 'fixture',
                        pageId: 'page',
                      )
                    : SingleChildScrollView(
                        child: LuaPluginSettingsSection(state: state),
                      ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          await tester.tap(find.text('before'));
          await tester.pumpAndSettle();
          final controller = tester
              .widget<TextField>(find.byType(TextField))
              .controller!;
          await tester.enterText(find.byType(TextField), 'after');
          if (close == 'back') {
            navigator.currentState!.pop();
          } else {
            await tester.tap(find.text(close == 'save' ? '保存' : '取消'));
          }
          await tester.pump();
          expect(
            find.byType(TextField),
            findsOneWidget,
            reason: 'the route is still animating out',
          );
          void listener() {}
          expect(
            () => controller.addListener(listener),
            returnsNormally,
            reason: 'the mounted TextField still owns its controller',
          );
          controller.removeListener(listener);
          await tester.pumpAndSettle();
          expect(find.byType(TextField), findsNothing);
          expect(() => controller.addListener(listener), throwsFlutterError);
          expect(plugins.writes, close == 'save' ? ['after'] : isEmpty);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        },
      );
    }
  }
}
