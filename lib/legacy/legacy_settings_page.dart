import 'dart:async';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/material.dart';

import '../audio/audio_device_report.dart';
import '../data/audio_quality.dart';
import '../diagnostics/build_info.dart';
import '../diagnostics/export_logs.dart';
import '../downloads/download_queue_sheet.dart';
import '../l10n/app_language.dart';
import '../l10n/app_localizations.dart';
import '../scrolling/scroll_motion.dart';
import '../state/app_state.dart';
import '../state/ui_preferences.dart';
import '../theme/apple_design.dart';
import '../widgets/accessible_controls.dart';
import '../widgets/apple_ui.dart';
import '../widgets/hifi_settings_section.dart';
import '../widgets/listen_together_dialog.dart';
import '../widgets/settings_detail.dart';
import '../widgets/settings_choice.dart';
import '../tv/tv_mode.dart';
import '../updates/update_dialog.dart';
import '../utils/background_image.dart';
import '../utils/byte_format.dart';
import '../widgets/ui_scaling.dart';
import 'legacy_login.dart';
import 'legacy_widgets.dart';
import 'font_settings_page.dart';
import 'shortcut_settings_page.dart';
import '../widgets/music_provider_badge.dart';

/// A single-column, inset-grouped Settings page, following the iOS Settings
/// information architecture rather than a desktop form grid.
class LegacySettingsPage extends StatelessWidget {
  const LegacySettingsPage({
    super.key,
    required this.state,
    this.onOpenLocalMusic,
    this.backgroundImagePicker,
  });

  final AppState state;

  /// Jumps to the local-music page from the download settings group.
  final VoidCallback? onOpenLocalMusic;

  /// Overrides the platform picture picker. Tests and platform forks can
  /// supply a stored file without opening a system dialog.
  final Future<String?> Function()? backgroundImagePicker;

  @override
  Widget build(BuildContext context) => SettingsDetailHost(
    compact: useCompactLayout(state.uiMode, MediaQuery.sizeOf(context).width),
    child: _SettingsOverview(
      state: state,
      onOpenLocalMusic: onOpenLocalMusic,
      backgroundImagePicker: backgroundImagePicker,
    ),
  );
}

