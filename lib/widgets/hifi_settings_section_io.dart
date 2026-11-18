// The HiFi output section of the Settings page.
//
// i18n:data — every CJK literal below is an interface key rendered through
// `context.tr` (directly or by SettingsRow).
//
// The readout at the end shows the format the engine actually negotiated rather
// than what was requested.
library;

import 'build_safe_state.dart';
import 'spring_buttons.dart';

import 'dart:async';

import 'package:flutter/material.dart';

import '../audio/hifi_controller.dart';
import '../audio/native/engine_metrics.dart';
import '../audio/native/lazer_audio_devices.dart';
import '../audio/native/lazer_audio_engine.dart';
import '../audio/native/output_path_state.dart';
import '../l10n/app_localizations.dart';
import '../state/app_state.dart';
import '../state/hifi_settings.dart';
import '../theme/apple_design.dart';
import '../widgets/accessible_controls.dart';
import '../widgets/apple_ui.dart';
import 'audio_engine_settings.dart';
import 'settings_detail.dart';
import 'settings_choice.dart';
import 'settings_row.dart';
import 'volume_control.dart';

/// Renders the 高保真播放 group: engine status, output device, exclusive/bit-perfect
/// policy, DSD mode, buffer, equaliser and the live format readout.
class HifiSettingsSection extends StatefulWidget {
  const HifiSettingsSection({super.key, required this.state});

  final AppState state;

  @override
  State<HifiSettingsSection> createState() => _HifiSettingsSectionState();
}

