import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/theme/apple_design.dart';
import 'package:lazer_nextgen/widgets/accessible_controls.dart';
import 'package:lazer_nextgen/widgets/player_controls_bar.dart';
import 'package:lazer_nextgen/widgets/player_seek_bar.dart';
import 'package:lazer_nextgen/widgets/volume_control.dart';
import 'package:shared_preferences/shared_preferences.dart';

Track _track(String id, {Duration duration = const Duration(minutes: 3)}) =>
    Track(
      id: id,
      title: 'Track $id',
      artist: 'Artist',
      album: 'Album',
      duration: duration,
      coverSeed: 1,
    );

class _ControlState extends AppState {
  Track? selected = _track('1');
  double fraction = .2;
  double limit = 1;
  double gain = .4;
  final seeks = <double>[];
  final committedVolumes = <double>[];
  int toggles = 0;
  int cursor = 0;
  @override
  int get queueIndex => cursor;
  @override
  Track? get current => selected;
  @override
  double get progress => fraction;
  @override
  double get seekLimitFraction => limit;
  @override
  Listenable get all => this;
  @override
  double get volume => gain;
  @override
  void seek(double value) {
    seeks.add(value);
    fraction = value.clamp(0, limit);
    notifyListeners();
  }

  @override
  void previewVolume(double value) => gain = value;
  @override
  Future<void> setVolume(double value) async {
    gain = value;
    committedVolumes.add(value);
    notifyListeners();
  }

  @override
  void togglePlay() => toggles++;
  void replace(Track? track, {double progress = .1}) {
    selected = track;
    fraction = progress;
    notifyListeners();
  }
}

Widget _host(
  Widget child, {
  double width = 400,
  TextDirection direction = TextDirection.ltr,
}) => MaterialApp(
  theme: buildAppleTheme(),
  home: Directionality(
    textDirection: direction,
    child: Scaffold(
      body: Center(
        child: SizedBox(width: width, child: child),
      ),
    ),
  ),
);

