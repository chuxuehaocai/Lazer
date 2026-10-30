// The HiFi output section of the Settings page.
//
// It exists to make the native engine's capabilities reachable without ever
// overstating them: every row says what the choice does, and the readout at the
// end shows the format the engine actually negotiated rather than what was asked
// for. A device that refused exclusive mode, a bit-perfect request the endpoint
// could not honour, or a DoP policy without a DSD source all stay visible instead
// of being reported as "enabled".
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../audio/hifi_controller.dart';
import '../audio/native/lazer_audio_devices.dart';
import '../audio/native/lazer_audio_engine.dart';
import '../l10n/app_localizations.dart';
import '../state/app_state.dart';
import '../state/hifi_settings.dart';
import '../theme/apple_design.dart';
import '../tv/tv_mode.dart';
import '../widgets/accessible_controls.dart';
import '../widgets/apple_ui.dart';
import 'ui_scaling.dart';
import 'audio_engine_settings.dart';
import 'settings_detail.dart';

/// Renders the 高保真播放 group: engine status, output device, exclusive/bit-perfect
/// policy, DSD mode, buffer, equaliser and the live format readout.
class HifiSettingsSection extends StatefulWidget {
  const HifiSettingsSection({super.key, required this.state});

  final AppState state;

  @override
  State<HifiSettingsSection> createState() => _HifiSettingsSectionState();
}

class _HifiSettingsSectionState extends State<HifiSettingsSection> {
  HifiController? _controller;
  bool _loaded = false;

  HifiController? get _hifi => widget.state.hifi;