class _HifiSettingsSectionState extends State<HifiSettingsSection>
    with BuildSafeState<HifiSettingsSection> {
  HifiController? _controller;

  @override
  void initState() {
    super.initState();
    _bindController();
  }

  @override
  void didUpdateWidget(covariant HifiSettingsSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    _bindController();
  }

  void _bindController() {
    final controller = widget.state.hifi;
    if (identical(controller, _controller)) return;
    _controller?.removeListener(_changed);
    _controller = controller;
    if (controller == null) return;
    controller.addListener(_changed);
    // Other retained sections can share this controller. Start discovery once
    // this section is mounted, after their build scopes have also completed.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && identical(_controller, controller)) {
        unawaited(controller.refreshDevices());
      }
    });
  }

  @override
  void dispose() {
    _controller?.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _update(HifiSettings next) => widget.state.setHifiSettings(next);

  @override
  Widget build(BuildContext context) {
    final HifiController? hifi = _controller;
    if (hifi == null) {
      return Column(
        children: [
          const _SectionLabel('高保真播放'),
          AudioEngineSettings(state: widget.state),
          EqualizerSettingsEntry(state: widget.state),
        ],
      );
    }
    final HifiSettings settings = widget.state.hifiSettings;
    final bool native = hifi.nativeAvailable;
    final String dspOrder = settings.dspStageOrder
        .map(dspStageLabel)
        .map(context.tr)
        .join(' → ');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const _SectionLabel('高保真播放'),
        AudioEngineSettings(state: widget.state),
        EqualizerSettingsEntry(state: widget.state),
        AppleGroupedCard(
          margin: EdgeInsets.zero,
          child: Column(
            children: <Widget>[
              _SettingRow(
                label: '播放引擎',
                subtitle: _engineSubtitle(hifi, native),
                trailing: Text(
                  context.tr(native ? '原生引擎' : '兼容引擎'),
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: native
                        ? AppleSemanticColors.of(context).label
                        : AppleSemanticColors.of(context).secondaryLabel,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (!native)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  child: Text(
                    context.tr(hifi.status.nativeReason ?? '原生音频引擎不可用'),
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: AppleSemanticColors.of(context).secondaryLabel,
                    ),
                  ),
                ),
              if (native && hifi.lastApplyError != null)
                _WarningRow('音频设置未应用：${hifi.lastApplyError}'),
              if (native && hifi.usesIosSystemRoute) ...<Widget>[
                const _SettingRow(
                  label: '输出设备',
                  subtitle: 'iOS 管理输出路由；连接 USB DAC 或在控制中心选择耳机、AirPlay 设备',
                  trailing: TrText('系统默认输出设备'),
                ),
                const _SettingRow(
                  label: '独占 / 严格 PCM / DoP',
                  subtitle: 'iOS 不支持独占、严格 PCM 或 DoP，使用系统共享输出',
                  trailing: TrText('不支持'),
                ),
                _SettingRow(
                  label: '音量',
                  subtitle: '应用音量；系统音量请在控制中心调整',
                  expandControl: true,
                  trailing: VolumeControl(state: widget.state),
                ),
              ],
              if (native && hifi.supportsDevices)
                _SettingRow(
                  label: '输出设备',
                  subtitle: _deviceSubtitle(hifi, settings),
                  expandControl: true,
                  trailing: _DevicePicker(
                    hifi: hifi,
                    settings: settings,
                    onChanged: (String? token, String? name) => _update(
                      token == null
                          ? settings.copyWith(
                              clearOutput: true,
                              exclusiveMode: hifi.usesAndroidUsbDevices
                                  ? false
                                  : settings.exclusiveMode,
                              bitPerfect: hifi.usesAndroidUsbDevices
                                  ? false
                                  : settings.bitPerfect,
                            )
                          : settings.copyWith(
                              outputToken: token,
                              outputName: name,
                              exclusiveMode: hifi.usesAndroidUsbDevices
                                  ? true
                                  : settings.exclusiveMode,
                            ),
                    ),
                  ),
                ),
              if (native && !hifi.usesIosSystemRoute)
                _SwitchRow(
                  label: '独占输出',
                  subtitle: hifi.supportsExclusiveMode
                      ? '使用设备独占输出'
                      : '该平台不支持独占输出',
                  value: settings.exclusiveMode,
                  enabled: hifi.supportsExclusiveMode,
                  onChanged: (bool value) => _update(
                    settings.copyWith(
                      exclusiveMode: value,
                      // Bit-perfect is an exclusive-mode promise.
                      bitPerfect: value ? settings.bitPerfect : false,
                    ),
                  ),
                ),
              if (native && !hifi.usesIosSystemRoute)
                _SwitchRow(
                  label: 'Bit-perfect 输出',
                  subtitle: _bitPerfectSubtitle(hifi, settings),
                  value: settings.bitPerfect,
                  enabled: hifi.supportsBitPerfect,
                  onChanged: (bool value) => _update(
                    settings.copyWith(
                      bitPerfect: value,
                      exclusiveMode: value ? true : settings.exclusiveMode,
                    ),
                  ),
                ),
              // The chain is explicit now (ABI v27), so the order is a setting rather
              // than something the engine decides: it is part of the audio result, and
              // the summary states what will actually be applied.
              if (native)
                _SettingRow(
                  label: 'DSP 链顺序',
                  subtitle: '当前：$dspOrder',
                  expandControl: true,
                  trailing: SettingsChoice<String>(
                    key: const ValueKey('hifi-dsp-order'),
                    value: _dspOrderChoice(settings),
                    items: <DropdownMenuItem<String>>[
                      for (final MapEntry<String, List<int>> preset
                          in kDspChainPresets.entries)
                        DropdownMenuItem<String>(
                          value: encodeDspStageOrder(preset.value),
                          child: TrText(preset.key),
                        ),
                      // A persisted order that matches no preset (hand-edited, or a
                      // future preset that was removed) still has to be selectable,
                      // otherwise the dropdown would assert on an unknown value.
                      if (!kDspChainPresets.values
                          .map(encodeDspStageOrder)
                          .contains(_dspOrderChoice(settings)))
                        DropdownMenuItem<String>(
                          value: _dspOrderChoice(settings),
                          child: const TrText('自定义'),
                        ),
                    ],
                    onChanged: (String? value) {
                      if (value != null) {
                        unawaited(
                          _update(
                            settings.copyWith(
                              dspStageOrder: decodeDspStageOrder(value),
                            ),
                          ),
                        );
                      }
                    },
                  ),
                ),
              if (native && hifi.supportsDoP)
                _SettingRow(
                  label: 'DSD 输出',
                  subtitle: _dsdSubtitle(hifi, settings),
                  expandControl: true,
                  trailing: SettingsChoice<HifiDsdOutputMode>(
                    key: const ValueKey('hifi-dsd-mode'),
                    value: settings.dsdOutputMode,
                    items: <DropdownMenuItem<HifiDsdOutputMode>>[
                      for (final HifiDsdOutputMode mode
                          in HifiDsdOutputMode.values)
                        if ((mode != HifiDsdOutputMode.requireNative ||
                            hifi.supportsNativeDsd))
                          DropdownMenuItem<HifiDsdOutputMode>(
                            value: mode,
                            child: TrText(mode.label),
                          ),
                    ],
                    onChanged: (HifiDsdOutputMode? value) {
                      if (value != null) {
                        unawaited(
                          _update(settings.copyWith(dsdOutputMode: value)),
                        );
                      }
                    },
                  ),
                ),
              if (native && hifi.supportsDoP && !hifi.usesIosSystemRoute)
                _SettingRow(
                  label: 'DSD 倍率策略',
                  subtitle: _dsdRatePolicySubtitle(settings),
                  expandControl: true,
                  trailing: SettingsChoice<HifiDsdRatePolicy>(
                    key: const ValueKey('hifi-dsd-rate-policy'),
                    value: settings.dsdRatePolicy,
                    items: <DropdownMenuItem<HifiDsdRatePolicy>>[
                      for (final HifiDsdRatePolicy policy
                          in HifiDsdRatePolicy.values)
                        DropdownMenuItem<HifiDsdRatePolicy>(
                          value: policy,
                          child: TrText(policy.label),
                        ),
                    ],
                    onChanged: (HifiDsdRatePolicy? value) {
                      if (value != null) {
                        unawaited(
                          _update(settings.copyWith(dsdRatePolicy: value)),
                        );
                      }
                    },
                  ),
                ),
              if (native)
                _SettingRow(
                  label: '响度归一',
                  subtitle: _normalizationSubtitle(settings),
                  expandControl: true,
                  trailing: SettingsChoice<HifiVolumeNormalization>(
                    key: const ValueKey('hifi-normalization'),
                    value: settings.volumeNormalization,
                    items: <DropdownMenuItem<HifiVolumeNormalization>>[
                      for (final HifiVolumeNormalization mode
                          in HifiVolumeNormalization.values)
                        DropdownMenuItem<HifiVolumeNormalization>(
                          value: mode,
                          child: TrText(mode.label),
                        ),
                    ],
                    onChanged: (HifiVolumeNormalization? value) {
                      if (value != null) {
                        unawaited(
                          _update(
                            settings.copyWith(volumeNormalization: value),
                          ),
                        );
                      }
                    },
                  ),
                ),
              if (native)
                _SettingRow(
                  label: '输出缓冲',
                  subtitle: '更小的缓冲换更低延迟，更大的缓冲更容易在负载下不断流',
                  expandControl: true,
                  trailing: SettingsChoice<HifiBufferSize>(
                    key: const ValueKey('hifi-buffer'),
                    value: settings.buffer,
                    items: <DropdownMenuItem<HifiBufferSize>>[
                      for (final HifiBufferSize size in HifiBufferSize.values)
                        DropdownMenuItem<HifiBufferSize>(
                          value: size,
                          child: Text(
                            '${context.tr(size.label)} · ${size.millis}ms',
                          ),
                        ),
                    ],
                    onChanged: (HifiBufferSize? value) {
                      if (value != null) {
                        unawaited(_update(settings.copyWith(buffer: value)));
                      }
                    },
                  ),
                ),
            ],
          ),
        ),
        if (native) ...<Widget>[
          const _SectionLabel('耳机串扰'),
          AppleGroupedCard(
            margin: EdgeInsets.zero,
            child: Column(
              children: <Widget>[
                _SwitchRow(
                  label: '启用 crossfeed',
                  subtitle: settings.directOutputRequested
                      ? '直通输出已启用，crossfeed 暂不可用'
                      : '把每声道延时、低通后混入对侧，减轻耳机里"声音在脑中"的感觉',
                  value: settings.crossfeedActive,
                  enabled: !settings.directOutputRequested,
                  onChanged: (bool value) => _update(
                    settings.copyWith(
                      crossfeed: settings.crossfeed.copyWith(enabled: value),
                    ),
                  ),
                ),
                if (settings.crossfeedActive) ...<Widget>[
                  _SettingRow(
                    label: '强度',
                    subtitle: '${(settings.crossfeed.strength * 100).round()}%',
                    trailing: SizedBox(
                      width: 200,
                      child: SemanticsPortal(
                        child: Slider(
                          key: const ValueKey('hifi-crossfeed-strength'),
                          value: settings.crossfeed.strength,
                          divisions: 20,
                          onChanged: (double value) => _update(
                            settings.copyWith(
                              crossfeed: settings.crossfeed.copyWith(
                                strength: value,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  _SettingRow(
                    label: '算法',
                    subtitle:
                        '延时 ${settings.crossfeed.effectiveDelayMs.toStringAsFixed(2)} ms · 截止 ${settings.crossfeed.effectiveCutoffHz.round()} Hz',
                    expandControl: true,
                    trailing: SettingsChoice<HifiCrossfeedAlgorithm>(
                      key: const ValueKey('hifi-crossfeed-algorithm'),
                      value: settings.crossfeed.algorithm,
                      items: <DropdownMenuItem<HifiCrossfeedAlgorithm>>[
                        for (final HifiCrossfeedAlgorithm algorithm
                            in HifiCrossfeedAlgorithm.values)
                          DropdownMenuItem<HifiCrossfeedAlgorithm>(
                            value: algorithm,
                            child: TrText(algorithm.label),
                          ),
                      ],
                      onChanged: (HifiCrossfeedAlgorithm? value) {
                        if (value != null) {
                          unawaited(
                            _update(
                              settings.copyWith(
                                crossfeed: settings.crossfeed.copyWith(
                                  algorithm: value,
                                ),
                              ),
                            ),
                          );
                        }
                      },
                    ),
                  ),
                ],
              ],
            ),
          ),
          _FormatCard(hifi: hifi),
        ],
      ],
    );
  }

  String _engineSubtitle(HifiController hifi, bool native) {
    if (!native) return '当前使用 just_audio / media_kit，没有独占与 DSP 能力';
    final LazerStreamInfo? info = hifi.streamInfo;
    if (info == null) return 'FFmpeg 解码 + 平台直出，当前没有打开的音源';
    return info.summary;
  }

  String _deviceSubtitle(HifiController hifi, HifiSettings settings) {
    if (hifi.usesAndroidUsbDevices) {
      if (settings.outputToken == null) {
        return '系统音频输出；选择 USB DAC 可绕过系统混音与重采样';
      }
      return hifi.selectedDevice == null
          ? 'USB DAC 未连接；连接后可使用直通输出'
          : 'USB DAC 直通；首次使用需要授权';
    }
    if (settings.outputToken == null) return '系统默认输出设备';
    final LazerOutputDevice? device = hifi.selectedDevice;
    if (device == null) {
      return settings.outputName == null
          ? '已保存的设备当前不可用'
          : context
                .tr('{name}（当前不可用）')
                .replaceAll('{name}', settings.outputName!);
    }
    final StringBuffer buffer = StringBuffer(device.displayName);
    if (!device.isActive) buffer.write(context.tr('（未激活）'));
    if (device.hardwareVolumeFlags != null) {
      buffer.write(
        device.hasHardwareVolume
            ? context.tr(' · 硬件音量')
            : context.tr(' · 无硬件音量'),
      );
    }
    return buffer.toString();
  }

  String _bitPerfectSubtitle(HifiController hifi, HifiSettings settings) {
    if (settings.bitPerfect) {
      return '保持源格式，旁路软件音量和 DSP';
    }
    return '尽量保持源格式输出';
  }

  String _dsdSubtitle(HifiController hifi, HifiSettings settings) {
    switch (settings.dsdOutputMode) {
      case HifiDsdOutputMode.auto:
        return '自动选择可用的 DSD 输出方式';
      case HifiDsdOutputMode.convertToPcm:
        return '转换为 PCM 输出';
      case HifiDsdOutputMode.requireDoP:
        return '使用 DoP 载波输出 DSD';
      case HifiDsdOutputMode.requireNative:
        return hifi.supportsNativeDsd ? '使用 ALSA 原生 DSD 格式' : '当前平台不支持原生 DSD';
    }
  }

  String _dsdRatePolicySubtitle(HifiSettings settings) {
    final HifiDsdRatePolicy policy = settings.dsdRatePolicy;
    final String detail = policy.detail;
    return policy.isSupported ? detail : '$detail（本引擎未实现，选择后仍按 PCM 回退行为播放）';
  }

  String _normalizationSubtitle(HifiSettings settings) {
    final HifiVolumeNormalization mode = settings.volumeNormalization;
    final String detail = mode.detail;
    return mode.isSupported ? detail : '$detail（需要测量阶段，本引擎未实现）';
  }
}

/// One row in the grouped card, matching the settings page's own rows.
class _SettingRow extends SettingsRow {
  const _SettingRow({
    required super.label,
    required super.subtitle,
    required super.trailing,
    super.expandControl,
  }) : super(controlFlex: 6);
}

class _SwitchRow extends StatelessWidget {
  const _SwitchRow({
    required this.label,
    required this.subtitle,
    required this.value,
    required this.onChanged,
    this.enabled = true,
  });

  final String label;
  final String subtitle;
  final bool value;
  final bool enabled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => _SettingRow(
    label: label,
    subtitle: subtitle,
    trailing: Switch(value: value, onChanged: enabled ? onChanged : null),
  );
}

class _WarningRow extends StatelessWidget {
  const _WarningRow(this.message);

  final String message;

  @override
  Widget build(BuildContext context) {
    final AppleSemanticColors apple = AppleSemanticColors.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(Icons.info_outline, size: 16, color: apple.secondaryLabel),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              context.tr(message),
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: apple.secondaryLabel),
            ),
          ),
        ],
      ),
    );
  }
}

