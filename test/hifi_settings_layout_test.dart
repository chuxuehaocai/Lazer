import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/audio/hifi_controller.dart';
import 'package:lazer_nextgen/audio/native/engine_metrics.dart';
import 'package:lazer_nextgen/audio/native/lazer_audio_devices.dart';
import 'package:lazer_nextgen/audio/native/lazer_audio_engine.dart';
import 'package:lazer_nextgen/audio/native/lazer_audio_worker.dart';
import 'package:lazer_nextgen/l10n/app_localizations.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/state/hifi_settings.dart';
import 'package:lazer_nextgen/theme/apple_design.dart';
import 'package:lazer_nextgen/widgets/hifi_settings_section.dart';
import 'package:lazer_nextgen/widgets/settings_choice.dart';
import 'package:lazer_nextgen/widgets/settings_row.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _NativeEngine extends Fake implements NativeAudioEngine {
  final List<List<int>> orders = <List<int>>[];

  @override
  LazerStreamInfo? get streamInfo => null;

  @override
  LazerEngineMetrics? readMetrics() => null;

  @override
  Future<void> setDeviceSettings(LazerDeviceSettings settings) async {}

  @override
  Future<void> setEqualizer({
    double preampDb = 0,
    bool limiterEnabled = false,
    double limiterThresholdDb = -1,
    List<LazerEqBandSettings> bands = const <LazerEqBandSettings>[],
    LazerCrossfeedSettings crossfeed = const LazerCrossfeedSettings(),
    List<int> stageOrder = const <int>[],
  }) async => orders.add(List<int>.of(stageOrder));
}

class _Hifi extends HifiController {
  _Hifi(_NativeEngine engine)
    : super(_settings, engine: engine, persist: (_) async {});

  static const _settings = HifiSettings(
    crossfeed: HifiCrossfeedState(enabled: true),
    equalizer: HifiEqualizerState(enabled: true),
  );

  @override
  bool get supportsDevices => true;

  @override
  bool get supportsDoP => true;

  @override
  bool get supportsNativeDsd => true;

  @override
  List<LazerOutputDevice> get devices => const <LazerOutputDevice>[
    LazerOutputDevice(
      token: 'usb-dac',
      identityKey: 'usb-dac',
      displayName: 'USB Audio DAC / Headphones (High Definition Audio Device)',
      isDefault: true,
    ),
  ];

  @override
  Future<void> refreshDevices() async {}

  @override
  Future<void> refreshEndpointVolume() async {}
}

AppLocalizations _strings(String tag) => AppLocalizations(
  switch (tag) {
    'zh_Hans' => const Locale.fromSubtags(
      languageCode: 'zh',
      scriptCode: 'Hans',
    ),
    'zh_Hant' => const Locale.fromSubtags(
      languageCode: 'zh',
      scriptCode: 'Hant',
    ),
    _ => Locale(tag),
  },
  (jsonDecode(File('assets/l10n/$tag.json').readAsStringSync())
          as Map<String, dynamic>)
      .cast<String, String>(),
);

Future<void> _choose<T>(WidgetTester tester, String key, T value) async {
  final control = find.byKey(ValueKey(key));
  await tester.ensureVisible(control);
  await tester.pumpAndSettle();
  await tester.tap(control);
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull, reason: 'opening $key');
  final options = find.byWidgetPredicate(
    (widget) => widget is DropdownMenuItem<T> && widget.value == value,
  );
  expect(options, isNot(findsNothing), reason: '$key option $value');
  final item = options.last;
  await tester.ensureVisible(item);
  await tester.pumpAndSettle();
  final label = find
      .descendant(of: item, matching: find.byType(RichText))
      .hitTestable();
  // Menu-item alignment can leave empty space at its center. Hit the actual
  // label so this exercises the overlay's InkWell for short choices as well.
  expect(label, findsOneWidget, reason: '$key option $value is reachable');
  for (final element
      in find
          .descendant(of: item, matching: find.byType(RichText))
          .evaluate()) {
    final paragraph = element.renderObject! as RenderParagraph;
    expect(paragraph.didExceedMaxLines, isFalse);
  }
  await tester.tap(label);
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull, reason: 'selecting $key: $value');
}

Future<void> _mount(
  WidgetTester tester, {
  required AppState state,
  required AppLocalizations strings,
  required double width,
  required double textScale,
  bool equalizer = false,
  Key? boundaryKey,
}) => tester.pumpWidget(
  MaterialApp(
    theme: buildAppleTheme(brightness: Brightness.dark),
    locale: strings.locale,
    supportedLocales: AppLocalizations.supportedLocales,
    localizationsDelegates: <LocalizationsDelegate<dynamic>>[
      _StringsDelegate(strings),
      ...GlobalMaterialLocalizations.delegates,
    ],
    builder: (context, child) => RepaintBoundary(
      key: boundaryKey,
      child: MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
    ),
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: width,
          child: equalizer
              ? EqualizerSettingsView(state: state)
              : SingleChildScrollView(child: HifiSettingsSection(state: state)),
        ),
      ),
    ),
  ),
);