  @override
  void initState() {
    super.initState();
    _controller = _hifi;
    if (_controller != null) {
      _controller!.addListener(_changed);
      if (!_loaded) {
        _loaded = true;
        unawaited(_controller!.refreshDevices());
      }
    }
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
              if (native && hifi.supportsDevices)
                _SettingRow(
                  label: '输出设备',
                  subtitle: _deviceSubtitle(hifi, settings),
                  trailing: _DevicePicker(
                    hifi: hifi,
                    settings: settings,
                    onChanged: (String? token, String? name) => _update(
                      token == null
                          ? settings.copyWith(clearOutput: true)
                          : settings.copyWith(
                              outputToken: token,
                              outputName: name,
                            ),
                    ),
                  ),
                ),
              if (native)
                _SwitchRow(
                  label: '独占输出',
                  subtitle: hifi.supportsExclusiveMode
                      ? '独占模式请求设备不再与系统混音共用；实际是否独占以引擎报告的会话格式为准'
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
              if (native)
                _SwitchRow(
                  label: 'Bit-perfect 输出',
                  subtitle: _bitPerfectSubtitle(settings),
                  value: settings.bitPerfect,
                  enabled: hifi.supportsExclusiveMode,
                  onChanged: (bool value) => _update(
                    settings.copyWith(
                      bitPerfect: value,
                      exclusiveMode: value ? true : settings.exclusiveMode,
                    ),
                  ),
                ),
              if (native && _needsVolumeWarning(settings))
                const _WarningRow(
                  '软件音量必须为 100%：Bit-perfect 会绕过音量与 EQ，引擎会以此拒绝直接输出',
                ),
              if (native && hifi.supportsDoP)
                _SettingRow(
                  label: 'DSD 输出',
                  subtitle: _dsdSubtitle(hifi, settings),
                  trailing: DropdownButton<HifiDsdOutputMode>(
                    key: const ValueKey('hifi-dsd-mode'),
                    value: settings.dsdOutputMode,
                    underline: const SizedBox.shrink(),
                    borderRadius: BorderRadius.circular(12),
                    items: <DropdownMenuItem<HifiDsdOutputMode>>[
                      for (final HifiDsdOutputMode mode
                          in HifiDsdOutputMode.values)
                        if (mode != HifiDsdOutputMode.requireNative ||
                            hifi.supportsNativeDsd)
                          DropdownMenuItem<HifiDsdOutputMode>(
                            value: mode,
                            child: Text(mode.label),
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
              if (native && hifi.supportsDoP)
                _SettingRow(
                  label: 'DSD 倍率策略',
                  subtitle: _dsdRatePolicySubtitle(settings),
                  trailing: DropdownButton<HifiDsdRatePolicy>(
                    key: const ValueKey('hifi-dsd-rate-policy'),
                    value: settings.dsdRatePolicy,
                    underline: const SizedBox.shrink(),
                    borderRadius: BorderRadius.circular(12),
                    items: <DropdownMenuItem<HifiDsdRatePolicy>>[
                      for (final HifiDsdRatePolicy policy
                          in HifiDsdRatePolicy.values)
                        DropdownMenuItem<HifiDsdRatePolicy>(
                          value: policy,
                          child: Text(policy.label),
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
                  trailing: DropdownButton<HifiVolumeNormalization>(
                    key: const ValueKey('hifi-normalization'),
                    value: settings.volumeNormalization,
                    underline: const SizedBox.shrink(),
                    borderRadius: BorderRadius.circular(12),
                    items: <DropdownMenuItem<HifiVolumeNormalization>>[
                      for (final HifiVolumeNormalization mode
                          in HifiVolumeNormalization.values)
                        DropdownMenuItem<HifiVolumeNormalization>(
                          value: mode,
                          child: Text(mode.label),
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
                  trailing: DropdownButton<HifiBufferSize>(
                    key: const ValueKey('hifi-buffer'),
                    value: settings.buffer,
                    underline: const SizedBox.shrink(),
                    borderRadius: BorderRadius.circular(12),
                    items: <DropdownMenuItem<HifiBufferSize>>[
                      for (final HifiBufferSize size in HifiBufferSize.values)
                        DropdownMenuItem<HifiBufferSize>(
                          value: size,
                          child: Text('${size.label} · ${size.millis}ms'),
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
                  subtitle: settings.bitPerfect
                      ? 'Bit-perfect 输出时 crossfeed 被旁路，先关闭 Bit-perfect'
                      : '把每声道延时、低通后混入对侧，减轻耳机里"声音在脑中"的感觉',
                  value: settings.crossfeedActive,
                  enabled: !settings.bitPerfect,
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
                        '延时 ${settings.crossfeed.effectiveDelayMs.toStringAsFixed(2)} ms'
                        ' · 截止 ${settings.crossfeed.effectiveCutoffHz.round()} Hz',
                    trailing: DropdownButton<HifiCrossfeedAlgorithm>(
                      key: const ValueKey('hifi-crossfeed-algorithm'),
                      value: settings.crossfeed.algorithm,
                      underline: const SizedBox.shrink(),
                      borderRadius: BorderRadius.circular(12),
                      items: <DropdownMenuItem<HifiCrossfeedAlgorithm>>[
                        for (final HifiCrossfeedAlgorithm algorithm
                            in HifiCrossfeedAlgorithm.values)
                          DropdownMenuItem<HifiCrossfeedAlgorithm>(
                            value: algorithm,
                            child: Text(algorithm.label),
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
    if (settings.outputToken == null) return '系统默认输出设备';
    final LazerOutputDevice? device = hifi.selectedDevice;
    if (device == null) {
      return settings.outputName == null
          ? '已保存的设备当前不可用，将回退到系统默认'
          : '${settings.outputName}（当前不可用，将回退到系统默认）';
    }
    final StringBuffer buffer = StringBuffer(device.displayName);
    if (!device.isActive) buffer.write('（未激活）');
    if (device.hardwareVolumeFlags != null) {
      buffer.write(device.hasHardwareVolume ? ' · 硬件音量' : ' · 无硬件音量');
    }
    return buffer.toString();
  }

  String _bitPerfectSubtitle(HifiSettings settings) {
    if (settings.bitPerfect) {
      return '要求设备接受与源完全相同的整数格式；不满足时打开会失败，而不是悄悄转成 PCM';
    }
    return '解码后的整数样本直接送设备，同时旁路软件音量与 EQ';
  }

  String _dsdSubtitle(HifiController hifi, HifiSettings settings) {
    switch (settings.dsdOutputMode) {
      case HifiDsdOutputMode.auto:
        return '按设备能力自动选择：原生 DSD → DoP → PCM，逐级回退';
      case HifiDsdOutputMode.convertToPcm:
        return 'DSD 源码解码为 PCM，任何设备都能播放';
      case HifiDsdOutputMode.requireDoP:
        return '要求精确的 24-bit DoP 载波；设备不接受时拒绝播放，不回退';
      case HifiDsdOutputMode.requireNative:
        return hifi.supportsNativeDsd
            ? '要求 ALSA 原生 DSD 字格式，仅 Linux hw: 直连可用'
            : '仅 Linux ALSA 直连支持原生 DSD';
    }
  }

  String _dsdRatePolicySubtitle(HifiSettings settings) {
    final HifiDsdRatePolicy policy = settings.dsdRatePolicy;
    return policy.isSupported
        ? policy.detail
        : '${policy.detail}（本引擎未实现，选择后仍按 PCM 回退行为播放）';
  }

  String _normalizationSubtitle(HifiSettings settings) {
    final HifiVolumeNormalization mode = settings.volumeNormalization;
    return mode.isSupported ? mode.detail : '${mode.detail}（需要测量阶段，本引擎未实现）';
  }

  bool _needsVolumeWarning(HifiSettings settings) =>
      settings.bitPerfect && widget.state.volume < 0.999;
}

/// One row in the grouped card, matching the settings page's own rows.
class _SettingRow extends StatelessWidget {
  const _SettingRow({
    required this.label,
    required this.subtitle,
    required this.trailing,
  });

  final String label;
  final String subtitle;
  final Widget trailing;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppleSemanticColors apple = AppleSemanticColors.of(context);
    final bool stacked = MediaQuery.sizeOf(context).width < 360;
    final Widget heading = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          context.tr(label),
          style: theme.textTheme.bodyLarge?.copyWith(color: apple.label),
        ),
        if (subtitle.isNotEmpty) ...<Widget>[
          const SizedBox(height: 2),
          Text(
            context.tr(subtitle),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              color: apple.secondaryLabel,
            ),
          ),
        ],
      ],
    );
    return TvFocusHighlight(
      borderRadius: BorderRadius.circular(10),
      child: Container(
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: apple.separator, width: .5)),
        ),
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
        child: stacked
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  heading,
                  const SizedBox(height: 8),
                  Align(alignment: Alignment.centerLeft, child: trailing),
                ],
              )
            : Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: <Widget>[
                  Expanded(flex: 4, child: heading),
                  const SizedBox(width: 12),
                  Flexible(
                    flex: 6,
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: trailing,
                    ),
                  ),
                ],
              ),
      ),
    );
  }
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
          child: DropdownButton<String?>(
            key: const ValueKey('hifi-device'),
            value: selectionKnown ? selected : null,
            isExpanded: true,
            underline: const SizedBox.shrink(),
            borderRadius: BorderRadius.circular(12),
            items: <DropdownMenuItem<String?>>[
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
                    overflow: TextOverflow.ellipsis,
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
        IconButton(
          tooltip: context.tr('刷新设备列表'),
          onPressed: hifi.busy ? null : () => unawaited(hifi.refreshDevices()),
          icon: const Icon(Icons.refresh, size: 18),
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
    margin: const EdgeInsets.only(bottom: 16),
    child: AppleListTile(
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
                subtitle: settings.bitPerfect
                    ? 'Bit-perfect 输出时 EQ 被旁路，先关闭 Bit-perfect'
                    : 'DSP 处理会改变样本，因此不再属于 bit-perfect 路径',
                value: settings.eqActive,
                enabled: !settings.bitPerfect,
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
                  trailing: DropdownButton<String>(
                    key: const ValueKey('hifi-eq-preset'),
                    value: settings.equalizer.matchingPresetId,
                    hint: const TrText('自定义'),
                    underline: const SizedBox.shrink(),
                    borderRadius: BorderRadius.circular(12),
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
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          SizedBox(
            height: UiMetrics.scaleOf(context) > 1.2 ? 210 : 180,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: <Widget>[
                  for (int index = 0; index < bands.length; index++)
                    SizedBox(
                      width: 40,
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.end,
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
          ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
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

/// The live format readout: what the engine negotiated, not what was requested.
class _FormatCard extends StatelessWidget {
  const _FormatCard({required this.hifi});

  final HifiController hifi;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppleSemanticColors apple = AppleSemanticColors.of(context);
    final LazerStreamInfo? info = hifi.streamInfo;
    final List<_Readout> rows = <_Readout>[
      _Readout('解码格式', info == null ? '未播放' : info.codec),
      _Readout(
        '源',
        info == null
            ? '—'
            : info.hasDsdSource
            ? 'DSD${info.sourceDsdRateMultiplier}x'
            : '${info.sourceSampleRate} Hz / ${info.sourceBitsPerSample}-bit',
      ),
      _Readout(
        '输出会话',
        info == null
            ? '—'
            : '${info.outputSampleRate} Hz / ${info.outputBitsPerSample}-bit'
                  '${info.outputIsFloat ? ' float' : ''}'
                  '${info.outputContainerBitsPerSample > info.outputBitsPerSample ? '（${info.outputContainerBitsPerSample}-bit 容器）' : ''}',
      ),
      _Readout(
        '格式选择',
        info == null ? '—' : _selectionLabel(info.outputFormatSelection),
      ),
      _Readout(
        '独占 / Bit-perfect',
        info == null
            ? '—'
            : '${info.outputExclusive ? '独占' : '共享'} / '
                  '${info.bitPerfectActive ? '是' : '否'}',
      ),
      if (info != null && info.telemetryValid)
        _Readout(
          '遥测',
          '峰值 ${(info.peakMilliDbfs / 1000).toStringAsFixed(1)} dBFS'
              '${info.limiterGainReductionMilliDb == 0 ? '' : ' · 限幅 ${(info.limiterGainReductionMilliDb / 1000).toStringAsFixed(1)} dB'}'
              '${info.clippedSampleCount == 0 ? '' : ' · 削波 ${info.clippedSampleCount}'}',
        ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const _SectionLabel('信号路径'),
        AppleGroupedCard(
          margin: EdgeInsets.zero,
          child: Column(
            children: <Widget>[
              for (final _Readout row in rows)
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
                          row.value,
                          textAlign: TextAlign.right,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: apple.label,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: Text(
                  context.tr('这里的格式是引擎与平台协商的结果，不是从 DAC 读回的格式，也不代表链路中没有系统重采样'),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: apple.secondaryLabel,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  static String _selectionLabel(int selection) => switch (selection) {
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
    _ => '未知',
  };
}

class _Readout {
  const _Readout(this.label, this.value);

  final String label;
  final String value;
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