/// Device dropdown; the first entry is "system default".
class _DevicePicker extends StatelessWidget {
  const _DevicePicker({
    required this.hifi,
    required this.settings,
    required this.onChanged,
  });

  final HifiController hifi;
  final HifiSettings settings;
  final void Function(String? token, String? name) onChanged;

  @override
  Widget build(BuildContext context) {
    final List<LazerOutputDevice> devices = hifi.devices;
    final String? selected = settings.outputToken;
    final bool selectionKnown =
        selected == null ||
        devices.any((LazerOutputDevice device) => device.token == selected);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (hifi.busy)
          const Padding(
            padding: EdgeInsets.only(right: 8),
            child: SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        Flexible(
          child: SettingsChoice<String?>(
            key: const ValueKey('hifi-device'),
            value: selected,
            items: <DropdownMenuItem<String?>>[
              if (!selectionKnown)
                DropdownMenuItem<String?>(
                  value: selected,
                  child: Text(settings.outputName ?? selected),
                ),
              const DropdownMenuItem<String?>(
                value: null,
                child: TrText('系统默认'),
              ),
              for (final LazerOutputDevice device in devices)
                DropdownMenuItem<String?>(
                  value: device.token,
                  child: Text(
                    '${device.isActive ? '' : '（未激活）'}'
                    '${device.displayName}'
                    '${device.isDefault ? ' · 默认' : ''}',
                  ),
                ),
            ],
            onChanged: (String? token) {
              final LazerOutputDevice? device = devices
                  .where(
                    (LazerOutputDevice candidate) => candidate.token == token,
                  )
                  .firstOrNull;
              onChanged(token, device?.displayName);
            },
          ),
        ),
        Semantics(
          label: context.tr('刷新设备列表'),
          button: true,
          enabled: !hifi.busy,
          child: IconButton(
            onPressed: hifi.busy
                ? null
                : () => unawaited(hifi.refreshDevices()),
            icon: const Icon(Icons.refresh, size: 18),
          ),
        ),
      ],
    );
  }
}