class _StringsDelegate extends LocalizationsDelegate<AppLocalizations> {
  const _StringsDelegate(this.strings);
  final AppLocalizations strings;

  @override
  bool isSupported(Locale locale) => true;

  @override
  Future<AppLocalizations> load(Locale locale) async => strings;

  @override
  bool shouldReload(_StringsDelegate old) => old.strings != strings;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    final text = FontLoader('MiSans');
    for (final weight in <String>['Regular', 'Medium', 'Semibold', 'Bold']) {
      text.addFont(rootBundle.load('assets/fonts/MiSans-$weight.ttf'));
    }
    await text.load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  for (final tag in <String>['zh_Hans', 'zh_Hant', 'en', 'ja']) {
    for (final width in <double>[320, 390, 600]) {
      for (final textScale in <double>[1, 1.5]) {
        testWidgets(
          'HiFi choices fit $tag at pane $width and text scale $textScale',
          (tester) async {
            tester.view.physicalSize = const Size(1280, 900);
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.reset);
            final native = _NativeEngine();
            final hifi = _Hifi(native);
            final state = AppState(hifi: hifi, hifiSettings: hifi.settings);
            addTearDown(state.dispose);
            addTearDown(hifi.dispose);
            await _mount(
              tester,
              state: state,
              strings: _strings(tag),
              width: width,
              textScale: textScale,
            );
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);

            for (final preset in <List<int>>[
              kDspChainPresets.values.elementAt(1),
              kDspChainPresets.values.elementAt(2),
              kDspChainPresets.values.first,
            ]) {
              await _choose(
                tester,
                'hifi-dsp-order',
                encodeDspStageOrder(preset),
              );
              expect(state.hifiSettings.dspStageOrder, preset);
              expect(hifi.settings.dspStageOrder, preset);
              expect(native.orders.last, preset);
              final choice = tester.widget<SettingsChoice<String>>(
                find.byKey(const ValueKey('hifi-dsp-order')),
              );
              final item = choice.items.firstWhere(
                (item) => item.value == encodeDspStageOrder(preset),
              );
              expect(item.child, isA<TrText>());
              expect((item.child as TrText).maxLines, isNull);
              expect((item.child as TrText).overflow, isNull);
            }

            await _choose(tester, 'audio-engine-choice', false);
            await _choose<String?>(tester, 'hifi-device', 'usb-dac');
            await _choose(
              tester,
              'hifi-dsd-mode',
              HifiDsdOutputMode.requireNative,
            );
            await _choose(
              tester,
              'hifi-dsd-rate-policy',
              HifiDsdRatePolicy.downrate,
            );
            await _choose(
              tester,
              'hifi-normalization',
              HifiVolumeNormalization.loudnorm,
            );
            await _choose(tester, 'hifi-buffer', HifiBufferSize.values.last);
            await _choose(
              tester,
              'hifi-crossfeed-algorithm',
              HifiCrossfeedAlgorithm.meier,
            );
            for (final element in find.byType(Switch).evaluate()) {
              expect(
                tester.getSize(find.byWidget(element.widget)).width,
                lessThan(100),
                reason: 'a switch keeps its natural width',
              );
            }

            await _mount(
              tester,
              state: state,
              strings: _strings(tag),
              width: width,
              textScale: textScale,
              equalizer: true,
            );
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
            await _choose(tester, 'hifi-eq-preset', 'rock');
            expect(state.hifiSettings.equalizer.matchingPresetId, 'rock');
          },
        );
      }
    }
  }

  testWidgets('DSP row can be captured without overflowing at large text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final native = _NativeEngine();
    final hifi = _Hifi(native);
    final state = AppState(hifi: hifi, hifiSettings: hifi.settings);
    addTearDown(state.dispose);
    addTearDown(hifi.dispose);
    const captureKey = ValueKey('hifi-layout-capture');
    for (final tag in <String>['zh_Hans', 'en']) {
      await _mount(
        tester,
        state: state,
        strings: _strings(tag),
        width: 390,
        textScale: 1.5,
        boundaryKey: captureKey,
      );
      await tester.pumpAndSettle();
      final dsp = find.byKey(const ValueKey('hifi-dsp-order'));
      final row = find.ancestor(
        of: dsp,
        matching: find.byWidgetPredicate((widget) => widget is SettingsRow),
      );
      await tester.ensureVisible(row);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(tester.getSize(row).height, greaterThan(100));
      await _capture(tester, captureKey, 'hifi-settings-$tag-large-text');
      await tester.tap(dsp);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await _capture(tester, captureKey, 'hifi-menu-$tag-large-text');
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
    }
  });
}

Future<void> _capture(WidgetTester tester, Key key, String name) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(key));
  await tester.runAsync(() async {
    final image = await boundary.toImage();
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    final capture = File('diag/settings/$name.png');
    await capture.parent.create(recursive: true);
    await capture.writeAsBytes(bytes!.buffer.asUint8List());
  });
}
