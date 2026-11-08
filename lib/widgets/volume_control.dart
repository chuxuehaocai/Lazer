import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../state/app_state.dart';
import '../l10n/app_localizations.dart';
import '../theme/app_palette.dart';
import 'accessible_controls.dart';

/// App-rendered volume controls shared by both desktop player surfaces.
class VolumeControl extends StatelessWidget {
  const VolumeControl({super.key, required this.state, this.onDark = false});
  final AppState state;
  final bool onDark;

  Future<void> _change(BuildContext context, Future<void> action) async {
    try {
      await action;
      final String? notice = state.takeVolumeNotice();
      if (notice != null && context.mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text(context.tr(notice))));
      }
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: TrText('音量调节失败，请重试。')));
      }
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: state,
    builder: (context, _) {
      final color = onDark ? context.colors.onPlayer : context.colors.slateDark;
      return LayoutBuilder(
        builder: (context, box) => SizedBox(
          width: math.min(168, box.maxWidth),
          child: Row(
            children: [
              AccessibleIconButton(
                tooltip: state.volume == 0 ? '取消静音' : '静音',
                color: color,
                iconSize: 22,
                constraints: const BoxConstraints(minWidth: 40, minHeight: 48),
                padding: const EdgeInsets.all(8),
                onPressed: () =>
                    unawaited(_change(context, state.toggleMute())),
                icon: Icon(
                  state.volume == 0
                      ? Icons.volume_off_rounded
                      : state.volume < .5
                      ? Icons.volume_down_rounded
                      : Icons.volume_up_rounded,
                ),
              ),
              Expanded(
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 3,
                    activeTrackColor: color,
                    inactiveTrackColor: color.withValues(alpha: .25),
                    thumbColor: context.colors.clay,
                    overlayColor: context.colors.clay.withValues(alpha: .12),
                    thumbShape: const RoundSliderThumbShape(
                      enabledThumbRadius: 5,
                    ),
                    overlayShape: const RoundSliderOverlayShape(
                      overlayRadius: 10,
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                  ),
                  child: AccessibleSlider(
                    semanticLabel: '音量',
                    semanticFormatterCallback: (value) =>
                        '${(value * 100).round()}%',
                    value: state.volume,
                    // The drag only touches the engine and the in-memory level;
                    // persisting on every pointer move wrote prefs and
                    // notified the whole shell dozens of times a second.
                    onChanged: state.previewVolume,
                    onChangeEnd: (value) =>
                        unawaited(_change(context, state.setVolume(value))),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}