class EqualizerSettingsEntry extends StatelessWidget {
  const EqualizerSettingsEntry({super.key, required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) => AppleGroupedCard(
    margin: const EdgeInsets.only(bottom: SettingsSpacing.groupGap),
    child: AppleListTile(
      padding: SettingsSpacing.rowPadding,
      minHeight: SettingsSpacing.rowMinHeight,
      key: const ValueKey('open-equalizer-settings'),
      title: context.tr('均衡器'),
      subtitle: context.tr(state.hifiSettings.eqActive ? '已启用' : '已关闭'),
      trailing: const Icon(Icons.chevron_right_rounded),
      onTap: () => SettingsDetailHost.open(
        context,
        page: (_) => EqualizerSettingsPage(state: state),
        view: (_) => EqualizerSettingsView(state: state),
      ),
    ),
  );
}

class EqualizerSettingsPage extends StatelessWidget {
  const EqualizerSettingsPage({super.key, required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) => EqualizerSettingsView(state: state);
}

class EqualizerSettingsView extends StatelessWidget {
  const EqualizerSettingsView({super.key, required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: state,
    builder: (context, _) => SettingsDetailScaffold(
      title: '均衡器',
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: _EqualizerControls(state: state),
          ),
        ),
      ),
    ),
  );
}

class _EqualizerControls extends StatelessWidget {
  const _EqualizerControls({required this.state});
  final AppState state;
  Future<void> _update(HifiSettings next) => state.setHifiSettings(next);