class _SettingsOverview extends StatelessWidget {
  const _SettingsOverview({
    required this.state,
    this.onOpenLocalMusic,
    this.backgroundImagePicker,
  });
  final AppState state;
  final VoidCallback? onOpenLocalMusic;
  final Future<String?> Function()? backgroundImagePicker;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppleSemanticColors apple = AppleSemanticColors.of(context);
    final double minScale = UiMetrics.minScaleOf(context);
    final double shownScale = UiMetrics.scaleOf(context);
    final bool car = UiMetrics.carOf(context);
    final DynamicBackgroundPrecision flowPrecision =
        DynamicBackgroundPrecision.of(state.dynamicBackgroundQuality);
    final double inset = legacyPageInset(context);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: ListView(
          key: const PageStorageKey('settings-overview-scroll'),
          padding: EdgeInsets.fromLTRB(inset, 8, inset, 36),
          children: <Widget>[
            const ApplePageTitle(
              title: '设置',
              subtitle: '外观、界面和账户。',
              padding: EdgeInsets.fromLTRB(0, 12, 0, 20),
            ),
            const _LegacySectionLabel('界面'),
            AppleGroupedCard(
              margin: EdgeInsets.zero,
              child: Column(
                children: <Widget>[
                  AppleListTile(
                    key: const ValueKey('open-font-settings'),
                    title: context.tr('字体自定义'),
                    subtitle: context.tr('调节页面文字与歌词的大小和粗细'),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => SettingsDetailHost.open(
                      context,
                      page: (_) => FontSettingsPage(state: state),
                      view: (_) => FontSettingsView(state: state),
                    ),
                  ),
                  _LegacySettingRow(
                    label: '配色',
                    subtitle: state.legacyPalette.detail,
                    trailing: DropdownButton<LegacyPaletteMode>(
                      value: state.legacyPalette,
                      underline: const SizedBox.shrink(),
                      borderRadius: BorderRadius.circular(12),
                      items: <DropdownMenuItem<LegacyPaletteMode>>[
                        for (final LegacyPaletteMode mode
                            in LegacyPaletteMode.values)
                          DropdownMenuItem<LegacyPaletteMode>(
                            value: mode,
                            child: TrText(mode.label),
                          ),
                      ],
                      onChanged: (LegacyPaletteMode? value) {
                        if (value == null) return;
                        unawaited(state.setLegacyPalette(value));
                        if (value == LegacyPaletteMode.custom &&
                            state.legacyAccentColor == null) {
                          unawaited(_pickLegacyAccent(context, state));
                        }
                      },
                    ),
                  ),
                  if (state.legacyPalette == LegacyPaletteMode.custom)
                    _LegacySettingRow(
                      label: '强调色',
                      subtitle: '点按色块挑选主题强调色',
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          Text(
                            _accentHex(
                              state.legacyAccentColor ?? AppleColors.musicRed,
                            ),
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: apple.secondaryLabel,
                              fontFeatures: const <FontFeature>[
                                FontFeature.tabularFigures(),
                              ],
                            ),
                          ),
                          const SizedBox(width: 10),
                          _LegacyAccentSwatch(
                            key: const ValueKey('legacy-accent-swatch'),
                            color:
                                state.legacyAccentColor ?? AppleColors.musicRed,
                            onTap: () =>
                                unawaited(_pickLegacyAccent(context, state)),
                          ),
                        ],
                      ),
                    ),
                  _LegacySettingRow(
                    label: '设备形态',
                    subtitle: state.surface.detail,
                    trailing: DropdownButton<AppSurface>(
                      value: state.surface,
                      underline: const SizedBox.shrink(),
                      borderRadius: BorderRadius.circular(12),
                      items: <DropdownMenuItem<AppSurface>>[
                        for (final AppSurface surface in AppSurface.values)
                          DropdownMenuItem<AppSurface>(
                            value: surface,
                            child: TrText(surface.label),
                          ),
                      ],
                      onChanged: (AppSurface? value) {
                        if (value != null) unawaited(state.setSurface(value));
                      },
                    ),
                  ),
                  _LegacySettingRow(
                    label: '界面布局',
                    subtitle: state.uiMode.detail,
                    trailing: DropdownButton<AppUiMode>(
                      value: state.uiMode,
                      underline: const SizedBox.shrink(),
                      borderRadius: BorderRadius.circular(12),
                      items: <DropdownMenuItem<AppUiMode>>[
                        for (final AppUiMode mode in AppUiMode.values)
                          DropdownMenuItem<AppUiMode>(
                            value: mode,
                            child: TrText(mode.label),
                          ),
                      ],
                      onChanged: (AppUiMode? value) {
                        if (value != null) unawaited(state.setUiMode(value));
                      },
                    ),
                  ),
                  _LegacySliderRow(
                    key: const ValueKey('dpi-scale-slider'),
                    label: 'DPI 缩放',
                    valueText: '${(shownScale * 100).round()}%',
                    subtitle: state.autoDpiScale
                        ? '自动推算 · 拖动拉杆即改为手动'
                        : car
                        ? '车机形态已把界面放大到 ${(minScale * 100).round()}% 起'
                        : '按比例放大整块界面，适合高分屏',
                    value: shownScale.clamp(minScale, kDpiScaleMax),
                    min: minScale,
                    max: kDpiScaleMax,
                    divisions: ((kDpiScaleMax - minScale) / kDpiScaleStep)
                        .round(),
                    onChanged: (double value) =>
                        unawaited(state.setDpiScale(value)),
                    action: TextButton(
                      key: const ValueKey('dpi-scale-reset'),
                      onPressed: () => unawaited(state.resetDpiScale()),
                      child: const TrText('恢复默认'),
                    ),
                  ),
                  _LegacySwitchRow(
                    key: const ValueKey('auto-dpi-switch'),
                    label: '自动调节 DPI 缩放',
                    subtitle: '按窗口可用空间自动推算',
                    value: state.autoDpiScale,
                    onChanged: (bool value) =>
                        unawaited(state.setAutoDpiScale(value)),
                  ),
                  _LegacySettingRow(
                    label: '背景',
                    subtitle: state.legacyBackground.detail,
                    trailing: SettingsChoice<LegacyBackgroundMode>(
                      key: const ValueKey('browse-background-mode'),
                      value: state.legacyBackground,
                      items: <DropdownMenuItem<LegacyBackgroundMode>>[
                        for (final LegacyBackgroundMode mode
                            in LegacyBackgroundMode.values)
                          DropdownMenuItem<LegacyBackgroundMode>(
                            value: mode,
                            child: TrText(mode.label),
                          ),
                      ],
                      onChanged: (LegacyBackgroundMode? value) {
                        if (value == null) return;
                        unawaited(state.setLegacyBackground(value));
                        if (value == LegacyBackgroundMode.customImage &&
                            state.legacyBackgroundImagePath == null) {
                          unawaited(
                            _pickBackgroundImage(
                              context,
                              state,
                              backgroundImagePicker,
                            ),
                          );
                        }
                      },
                    ),
                  ),
                  if (state.legacyBackground ==
                      LegacyBackgroundMode.customImage)
                    _LegacySettingRow(
                      label: '背景图片',
                      subtitle: state.legacyBackgroundImagePath == null
                          ? '尚未选择图片，点按右侧选择'
                          : '已选择图片，可更换或移除',
                      trailing: Wrap(
                        spacing: 8,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: <Widget>[
                          if (state.legacyBackgroundImagePath != null)
                            TextButton(
                              key: const ValueKey('background-image-clear'),
                              onPressed: () {
                                final String? path =
                                    state.legacyBackgroundImagePath;
                                unawaited(state.setLegacyBackgroundImage(null));
                                unawaited(
                                  state.setLegacyBackground(
                                    LegacyBackgroundMode.off,
                                  ),
                                );
                                unawaited(deleteCustomBackgroundImage(path));
                              },
                              child: const TrText('移除'),
                            ),
                          OutlinedButton(
                            key: const ValueKey('background-image-pick'),
                            onPressed: () => unawaited(
                              _pickBackgroundImage(
                                context,
                                state,
                                backgroundImagePicker,
                              ),
                            ),
                            child: Text(
                              context.tr(
                                state.legacyBackgroundImagePath == null
                                    ? '选择图片'
                                    : '更换',
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  _LegacySliderRow(
                    key: const ValueKey('legacy-ui-alpha'),
                    label: '内容不透明度',
                    valueText: '${(state.legacyUiAlpha * 100).round()}%',
                    subtitle: '数值越小，背景越明显',
                    value: state.legacyUiAlpha.clamp(0.4, 1.0),
                    min: 0.4,
                    max: 1.0,
                    divisions: 12,
                    onChanged:
                        state.legacyBackground == LegacyBackgroundMode.off
                        ? null
                        : (double value) =>
                              unawaited(state.setLegacyUiAlpha(value)),
                  ),
                  _BackgroundPreferences(state: state, player: false),
                  // The flowing canvas is the app's only continuously
                  // repainting surface, so its precision is the setting a
                  // struggling GPU needs. Both halves of it are shown —
                  // the mesh it draws and how often it redraws it — so the
                  // value is verifiable rather than a blind percentage.
                  _LegacySliderRow(
                    key: const ValueKey('dynamic-background-quality'),
                    label: '动态背景渲染精度',
                    valueText:
                        '${(state.dynamicBackgroundQuality * 100).round()}%',
                    // One literal on purpose: the translation table matches
                    // it as a single pattern key.
                    subtitle:
                        '网格 ${flowPrecision.columns}×${flowPrecision.rows}，帧率单独设置',
                    value: state.dynamicBackgroundQuality,
                    min: kDynamicBackgroundQualityMin,
                    max: kDynamicBackgroundQualityMax,
                    divisions:
                        ((kDynamicBackgroundQualityMax -
                                    kDynamicBackgroundQualityMin) /
                                kDynamicBackgroundQualityStep)
                            .round(),
                    onChanged: (double value) =>
                        unawaited(state.setDynamicBackgroundQuality(value)),
                    action: TextButton(
                      key: const ValueKey('dynamic-background-quality-reset'),
                      onPressed: () =>
                          unawaited(state.resetDynamicBackgroundQuality()),
                      child: const TrText('恢复默认'),
                    ),
                  ),
                ],
              ),
            ),
            const _LegacySectionLabel('外观'),
            AppleGroupedCard(
              margin: EdgeInsets.zero,
              child: Column(
                children: <Widget>[
                  _LegacySettingRow(
                    label: '主题',
                    subtitle: switch (state.themeMode) {
                      ThemeMode.system => '跟随系统',
                      ThemeMode.light => '浅色',
                      ThemeMode.dark => '深色',
                    },
                    trailing: DropdownButton<ThemeMode>(
                      value: state.themeMode,
                      underline: const SizedBox.shrink(),
                      borderRadius: BorderRadius.circular(12),
                      items: const <DropdownMenuItem<ThemeMode>>[
                        DropdownMenuItem<ThemeMode>(
                          value: ThemeMode.system,
                          child: TrText('跟随系统'),
                        ),
                        DropdownMenuItem<ThemeMode>(
                          value: ThemeMode.light,
                          child: TrText('浅色'),
                        ),
                        DropdownMenuItem<ThemeMode>(
                          value: ThemeMode.dark,
                          child: TrText('深色'),
                        ),
                      ],
                      onChanged: (ThemeMode? value) {
                        if (value != null) {
                          unawaited(state.setThemeMode(value));
                        }
                      },
                    ),
                  ),
                  _LegacySettingRow(
                    label: '语言',
                    subtitle: state.language.name,
                    trailing: DropdownButton<AppLanguage>(
                      value: state.language,
                      underline: const SizedBox.shrink(),
                      borderRadius: BorderRadius.circular(12),
                      items: <DropdownMenuItem<AppLanguage>>[
                        for (final AppLanguage language in AppLanguage.values)
                          DropdownMenuItem<AppLanguage>(
                            value: language,
                            child: Text(language.name),
                          ),
                      ],
                      onChanged: (AppLanguage? value) {
                        if (value != null) {
                          unawaited(state.setLanguage(value));
                        }
                      },
                    ),
                  ),
                ],
              ),
            ),
            const _LegacySectionLabel('动态背景'),
            AppleGroupedCard(
              margin: EdgeInsets.zero,
              child: _BackgroundPreferences(
                state: state,
                player: true,
                picker: backgroundImagePicker,
              ),
            ),
            const _LegacySectionLabel('播放'),
            AppleGroupedCard(
              margin: EdgeInsets.zero,
              child: Column(
                children: <Widget>[
                  _LegacySettingRow(
                    label: '播放音质',
                    subtitle: state.audioQualityDetail(state.playbackQuality),
                    trailing: DropdownButton<AudioQuality>(
                      key: const ValueKey('playback-quality'),
                      value: state.playbackQuality,
                      underline: const SizedBox.shrink(),
                      borderRadius: BorderRadius.circular(12),
                      items: <DropdownMenuItem<AudioQuality>>[
                        for (final AudioQuality quality in AudioQuality.values)
                          DropdownMenuItem<AudioQuality>(
                            value: quality,
                            child: TrText(state.audioQualityLabel(quality)),
                          ),
                      ],
                      onChanged: (AudioQuality? value) {
                        if (value != null) {
                          unawaited(state.setPlaybackQuality(value));
                        }
                      },
                    ),
                  ),
                  _LegacySwitchRow(
                    label: '独立播放',
                    subtitle: '不接入系统媒体控制',
                    value: state.independentPlayback,
                    onChanged: (bool value) =>
                        unawaited(state.setIndependentPlayback(value)),
                  ),
                ],
              ),
            ),
            HifiSettingsSection(state: state),
            const _LegacySectionLabel('下载'),
            AppleGroupedCard(
              margin: EdgeInsets.zero,
              child: Column(
                children: <Widget>[
                  _LegacySettingRow(
                    label: '下载音质',
                    subtitle: state.audioQualityDetail(state.downloadQuality),
                    trailing: DropdownButton<AudioQuality>(
                      key: const ValueKey('download-quality'),
                      value: state.downloadQuality,
                      underline: const SizedBox.shrink(),
                      borderRadius: BorderRadius.circular(12),
                      items: <DropdownMenuItem<AudioQuality>>[
                        for (final AudioQuality quality in AudioQuality.values)
                          DropdownMenuItem<AudioQuality>(
                            value: quality,
                            child: TrText(state.audioQualityLabel(quality)),
                          ),
                      ],
                      onChanged: (AudioQuality? value) {
                        if (value != null) {
                          unawaited(state.setDownloadQuality(value));
                        }
                      },
                    ),
                  ),
                  _LegacySettingRow(
                    label: '下载任务',
                    subtitle: '查看进度、取消或重试下载',
                    trailing: AnimatedBuilder(
                      animation: state.downloadManager,
                      builder: (BuildContext context, Widget? child) {
                        final int active = state.downloadManager.activeCount;
                        final int done = state.downloadManager.completedCount;
                        return Row(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            Text(
                              context.tr(
                                active > 0 ? '$active 进行中' : '$done 已完成',
                              ),
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: apple.secondaryLabel,
                              ),
                            ),
                            const SizedBox(width: 6),
                            TextButton(
                              key: const ValueKey('open-download-queue'),
                              onPressed: () =>
                                  showDownloadQueueSheet(context, state),
                              child: const TrText('查看'),
                            ),
                          ],
                        );
                      },
                    ),
                  ),
                  if (onOpenLocalMusic != null)
                    AnimatedBuilder(
                      animation: state.localLibrary,
                      builder: (BuildContext context, Widget? child) {
                        final int count = state.localLibrary.availableCount;
                        return _LegacySettingRow(
                          label: '本地音乐',
                          subtitle: count == 0
                              ? '下载和导入的歌曲会保存在这里'
                              : '$count 首 · ${formatBytes(state.localLibrary.totalBytes)}',
                          trailing: TextButton(
                            key: const ValueKey('open-local-music-settings'),
                            onPressed: onOpenLocalMusic,
                            child: const TrText('管理'),
                          ),
                        );
                      },
                    ),
                ],
              ),
            ),
            const _LegacySectionLabel('交互'),
            AppleGroupedCard(
              margin: EdgeInsets.zero,
              child: Column(
                children: <Widget>[
                  _LegacySwitchRow(
                    label: '震动反馈',
                    subtitle: '点击可操作的元素和拖动进度条、数值条时反馈',
                    value: state.hapticsEnabled,
                    onChanged: (bool value) =>
                        unawaited(state.setHapticsEnabled(value)),
                  ),
                  if (defaultTargetPlatform == TargetPlatform.iOS ||
                      defaultTargetPlatform == TargetPlatform.android)
                    _LegacySliderRow(
                      label: '震动强度',
                      valueText: '${(state.hapticIntensity * 100).round()}%',
                      value: state.hapticIntensity.clamp(0.0, 1.0),
                      min: 0,
                      max: 1,
                      divisions: 20,
                      onChanged: state.hapticsEnabled
                          ? (double value) =>
                                unawaited(state.setHapticIntensity(value))
                          : null,
                    ),
                  _LegacySliderRow(
                    label: '歌词控件自动隐藏',
                    valueText:
                        '${state.lyricControlsSeconds.toStringAsFixed(1)} 秒',
                    subtitle: '闲置一会儿后收起歌词页的控件',
                    value: state.lyricControlsSeconds.clamp(1.0, 10.0),
                    min: 1,
                    max: 10,
                    divisions: 18,
                    onChanged: (double value) =>
                        unawaited(state.setLyricControlsSeconds(value)),
                  ),
                ],
              ),
            ),
            const _LegacySectionLabel('快捷键'),
            AppleGroupedCard(
              margin: EdgeInsets.zero,
              child: AppleListTile(
                key: const ValueKey('open-shortcut-settings'),
                title: context.tr('快捷键设置'),
                subtitle: context.tr('自定义播放控制的键盘快捷键'),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => SettingsDetailHost.open(
                  context,
                  page: (_) => ShortcutSettingsPage(state: state),
                  view: (_) => ShortcutSettingsView(state: state),
                ),
              ),
            ),
            const _LegacySectionLabel('歌词'),
            AppleGroupedCard(
              margin: EdgeInsets.zero,
              child: Column(
                children: <Widget>[
                  _LegacySwitchRow(
                    key: const ValueKey('artwork-with-lyrics-switch'),
                    label: '歌词同时显示封面',
                    subtitle: '仅移动端：封面缩至歌曲信息旁，随播放控件收起；顶部保留歌曲信息',
                    value: state.showArtworkWithLyrics,
                    onChanged: (value) =>
                        unawaited(state.setShowArtworkWithLyrics(value)),
                  ),
                  _LegacySwitchRow(
                    label: '歌词模糊',
                    subtitle: '距离当前歌词越远，模糊越强；手动浏览时渐隐',
                    value: state.lyricBlurEnabled,
                    onChanged: (bool value) =>
                        unawaited(state.setLyricBlurEnabled(value)),
                  ),
                  _LegacySliderRow(
                    label: '手动浏览后恢复跟随',
                    valueText:
                        '${state.lyricResumeSeconds.toStringAsFixed(1)} 秒',
                    subtitle: '松开手后多久回到当前行',
                    value: state.lyricResumeSeconds.clamp(1.0, 10.0),
                    min: 1,
                    max: 10,
                    divisions: 18,
                    onChanged: (double value) =>
                        unawaited(state.setLyricResumeSeconds(value)),
                  ),
                ],
              ),
            ),
            const _LegacySectionLabel('滚动'),
            AppleGroupedCard(
              margin: EdgeInsets.zero,
              child: Column(
                children: <Widget>[
                  _LegacySliderRow(
                    label: '滚动惯性',
                    valueText: '${(state.scrollRetention * 100).round()}%',
                    subtitle: '85–98%；数值越高，松手后滑行越久、越远',
                    value: state.scrollRetention,
                    min: ScrollMotion.minRetention,
                    max: ScrollMotion.maxRetention,
                    divisions: 13,
                    onChanged: (double value) =>
                        unawaited(state.setScrollRetention(value)),
                    action: TextButton(
                      onPressed: () => unawaited(
                        state.setScrollRetention(ScrollMotion.defaultRetention),
                      ),
                      child: const TrText('恢复默认'),
                    ),
                  ),
                  _LegacySliderRow(
                    label: '滚动加速度',
                    valueText: '${(state.scrollAcceleration * 100).round()}%',
                    subtitle: '50–300%；数值越高，滚轮和连续甩动提速越明显',
                    value: state.scrollAcceleration,
                    min: ScrollMotion.minAcceleration,
                    max: ScrollMotion.maxAcceleration,
                    divisions: 25,
                    onChanged: (double value) =>
                        unawaited(state.setScrollAcceleration(value)),
                    action: TextButton(
                      onPressed: () => unawaited(
                        state.setScrollAcceleration(
                          ScrollMotion.defaultAcceleration,
                        ),
                      ),
                      child: const TrText('恢复默认'),
                    ),
                  ),
                ],
              ),
            ),
            const _LegacySectionLabel('性能'),
            AppleGroupedCard(
              margin: EdgeInsets.zero,
              child: Column(
                children: <Widget>[
                  _LegacySettingRow(
                    label: '动画帧预算',
                    subtitle: '全部界面动画按 10 ms 设计；低帧目标不低于 90 fps',
                    trailing: Text(
                      '10 ms',
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: apple.secondaryLabel,
                        fontFeatures: const <FontFeature>[
                          FontFeature.tabularFigures(),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            if (state.debugOptionsEnabled) ...<Widget>[
              const _LegacySectionLabel('调试'),
              AppleGroupedCard(
                margin: EdgeInsets.zero,
                child: Column(
                  children: <Widget>[
                    _LegacySwitchRow(
                      label: '显示帧数',
                      subtitle: '实时显示 UI、GPU、低帧和 100 fps 帧预算',
                      value: state.showFrameStats,
                      onChanged: (bool value) =>
                          unawaited(state.setShowFrameStats(value)),
                    ),
                    _LegacySettingRow(
                      label: '音频设备',
                      subtitle: '查看当前音频输出端点和音频会话详情',
                      trailing: OutlinedButton(
                        key: const ValueKey('open-audio-device-info'),
                        onPressed: () =>
                            unawaited(showAudioDeviceInfoDialog(context)),
                        child: const TrText('查看'),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            const _LegacySectionLabel('账户'),
            AppleGroupedCard(
              margin: EdgeInsets.zero,
              child: Column(
                children: <Widget>[
                  AppleListTile(
                    key: const ValueKey('music-platform-settings'),
                    title: context.tr('音乐平台'),
                    subtitle: state.isNavidrome
                        ? 'Navidrome'
                        : context.tr('网易云音乐'),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (state.musicProvider.experimental)
                          const ExperimentalMusicBadge(),
                        const SizedBox(width: 8),
                        const Icon(Icons.chevron_right_rounded),
                      ],
                    ),
                    onTap: () =>
                        unawaited(showLegacyLoginDialog(context, state)),
                  ),
                  _LegacySettingRow(
                    label: state.isGuest ? '游客' : state.user.name,
                    subtitle: state.isGuest
                        ? '登录后同步歌单和每日推荐'
                        : state.user.vipLabel ?? '普通用户',
                    trailing: state.isGuest
                        ? FilledButton(
                            onPressed: () => unawaited(
                              showLegacyLoginDialog(context, state),
                            ),
                            child: const TrText('登录'),
                          )
                        : TextButton(
                            onPressed: state.signOut,
                            child: const TrText('退出登录'),
                          ),
                  ),
                  if (!state.isNavidrome)
                    _LegacySettingRow(
                      label: '一起听',
                      subtitle: '和朋友同步听歌',
                      trailing: OutlinedButton(
                        onPressed: () =>
                            unawaited(showListenTogetherDialog(context, state)),
                        child: const TrText('打开'),
                      ),
                    ),
                  _LegacySettingRow(
                    label: '刷新曲库',
                    subtitle: '重新拉取首页、歌单和每日推荐',
                    trailing: OutlinedButton(
                      onPressed: () =>
                          unawaited(state.refreshHome(force: true)),
                      child: const TrText('刷新'),
                    ),
                  ),
                ],
              ),
            ),
            const _LegacySectionLabel('关于'),
            AppleGroupedCard(
              margin: EdgeInsets.zero,
              child: Column(
                children: <Widget>[
                  _VersionSecretTile(state: state),
                  AppleListTile(
                    key: const ValueKey('export-logs'),
                    title: context.tr('导出日志'),
                    subtitle: context.tr('保存运行日志与播放诊断信息'),
                    trailing: const Icon(Icons.file_download_outlined),
                    onTap: () => unawaited(exportLogs(context, state)),
                  ),
                  _LegacySettingRow(
                    label: '检查更新',
                    subtitle: '从 GitHub 获取最新版本',
                    trailing: state.updateChecking
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : OutlinedButton(
                            onPressed: () => unawaited(
                              checkUpdatesFromSettings(context, state),
                            ),
                            child: const TrText('检查更新'),
                          ),
                  ),
                  if (state.skippedUpdateVersion != null)
                    _LegacySettingRow(
                      label: context.tr('已跳过 v${state.skippedUpdateVersion}'),
                      subtitle: '自动提醒不再提示这个版本',
                      trailing: TextButton(
                        onPressed: () => unawaited(state.clearSkippedUpdate()),
                        child: const TrText('恢复提醒'),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LegacySectionLabel extends StatelessWidget {
  const _LegacySectionLabel(this.label);

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

class _LegacySettingRow extends StatelessWidget {
  const _LegacySettingRow({
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
                    flex: 9,
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

class _LegacySwitchRow extends StatelessWidget {
  const _LegacySwitchRow({
    super.key,
    required this.label,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final String subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    return _LegacySettingRow(
      label: label,
      subtitle: subtitle,
      trailing: Switch(value: value, onChanged: onChanged),
    );
  }
}

/// The 关于 version card doubles as the hidden switch for the debug section:
/// seven taps inside four seconds toggle it. The tap target is invisible, so
/// ordinary users only ever see an ordinary version row.
class _VersionSecretTile extends StatefulWidget {
  const _VersionSecretTile({required this.state});

  final AppState state;

  @override
  State<_VersionSecretTile> createState() => _VersionSecretTileState();
}

class _VersionSecretTileState extends State<_VersionSecretTile> {
  static const int _tapsToToggle = 7;
  static const Duration _window = Duration(seconds: 4);

  int _taps = 0;
  DateTime? _firstTap;

  void _tap() {
    final DateTime now = DateTime.now();
    final DateTime? first = _firstTap;
    if (first == null || now.difference(first) > _window) {
      _firstTap = now;
      _taps = 0;
    }
    if (++_taps < _tapsToToggle) return;
    _taps = 0;
    _firstTap = null;
    final bool enabled = !widget.state.debugOptionsEnabled;
    unawaited(widget.state.setDebugOptionsEnabled(enabled));
    final String message = enabled
        ? context.tr('调试选项已开启')
        : context.tr('调试选项已关闭');
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppleSemanticColors apple = AppleSemanticColors.of(context);
    return AppleListTile(
      title: 'Lazer',
      subtitle: context.tr('提交 ${BuildInfo.shortCommit}'),
      onTap: _tap,
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(7),
        child: Image.asset(
          'assets/app_icon.png',
          width: 30,
          height: 30,
          fit: BoxFit.cover,
        ),
      ),
      trailing: Text(
        BuildInfo.displayVersion,
        style: theme.textTheme.bodyMedium?.copyWith(
          color: apple.secondaryLabel,
          fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}

/// Debug-only panel listing the current audio endpoints and the session
/// attributes the player asked the platform for.
Future<void> showAudioDeviceInfoDialog(BuildContext context) =>
    showDialog<void>(
      context: context,
      builder: (BuildContext context) => const _AudioDeviceDialog(),
    );

class _AudioDeviceDialog extends StatefulWidget {
  const _AudioDeviceDialog();

  @override
  State<_AudioDeviceDialog> createState() => _AudioDeviceDialogState();
}

class _AudioDeviceDialogState extends State<_AudioDeviceDialog> {
  late Future<AudioDeviceReport> _report = AudioDeviceReport.collect();

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const TrText('音频设备'),
      contentPadding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
      content: SizedBox(
        width: 420,
        child: FutureBuilder<AudioDeviceReport>(
          future: _report,
          builder:
              (
                BuildContext context,
                AsyncSnapshot<AudioDeviceReport> snapshot,
              ) {
                if (snapshot.connectionState != ConnectionState.done) {
                  return const SizedBox(
                    height: 120,
                    child: Center(child: CircularProgressIndicator()),
                  );
                }
                return _body(context, snapshot.data);
              },
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => setState(() {
            _report = AudioDeviceReport.collect();
          }),
          child: const TrText('刷新'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const TrText('完成'),
        ),
      ],
    );
  }

  Widget _body(BuildContext context, AudioDeviceReport? report) {
    final ThemeData theme = Theme.of(context);
    final AppleSemanticColors apple = AppleSemanticColors.of(context);
    final TextStyle labelStyle =
        theme.textTheme.bodyMedium?.copyWith(color: apple.label) ??
        const TextStyle();
    final TextStyle valueStyle =
        theme.textTheme.bodySmall?.copyWith(color: apple.secondaryLabel) ??
        const TextStyle();
    final List<Widget> children = <Widget>[];
    if (report == null) {
      children.add(Text(context.tr('读取音频设备失败。'), style: valueStyle));
    } else {
      for (final AudioSessionAttribute attribute in report.attributes) {
        children.add(
          Padding(
            padding: const EdgeInsets.only(bottom: 3),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                SizedBox(
                  width: 84,
                  child: Text(context.tr(attribute.label), style: valueStyle),
                ),
                Expanded(child: Text(attribute.value, style: valueStyle)),
              ],
            ),
          ),
        );
      }
      if (report.error != null) {
        children.add(
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              context.tr('读取失败：${report.error}'),
              style: valueStyle.copyWith(
                color: Theme.of(context).colorScheme.error,
              ),
            ),
          ),
        );
      }
      if (report.outputs.isEmpty) {
        if (report.error == null) {
          children.add(
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                context.tr('当前平台不支持读取音频设备（仅 Android 与 iOS 支持）。'),
                style: valueStyle,
              ),
            ),
          );
        }
      } else {
        children.add(
          Padding(
            padding: const EdgeInsets.only(top: 10, bottom: 6),
            child: Text(
              context.tr('可用输出设备（${report.outputs.length}）'),
              style: labelStyle,
            ),
          ),
        );
        for (final AudioDeviceInfo device in report.outputs) {
          children.add(
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(device.name, style: labelStyle),
                  const SizedBox(height: 1),
                  Text(context.tr(device.typeLabel), style: valueStyle),
                  Text(
                    context.tr('ID：${device.id}'),
                    style: valueStyle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          );
        }
      }
    }
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 360),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: children,
        ),
      ),
    );
  }
}

class _LegacySliderRow extends StatelessWidget {
  const _LegacySliderRow({
    super.key,
    required this.label,
    required this.valueText,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.subtitle,
    this.divisions,
    this.action,
  });

  final String label;
  final String valueText;
  final String? subtitle;
  final double value;
  final double min;
  final double max;
  final int? divisions;
  final ValueChanged<double>? onChanged;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppleSemanticColors apple = AppleSemanticColors.of(context);
    return TvFocusHighlight(
      borderRadius: BorderRadius.circular(10),
      child: Container(
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: apple.separator, width: .5)),
        ),
        padding: const EdgeInsets.fromLTRB(16, 13, 12, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    context.tr(label),
                    style: theme.textTheme.bodyLarge?.copyWith(
                      color: apple.label,
                    ),
                  ),
                ),
                if (action != null) ...<Widget>[
                  action!,
                  const SizedBox(width: 4),
                ],
                Text(
                  context.tr(valueText),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: apple.secondaryLabel,
                    fontFeatures: const <FontFeature>[
                      FontFeature.tabularFigures(),
                    ],
                  ),
                ),
              ],
            ),
            if (subtitle != null) ...<Widget>[
              const SizedBox(height: 2),
              Text(
                context.tr(subtitle!),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: apple.secondaryLabel,
                ),
              ),
            ],
            AccessibleSlider(
              semanticLabel: label,
              label: valueText,
              value: value.clamp(min, max),
              min: min,
              max: max,
              divisions: divisions,
              detentFeedback: onChanged != null,
              onChanged: onChanged,
            ),
          ],
        ),
      ),
    );
  }
}

/// `#RRGGBB` label shown beside the custom accent swatch.
String _accentHex(Color color) =>
    '#${((color.toARGB32() & 0xFFFFFF).toRadixString(16)).padLeft(6, '0').toUpperCase()}';

/// Opens the custom-accent picker and persists the chosen colour.
Future<void> _pickLegacyAccent(BuildContext context, AppState state) async {
  final Color initial = state.legacyAccentColor ?? AppleColors.musicRed;
  final Color? picked = await showDialog<Color>(
    context: context,
    builder: (BuildContext context) => _LegacyAccentDialog(initial: initial),
  );
  if (picked != null) await state.setLegacyAccent(picked);
}

/// Picks a picture, stores a copy and switches the backdrop to it.
Future<void> _pickBackgroundImage(
  BuildContext context,
  AppState state, [
  Future<String?> Function()? picker,
  bool player = false,
]) async {
  String? stored;
  try {
    stored = await (picker ?? pickCustomBackgroundImage)();
  } catch (_) {
    // No picker on this platform, or the copy failed; leave the setting as is.
    return;
  }
  if (stored == null) return;
  final String? previous = player
      ? state.playerBackgroundImagePath
      : state.legacyBackgroundImagePath;
  if (player) {
    await state.setPlayerBackgroundImage(stored);
    await state.setPlayerBackground(LegacyBackgroundMode.customImage);
  } else {
    await state.setLegacyBackgroundImage(stored);
    await state.setLegacyBackground(LegacyBackgroundMode.customImage);
  }
  if (previous != stored &&
      previous != state.playerBackgroundImagePath &&
      previous != state.legacyBackgroundImagePath) {
    await deleteCustomBackgroundImage(previous);
  }
}

class _BackgroundPreferences extends StatelessWidget {
  const _BackgroundPreferences({
    required this.state,
    required this.player,
    this.picker,
  });
  final AppState state;
  final bool player;
  final Future<String?> Function()? picker;

  @override
  Widget build(BuildContext context) {
    final mode = player ? state.playerBackground : state.legacyBackground;
    final double reported = View.of(context).display.refreshRate;
    final double refresh = (reported.isFinite && reported > 0 ? reported : 60.0)
        .clamp(10, 1000);
    final double stored = player
        ? state.playerBackgroundFps
        : state.browseBackgroundFps;
    final double shown = (stored == 0 ? refresh : stored).clamp(10, refresh);
    final color = player
        ? state.playerBackgroundColor
        : state.browseBackgroundColor;
    return Column(
      children: [
        if (player)
          _LegacySettingRow(
            label: '正在播放页面',
            subtitle: mode.detail,
            trailing: SettingsChoice<LegacyBackgroundMode>(
              key: const ValueKey('player-background-mode'),
              value: mode,
              items: [
                for (final option in LegacyBackgroundMode.values)
                  DropdownMenuItem(value: option, child: TrText(option.label)),
              ],
              onChanged: (value) {
                if (value == null) return;
                unawaited(state.setPlayerBackground(value));
                if (value == LegacyBackgroundMode.customImage &&
                    state.playerBackgroundImagePath == null) {
                  unawaited(_pickBackgroundImage(context, state, picker, true));
                }
              },
            ),
          ),
        if (player && mode == LegacyBackgroundMode.customImage)
          _LegacySettingRow(
            label: '背景图片',
            subtitle: '正在播放页面的背景图片',
            trailing: Wrap(
              spacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (state.playerBackgroundImagePath != null)
                  TextButton(
                    key: const ValueKey('player-background-image-clear'),
                    onPressed: () async {
                      final path = state.playerBackgroundImagePath;
                      await state.setPlayerBackgroundImage(null);
                      await state.setPlayerBackground(LegacyBackgroundMode.off);
                      if (path != state.legacyBackgroundImagePath) {
                        await deleteCustomBackgroundImage(path);
                      }
                    },
                    child: const TrText('移除'),
                  ),
                OutlinedButton(
                  key: const ValueKey('player-background-image-pick'),
                  onPressed: () => unawaited(
                    _pickBackgroundImage(context, state, picker, true),
                  ),
                  child: TrText(
                    state.playerBackgroundImagePath == null ? '选择图片' : '更换',
                  ),
                ),
              ],
            ),
          ),
        if (mode == LegacyBackgroundMode.solidColor)
          _LegacySettingRow(
            label: '背景颜色',
            subtitle: color == null ? '根据主题色生成' : '自定义',
            trailing: Wrap(
              spacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                TextButton(
                  onPressed: () =>
                      unawaited(state.setBackgroundColor(null, player: player)),
                  child: const TrText('跟随主题色'),
                ),
                _LegacyAccentSwatch(
                  color: color ?? Theme.of(context).colorScheme.primary,
                  onTap: () async {
                    final chosen = await showDialog<Color>(
                      context: context,
                      builder: (_) => _LegacyAccentDialog(
                        initial: color ?? Theme.of(context).colorScheme.primary,
                      ),
                    );
                    if (chosen != null) {
                      await state.setBackgroundColor(chosen, player: player);
                    }
                  },
                ),
              ],
            ),
          ),
        if (player)
          _LegacySwitchRow(
            key: const ValueKey('player-background-follow-display'),
            label: '跟随屏幕刷新率',
            subtitle: '播放背景按当前屏幕刷新率运行',
            value: stored == 0,
            onChanged: mode == LegacyBackgroundMode.nowPlayingDynamic
                ? (value) => unawaited(
                    state.setBackgroundFps(value ? 0 : refresh, player: true),
                  )
                : null,
          ),
        _LegacySliderRow(
          key: ValueKey(
            player ? 'player-background-fps' : 'browse-background-fps',
          ),
          label: player ? '播放背景帧率' : '浏览背景帧率',
          valueText: '${shown.round()} fps',
          value: shown,
          min: 10,
          max: refresh,
          divisions: (refresh - 10).round().clamp(1, 990),
          subtitle: player ? '最低 10fps；关闭跟随屏幕后可手动调节' : '默认 30fps，仅影响其他页面的动态背景',
          onChanged:
              mode != LegacyBackgroundMode.nowPlayingDynamic ||
                  (player && stored == 0)
              ? null
              : (value) =>
                    unawaited(state.setBackgroundFps(value, player: player)),
        ),
        if (player)
          _LegacySliderRow(
            key: const ValueKey('player-background-quality'),
            label: '播放背景渲染精度',
            valueText: '${(state.playerBackgroundQuality * 100).round()}%',
            value: state.playerBackgroundQuality,
            min: .1,
            max: 1,
            divisions: 18,
            onChanged:
                mode == LegacyBackgroundMode.nowPlayingDynamic ||
                    mode == LegacyBackgroundMode.nowPlayingStatic
                ? (value) => unawaited(state.setPlayerBackgroundQuality(value))
                : null,
          ),
      ],
    );
  }
}

/// Opens the key recorder for [action] and persists the chosen combination.
class _LegacyAccentSwatch extends StatelessWidget {
  const _LegacyAccentSwatch({
    super.key,
    required this.color,
    required this.onTap,
  });

  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final AppleSemanticColors apple = AppleSemanticColors.of(context);
    return Semantics(
      button: true,
      label: context.tr('选择强调色'),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: TvTapTarget(
          onTap: onTap,
          borderRadius: BorderRadius.circular(15),
          focusScale: 1.12,
          child: GestureDetector(
            onTap: onTap,
            child: Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
                border: Border.all(color: apple.separator, width: .75),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Hue/saturation/value picker for the custom accent.
class _LegacyAccentDialog extends StatefulWidget {
  const _LegacyAccentDialog({required this.initial});

  final Color initial;

  @override
  State<_LegacyAccentDialog> createState() => _LegacyAccentDialogState();
}

class _LegacyAccentDialogState extends State<_LegacyAccentDialog> {
  static const List<Color> _presets = <Color>[
    AppleColors.musicRed,
    AppleColors.systemPink,
    AppleColors.systemPurple,
    AppleColors.systemBlue,
    AppleColors.systemTeal,
    AppleColors.systemGreen,
    AppleColors.systemOrange,
    AppleColors.systemYellow,
  ];

  late HSVColor _hsv = HSVColor.fromColor(widget.initial);

  Color get _color => _hsv.toColor();

  void _selectPreset(Color color) =>
      setState(() => _hsv = HSVColor.fromColor(color));

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppleSemanticColors apple = AppleSemanticColors.of(context);
    return AlertDialog(
      title: const TrText('自定义主题色'),
      content: SizedBox(
        width: 320,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Container(
                height: 54,
                decoration: BoxDecoration(
                  color: _color,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: apple.separator, width: .5),
                ),
              ),
              const SizedBox(height: 14),
              for (int row = 0; row < 2; row++) ...<Widget>[
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: <Widget>[
                    for (final Color preset in _presets.skip(row * 4).take(4))
                      _LegacyPresetSwatch(
                        color: preset,
                        selected: preset.toARGB32() == _color.toARGB32(),
                        onTap: () => _selectPreset(preset),
                      ),
                  ],
                ),
                if (row == 0) const SizedBox(height: 10),
              ],
              _LegacyGradientSlider(
                label: '色相',
                value: _hsv.hue,
                max: 360,
                colors: const <Color>[
                  Color(0xFFFF0000),
                  Color(0xFFFFFF00),
                  Color(0xFF00FF00),
                  Color(0xFF00FFFF),
                  Color(0xFF0000FF),
                  Color(0xFFFF00FF),
                  Color(0xFFFF0000),
                ],
                onChanged: (double value) =>
                    setState(() => _hsv = _hsv.withHue(value)),
              ),
              _LegacyGradientSlider(
                label: '饱和度',
                value: _hsv.saturation,
                colors: <Color>[
                  Colors.white,
                  HSVColor.fromAHSV(1, _hsv.hue, 1, 1).toColor(),
                ],
                onChanged: (double value) =>
                    setState(() => _hsv = _hsv.withSaturation(value)),
              ),
              _LegacyGradientSlider(
                label: '明度',
                value: _hsv.value,
                colors: <Color>[
                  Colors.black,
                  HSVColor.fromAHSV(1, _hsv.hue, _hsv.saturation, 1).toColor(),
                ],
                onChanged: (double value) =>
                    setState(() => _hsv = _hsv.withValue(value)),
              ),
              const SizedBox(height: 4),
              Text(
                _accentHex(_color),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: apple.secondaryLabel,
                  fontFeatures: const <FontFeature>[
                    FontFeature.tabularFigures(),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const TrText('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_color),
          child: const TrText('完成'),
        ),
      ],
    );
  }
}

class _LegacyPresetSwatch extends StatelessWidget {
  const _LegacyPresetSwatch({
    required this.color,
    required this.selected,
    required this.onTap,
  });

  final Color color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final AppleSemanticColors apple = AppleSemanticColors.of(context);
    final Color check =
        ThemeData.estimateBrightnessForColor(color) == Brightness.dark
        ? Colors.white
        : Colors.black;
    return Semantics(
      button: true,
      selected: selected,
      child: InkResponse(
        onTap: onTap,
        radius: 20,
        child: Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: Border.all(
              color: selected ? apple.label : apple.separator,
              width: selected ? 2 : .5,
            ),
          ),
          child: selected
              ? Icon(Icons.check_rounded, size: 18, color: check)
              : null,
        ),
      ),
    );
  }
}

/// A slider painted over its own gradient track.
class _LegacyGradientSlider extends StatelessWidget {
  const _LegacyGradientSlider({
    required this.label,
    required this.value,
    required this.colors,
    required this.onChanged,
    this.max = 1,
  });

  final String label;
  final double value;
  final double max;
  final List<Color> colors;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppleSemanticColors apple = AppleSemanticColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            context.tr(label),
            style: theme.textTheme.labelMedium?.copyWith(
              color: apple.secondaryLabel,
            ),
          ),
          SizedBox(
            height: 40,
            child: Stack(
              alignment: Alignment.center,
              children: <Widget>[
                Positioned(
                  left: 0,
                  right: 0,
                  child: Container(
                    height: 14,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(colors: colors),
                      borderRadius: BorderRadius.circular(7),
                      border: Border.all(color: apple.separator, width: .5),
                    ),
                  ),
                ),
                SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 14,
                    activeTrackColor: Colors.transparent,
                    inactiveTrackColor: Colors.transparent,
                    secondaryActiveTrackColor: Colors.transparent,
                    thumbColor: Colors.white,
                    overlayColor: Colors.white.withValues(alpha: .18),
                    overlayShape: const RoundSliderOverlayShape(
                      overlayRadius: 18,
                    ),
                    thumbShape: const RoundSliderThumbShape(
                      enabledThumbRadius: 9,
                      elevation: 2,
                    ),
                    tickMarkShape: SliderTickMarkShape.noTickMark,
                  ),
                  child: SemanticsPortal(
                    child: Slider(
                      value: value.clamp(0, max),
                      min: 0,
                      max: max,
                      onChanged: onChanged,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