Finder get _slider => find.byType(Slider).first;
double _value(WidgetTester tester) => tester.widget<Slider>(_slider).value;

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('seek cannot commit when the pointer is canceled', (
    tester,
  ) async {
    final state = _ControlState();
    addTearDown(state.dispose);
    await tester.pumpWidget(_host(PlayerSeekBar(state: state)));
    final gesture = await tester.startGesture(tester.getCenter(_slider));
    await gesture.moveBy(const Offset(80, 0));
    await tester.pump();
    await gesture.cancel();
    await tester.pump();
    expect(state.seeks, isEmpty);
    expect(_value(tester), closeTo(state.progress, .001));
  });

  testWidgets(
    'changing tracks during a seek immediately restores the new playhead',
    (tester) async {
      final state = _ControlState();
      addTearDown(state.dispose);
      await tester.pumpWidget(_host(PlayerSeekBar(state: state)));
      final gesture = await tester.startGesture(tester.getCenter(_slider));
      await gesture.moveBy(const Offset(80, 0));
      await tester.pump();
      state.replace(_track('2'), progress: .1);
      await tester.pump();
      expect(_value(tester), closeTo(.1, .001));
      final rail = tester.widget<SliderTheme>(
        find.ancestor(of: _slider, matching: find.byType(SliderTheme)).first,
      );
      expect(rail.data.trackHeight, 4);
      await gesture.up();
      await tester.pump();
      expect(state.seeks, isEmpty);
    },
  );

  testWidgets(
    'a track with unknown duration disables pointer and keyboard seeking',
    (tester) async {
      final state = _ControlState()
        ..selected = _track('live', duration: Duration.zero);
      addTearDown(state.dispose);
      await tester.pumpWidget(_host(PlayerSeekBar(state: state)));
      expect(tester.widget<Slider>(_slider).onChanged, isNull);
      await tester.tap(_slider);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(state.seeks, isEmpty);
    },
  );

  testWidgets(
    'a constrained seek snaps the thumb to the accepted buffer boundary',
    (tester) async {
      final state = _ControlState()..limit = .4;
      addTearDown(state.dispose);
      await tester.pumpWidget(_host(PlayerSeekBar(state: state)));
      final gesture = await tester.startGesture(tester.getCenter(_slider));
      await gesture.moveBy(const Offset(120, 0));
      await tester.pump();
      await gesture.up();
      await tester.pump();
      expect(state.seeks.single, lessThanOrEqualTo(.4));
      expect(_value(tester), closeTo(.4, .001));
    },
  );

  testWidgets('a secondary mouse drag never changes an accessible slider', (
    tester,
  ) async {
    final changes = <double>[];
    await tester.pumpWidget(
      _host(AccessibleSlider(value: .2, onChanged: changes.add)),
    );
    final gesture = await tester.startGesture(
      tester.getCenter(_slider),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await gesture.moveBy(const Offset(80, 0));
    await gesture.up();
    await tester.pump();
    expect(changes, isEmpty);
  });

  testWidgets(
    'RTL dragging follows the Material track direction exactly once',
    (tester) async {
      final changes = <double>[];
      await tester.pumpWidget(
        _host(
          AccessibleSlider(value: .5, onChanged: changes.add),
          direction: TextDirection.rtl,
        ),
      );
      final gesture = await tester.startGesture(tester.getCenter(_slider));
      changes.clear();
      await gesture.moveBy(const Offset(-80, 0));
      await tester.pump();
      expect(changes, hasLength(1));
      expect(changes.single, greaterThan(.5));
      await gesture.up();
      await tester.pump();
    },
  );

  testWidgets('a canceled volume drag restores its original level', (
    tester,
  ) async {
    final state = _ControlState();
    addTearDown(state.dispose);
    await tester.pumpWidget(_host(VolumeControl(state: state)));
    final gesture = await tester.startGesture(tester.getCenter(_slider));
    await gesture.moveBy(const Offset(20, 0));
    await tester.pump();
    await gesture.cancel();
    await tester.pump();
    expect(state.volume, closeTo(.4, .001));
    expect(_value(tester), closeTo(.4, .001));
  });

  testWidgets(
    'seek arrow keys change progress while vertical keys leave the rail',
    (tester) async {
      final state = _ControlState();
      final before = FocusNode();
      final after = FocusNode();
      addTearDown(state.dispose);
      addTearDown(before.dispose);
      addTearDown(after.dispose);
      await tester.pumpWidget(
        _host(
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextButton(
                focusNode: before,
                onPressed: () {},
                child: const Text('Before'),
              ),
              PlayerSeekBar(state: state),
              TextButton(
                focusNode: after,
                onPressed: () {},
                child: const Text('After'),
              ),
            ],
          ),
        ),
      );
      before.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(state.seeks, [.22]);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(after.hasFocus, isTrue);
      expect(state.seeks, [.22]);
    },
  );

  testWidgets('same song at a new queue index cancels the old drag', (
    tester,
  ) async {
    final state = _ControlState();
    addTearDown(state.dispose);
    await tester.pumpWidget(_host(PlayerSeekBar(state: state)));
    final gesture = await tester.startGesture(tester.getCenter(_slider));
    await gesture.moveBy(const Offset(80, 0));
    await tester.pump();
    state.cursor++;
    state.replace(_track('1'), progress: .05);
    await tester.pump();
    expect(_value(tester), closeTo(.05, .001));
    await gesture.up();
    await tester.pump();
    expect(state.seeks, isEmpty);
  });

  testWidgets(
    'losing app focus cancels a seek without committing its preview',
    (tester) async {
      final state = _ControlState();
      addTearDown(state.dispose);
      await tester.pumpWidget(_host(PlayerSeekBar(state: state)));
      final gesture = await tester.startGesture(tester.getCenter(_slider));
      await gesture.moveBy(const Offset(80, 0));
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      await gesture.up();
      await tester.pump();
      expect(state.seeks, isEmpty);
      expect(_value(tester), closeTo(.2, .001));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
    },
  );

  testWidgets(
    'disabling a slider during its gesture cancels its pending commit',
    (tester) async {
      var enabled = true;
      final committed = <double>[];
      late StateSetter rebuild;
      await tester.pumpWidget(
        _host(
          StatefulBuilder(
            builder: (context, setState) {
              rebuild = setState;
              return AccessibleSlider(
                value: .3,
                onChanged: enabled ? (_) {} : null,
                onChangeEnd: committed.add,
              );
            },
          ),
        ),
      );
      final gesture = await tester.startGesture(tester.getCenter(_slider));
      await gesture.moveBy(const Offset(80, 0));
      await tester.pump();
      rebuild(() => enabled = false);
      await tester.pump();
      await gesture.up();
      await tester.pump();
      expect(committed, isEmpty);
      expect(_value(tester), closeTo(.3, .001));
    },
  );

  testWidgets('empty transport controls cannot activate a missing track', (
    tester,
  ) async {
    final state = _ControlState()..selected = null;
    addTearDown(state.dispose);
    await tester.pumpWidget(
      _host(PlayerControlsBar(state: state, onExpand: () {}), width: 800),
    );
    final play = find.widgetWithIcon(IconButton, Icons.play_arrow_rounded);
    expect(tester.widget<IconButton>(play).onPressed, isNull);
    await tester.tap(play);
    await tester.pump();
    expect(state.toggles, 0);
  });

  testWidgets('the player controls remain usable at a 320 pixel width', (
    tester,
  ) async {
    final state = _ControlState();
    addTearDown(state.dispose);
    await tester.pumpWidget(
      _host(PlayerControlsBar(state: state, onExpand: () {}), width: 320),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