  @override
  Widget build(BuildContext context) {
    final settings = state.hifiSettings;
    return Column(
      children: [
        if (state.hifi?.nativeAvailable != true)
          const Padding(
            padding: EdgeInsets.only(bottom: 16),
            child: TrText('当前引擎不支持均衡器，切换到 Audio Engine 并重启后生效。'),
          ),
        AppleGroupedCard(
          margin: EdgeInsets.zero,
          child: Column(
            children: <Widget>[
              _SwitchRow(
                label: '启用均衡器',
                subtitle: settings.directOutputRequested
                    ? '直通输出已启用，均衡器暂不可用'
                    : '均衡器和限幅器参与 DSP',
                value: settings.eqActive,
                enabled: !settings.directOutputRequested,
                onChanged: (bool value) => _update(
                  settings.copyWith(
                    equalizer: settings.equalizer.copyWith(enabled: value),
                  ),
                ),
              ),
              if (settings.eqActive) ...<Widget>[
                _SettingRow(
                  label: '预设',
                  subtitle: settings.equalizer.matchingPresetId == null
                      ? '自定义曲线'
                      : '选择预设会自动启用均衡器',
                  expandControl: true,
                  trailing: SettingsChoice<String>(
                    key: const ValueKey('hifi-eq-preset'),
                    value: settings.equalizer.matchingPresetId,
                    hint: const TrText('自定义'),
                    items: <DropdownMenuItem<String>>[
                      for (final HifiEqPreset preset in hifiEqPresets)
                        DropdownMenuItem<String>(
                          value: preset.id,
                          child: TrText(preset.label),
                        ),
                    ],
                    onChanged: (String? id) {
                      if (id == null) return;
                      final HifiEqPreset preset = hifiEqPresets.firstWhere(
                        (HifiEqPreset candidate) => candidate.id == id,
                      );
                      unawaited(
                        _update(
                          settings.copyWith(
                            equalizer: settings.equalizer
                                .withPreset(preset)
                                .copyWith(enabled: true),
                          ),
                        ),
                      );
                    },
                  ),
                ),
                _SettingRow(
                  label: '前级',
                  subtitle:
                      '${settings.equalizer.preampDb.toStringAsFixed(1)} dB',
                  trailing: SizedBox(
                    width: 200,
                    child: SemanticsPortal(
                      child: Slider(
                        value: settings.equalizer.preampDb,
                        min: kMinHifiPreampDb,
                        max: kMaxHifiPreampDb,
                        onChanged: (double value) => _update(
                          settings.copyWith(
                            equalizer: settings.equalizer.copyWith(
                              preampDb: clampHifiPreampDb(_tenthDb(value)),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                _SwitchRow(
                  label: '限幅器',
                  subtitle: '样本峰值上限 −1 dBFS，防止 EQ 提升导致削波',
                  value: settings.equalizer.limiterEnabled,
                  onChanged: (bool value) => _update(
                    settings.copyWith(
                      equalizer: settings.equalizer.copyWith(
                        limiterEnabled: value,
                      ),
                    ),
                  ),
                ),
                _EqBandEditor(
                  equalizer: settings.equalizer,
                  onChanged: (int index, double gainDb) => _update(
                    settings.copyWith(
                      equalizer: settings.equalizer.withBandGain(index, gainDb),
                    ),
                  ),
                  onReset: () => _update(
                    settings.copyWith(
                      equalizer: settings.equalizer.copyWith(
                        bands: defaultHifiEqBands(),
                        preampDb: 0,
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// Ten vertical sliders, one per ISO octave centre.
class _EqBandEditor extends StatelessWidget {
  const _EqBandEditor({
    required this.equalizer,
    required this.onChanged,
    required this.onReset,
  });

  final HifiEqualizerState equalizer;
  final void Function(int index, double gainDb) onChanged;
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) {
    final AppleSemanticColors apple = AppleSemanticColors.of(context);
    final ThemeData theme = Theme.of(context);
    final List<HifiEqBand> bands = equalizer.effectiveBands;
    final double bandWidth =
        40 * (MediaQuery.textScalerOf(context).scale(12) / 12).clamp(1, 3);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: <Widget>[
                for (int index = 0; index < bands.length; index++)
                  SizedBox(
                    width: bandWidth,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Text(
                          bands[index].gainDb.toStringAsFixed(1),
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: apple.secondaryLabel,
                          ),
                        ),
                        RotatedBox(
                          quarterTurns: -1,
                          child: SizedBox(
                            width: 130,
                            height: 40,
                            child: SemanticsPortal(
                              child: Slider(
                                key: ValueKey<String>('hifi-eq-band-$index'),
                                value: clampHifiEqGainDb(bands[index].gainDb),
                                min: kMinHifiEqGainDb,
                                max: kMaxHifiEqGainDb,
                                onChanged: (double value) =>
                                    onChanged(index, _tenthDb(value)),
                              ),
                            ),
                          ),
                        ),
                        Text(
                          _frequencyLabel(bands[index].frequencyHz),
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: apple.label,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: SpringTextButton(
              onPressed: onReset,
              child: Text(context.tr('重置为平直')),
            ),
          ),
        ],
      ),
    );
  }

  static String _frequencyLabel(double hz) {
    if (hz >= 1000) {
      final double k = hz / 1000;
      return '${k == k.roundToDouble() ? k.toInt() : k.toStringAsFixed(1)}k';
    }
    return hz.toInt().toString();
  }
}

double _tenthDb(double value) => (value * 10).roundToDouble() / 10;

/// The dropdown's value: the encoded order, because the selector compares with
/// `==` and two equal `List<int>`s are not equal.
String _dspOrderChoice(HifiSettings settings) =>
    encodeDspStageOrder(settings.dspStageOrder);

/// One row of the 信号路径 panel.
class SignalPathReadout {
  const SignalPathReadout(this.label, this.value);

  final String label;
  final String value;
}

/// The rows the 信号路径 panel shows, derived from what the engine reported.
///
/// Public and pure so the bit-perfect rule is asserted directly instead of through
/// a rendered page: the transport must be exclusive or an explicitly validated
/// USB client path, with DSP bypassed and the source format preserved. The USB
/// verdict is distinguished from hardware exclusivity and physical DAC testing.
List<SignalPathReadout> signalPathReadouts({
  required LazerStreamInfo? info,
  LazerEngineMetrics? metrics,
  bool iosSystemRoute = false,
}) {
  final OutputPathState? path = info?.outputPath;
  final String failing = path?.failingConditions.join('; ') ?? '';
  return <SignalPathReadout>[
    SignalPathReadout('解码格式', info == null ? '未播放' : info.codec),
    SignalPathReadout(
      '源',
      info == null
          ? '—'
          : info.hasDsdSource
          ? 'DSD${info.sourceDsdRateMultiplier}x'
          : '${info.sourceSampleRate} Hz / ${info.sourceBitsPerSample}-bit',
    ),
    SignalPathReadout(
      '输出会话',
      info == null
          ? '—'
          : '${info.outputSampleRate} Hz / ${info.outputBitsPerSample}-bit'
                '${info.outputIsFloat ? ' float' : ''}'
                '${info.outputContainerBitsPerSample > info.outputBitsPerSample ? '（${info.outputContainerBitsPerSample}-bit 容器）' : ''}',
    ),
    if (iosSystemRoute)
      const SignalPathReadout('严格输出', '不支持')
    else ...<SignalPathReadout>[
      SignalPathReadout(
        '格式选择',
        info == null
            ? '—'
            : _FormatCard.selectionLabel(info.outputFormatSelection),
      ),
      SignalPathReadout(
        'Bit-perfect',
        path == null
            ? '—'
            : path.bitPerfect
            ? path.transparentUsb
                  ? 'USB 严格输出（未作硬件位校验）'
                  : '是（独占 · 无 DSP · 格式一致）'
            : '否（$failing）',
      ),
      SignalPathReadout(
        '独占',
        path == null ? '—' : (path.exclusive ? '是' : '否'),
      ),
      SignalPathReadout(
        '格式与源一致',
        path == null ? '—' : (path.formatMatchesSource ? '是' : '否'),
      ),
    ],
    SignalPathReadout(
      'DSP',
      path == null ? '—' : (path.dspActive ? '在信号路径中' : '不在信号路径中'),
    ),
    // The output-side counters the HiFi work has to be able to point at.
    SignalPathReadout('输出缓冲', metrics == null ? '—' : metrics.summary),
    if (info != null && info.telemetryValid)
      SignalPathReadout(
        '遥测',
        '峰值 ${(info.peakMilliDbfs / 1000).toStringAsFixed(1)} dBFS'
            '${info.limiterGainReductionMilliDb == 0 ? '' : ' · 限幅 ${(info.limiterGainReductionMilliDb / 1000).toStringAsFixed(1)} dB'}'
            '${info.clippedSampleCount == 0 ? '' : ' · 削波 ${info.clippedSampleCount}'}',
      ),
  ];
}

/// The live format readout: what the engine negotiated, not what was requested.
class _FormatCard extends StatelessWidget {
  const _FormatCard({required this.hifi});

  final HifiController hifi;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppleSemanticColors apple = AppleSemanticColors.of(context);
    final List<SignalPathReadout> rows = signalPathReadouts(
      info: hifi.streamInfo,
      metrics: hifi.readMetrics(),
      iosSystemRoute: hifi.usesIosSystemRoute,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const _SectionLabel('信号路径'),
        AppleGroupedCard(
          margin: EdgeInsets.zero,
          child: Column(
            children: <Widget>[
              for (final SignalPathReadout row in rows)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 9, 16, 9),
                  child: Row(
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          context.tr(row.label),
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: apple.secondaryLabel,
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Flexible(
                        child: Text(
                          context.tr(row.value),
                          textAlign: TextAlign.right,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: apple.label,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  /// How the engine selected the initialized output format, in the panel's words.
  static String selectionLabel(int selection) => switch (selection) {
    1 => '共享混音',
    2 => '独占 · 源格式',
    3 => '独占 · 同采样率替代格式',
    4 => '独占 · 单声道转立体声',
    5 => '独占 · 混音回退',
    6 => '独占 · 通用采样率回退',
    7 => 'DoP 载波',
    8 => '原生 DSD_U8',
    9 => '原生 DSD_U16_LE',
    10 => '原生 DSD_U16_BE',
    11 => '原生 DSD_U32_LE',
    12 => '原生 DSD_U32_BE',
    13 => 'USB 严格 PCM（实验性）',
    14 => 'USB DoP 载波（实验性）',
    _ => '未知',
  };
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    final AppleSemanticColors apple = AppleSemanticColors.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 22, 12, 7),
      child: Text(
        context.tr(label),
        style: Theme.of(context).textTheme.labelMedium?.copyWith(
          color: apple.secondaryLabel,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}
