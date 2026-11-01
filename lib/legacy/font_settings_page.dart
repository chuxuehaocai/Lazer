import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../state/app_state.dart';
import '../theme/apple_design.dart';
import '../theme/font_preferences.dart';
import '../widgets/accessible_controls.dart';
import '../widgets/apple_ui.dart';
import '../widgets/settings_detail.dart';

class FontSettingsPage extends StatelessWidget {
  const FontSettingsPage({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) => FontSettingsView(state: state);
}

class FontSettingsView extends StatelessWidget {
  const FontSettingsView({super.key, required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: state,
    builder: (context, _) => Theme(
      data: buildAppleTheme(
        brightness: Theme.of(context).brightness,
        seedAccent: state.legacyAccentSeed,
        fonts: state.fontPreferences,
      ),
      child: Builder(
        builder: (context) => SettingsDetailScaffold(
          title: '字体自定义',
          actions: [
            TextButton(
              key: const ValueKey('reset-all-fonts'),
              onPressed: () => unawaited(state.resetFonts()),
              child: const TrText('恢复默认'),
            ),
          ],
          child: Builder(
            builder: (context) {
              final desktop = SettingsDetailHost.isEmbedded(context);
              final cards = <Widget>[
                for (final category in FontCategory.values)
                  _FontCard(
                    key: ValueKey('font-card-${category.name}'),
                    desktop: desktop,
                    label: category.label,
                    detail: category.detail,
                    sample: category == FontCategory.playerArtist
                        ? 'Lazer · Artist'
                        : 'Lazer · 音乐与生活',
                    style: state.fontPreferences.apply(
                      category,
                      _sampleStyle(category),
                    ),
                    value: state.fontPreferences[category].scale,
                    valueText:
                        '${(state.fontPreferences[category].scale * 100).round()}%',
                    min: .75,
                    max: 1.6,
                    divisions: 17,
                    weight: state.fontPreferences[category].weight,
                    onSize: (value) => unawaited(
                      state.setFontCustomization(
                        category,
                        FontCustomization(
                          scale: value,
                          weight: state.fontPreferences[category].weight,
                        ),
                      ),
                    ),
                    onWeight: (value) => unawaited(
                      state.setFontCustomization(
                        category,
                        FontCustomization(
                          scale: state.fontPreferences[category].scale,
                          weight: value,
                        ),
                      ),
                    ),
                    onReset: () =>
                        unawaited(state.setFontCustomization(category, null)),
                  ),
                _FontCard(
                  key: const ValueKey('font-card-lyrics'),
                  desktop: desktop,
                  label: '歌词',
                  detail: '正在播放页面的歌词',
                  sample: '让音乐陪伴每一个瞬间',
                  style: TextStyle(
                    fontSize: state.lyricFontSize,
                    fontWeight:
                        FontWeight.values[state.lyricFontWeight ~/ 100 - 1],
                  ),
                  value: state.lyricFontSize,
                  valueText: '${state.lyricFontSize.round()} px',
                  min: 14,
                  max: 40,
                  divisions: 26,
                  weight: state.lyricFontWeight,
                  onSize: (value) => unawaited(state.setLyricFontSize(value)),
                  onWeight: (value) =>
                      unawaited(state.setLyricFontWeight(value ?? 600)),
                  onReset: () {
                    unawaited(state.setLyricFontSize(22));
                    unawaited(state.setLyricFontWeight(600));
                  },
                ),
              ];
              return LayoutBuilder(
                builder: (context, constraints) {
                  final width = constraints.maxWidth.clamp(
                    0.0,
                    desktop ? 1000.0 : 760.0,
                  );
                  final twoColumns = desktop && width >= 700;
                  final cardWidth = (width - 56) / 2;
                  return Center(
                    child: SizedBox(
                      width: width,
                      child: ListView(
                        padding: const EdgeInsets.fromLTRB(20, 12, 20, 36),
                        children: [
                          _FontFamilyCard(state: state),
                          const SizedBox(height: 16),
                          const Padding(
                            padding: EdgeInsets.only(bottom: 16),
                            child: TrText('按文字用途调节大小和粗细，修改即时生效。'),
                          ),
                          if (twoColumns)
                            Wrap(
                              spacing: 16,
                              runSpacing: 16,
                              children: [
                                for (final card in cards)
                                  SizedBox(width: cardWidth, child: card),
                              ],
                            )
                          else
                            for (final card in cards)
                              Padding(
                                padding: EdgeInsets.only(
                                  bottom: desktop ? 16 : 0,
                                ),
                                child: card,
                              ),
                        ],
                      ),
                    ),
                  );
                },
              );
            },
          ),
        ),
      ),
    ),
  );

  TextStyle _sampleStyle(FontCategory category) => TextStyle(
    fontSize: switch (category) {
      FontCategory.pageTitle => 34,
      FontCategory.title => 20,
      FontCategory.body => 17,
      FontCategory.caption => 13,
      FontCategory.controls => 15,
      FontCategory.playerTitle => 24,
      FontCategory.playerArtist => 17,
    },
    fontWeight: switch (category) {
      FontCategory.pageTitle => FontWeight.w700,
      FontCategory.title || FontCategory.playerTitle => FontWeight.w600,
      FontCategory.controls => FontWeight.w500,
      _ => FontWeight.w400,
    },
  );
}

class _FontFamilyCard extends StatefulWidget {
  const _FontFamilyCard({required this.state});
  final AppState state;

  @override
  State<_FontFamilyCard> createState() => _FontFamilyCardState();
}

class _FontFamilyCardState extends State<_FontFamilyCard> {
  bool _busy = false;

  void _showImportError() {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(context.tr('字体导入失败，请选择有效的 OTF 或 TTF 字体文件'))),
    );
  }

  Future<void> _select(FontFamilyPreference family) async {
    setState(() => _busy = true);
    try {
      await widget.state.setFontFamily(family);
    } catch (_) {
      _showImportError();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _import() async {
    setState(() => _busy = true);
    try {
      final file = await openFile(
        acceptedTypeGroups: const [
          XTypeGroup(
            label: 'OTF / TTF',
            extensions: ['otf', 'ttf'],
            mimeTypes: [
              'font/ttf',
              'font/otf',
              'application/x-font-ttf',
              'application/x-font-opentype',
              'application/vnd.ms-opentype',
            ],
            uniformTypeIdentifiers: ['public.font'],
          ),
        ],
      );
      if (file == null) return;
      await widget.state.importFont(await file.readAsBytes(), file.name);
    } catch (_) {
      _showImportError();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final family = widget.state.fontPreferences.family;
    return AppleGroupedCard(
      key: const ValueKey('font-family-card'),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TrText('字体', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 6),
            const TrText('选择自带字体、系统字体，或导入自己的字体文件。'),
            const SizedBox(height: 8),
            DropdownButton<FontSource>(
              key: const ValueKey('font-family-selector'),
              isExpanded: true,
              value: family.source,
              items: [
                const DropdownMenuItem(
                  value: FontSource.miSans,
                  child: TrText('MiSans（自带）'),
                ),
                const DropdownMenuItem(
                  value: FontSource.system,
                  child: TrText('系统字体'),
                ),
                if (family.path != null)
                  DropdownMenuItem(
                    value: FontSource.imported,
                    child: Text(
                      family.name ?? context.tr('导入字体'),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: _busy
                  ? null
                  : (source) {
                      if (source == null) return;
                      unawaited(_select(family.withSource(source)));
                    },
            ),
            TextButton.icon(
              key: const ValueKey('import-custom-font'),
              onPressed: _busy ? null : _import,
              icon: const Icon(Icons.font_download_outlined),
              label: TrText(_busy ? '正在导入字体…' : '导入 OTF / TTF 字体'),
            ),
          ],
        ),
      ),
    );
  }
}

class _FontCard extends StatelessWidget {
  const _FontCard({
    super.key,
    required this.desktop,
    required this.label,
    required this.detail,
    required this.sample,
    required this.style,
    required this.value,
    required this.valueText,
    required this.min,
    required this.max,
    required this.divisions,
    required this.weight,
    required this.onSize,
    required this.onWeight,
    required this.onReset,
  });

  final String label, detail, sample, valueText;
  final bool desktop;
  final TextStyle style;
  final double value, min, max;
  final int divisions;
  final int? weight;
  final ValueChanged<double> onSize;
  final ValueChanged<int?> onWeight;
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) => AppleGroupedCard(
    margin: desktop
        ? EdgeInsets.zero
        : const EdgeInsets.symmetric(horizontal: 24),
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: TrText(
                  label,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              TextButton(onPressed: onReset, child: const TrText('恢复默认')),
            ],
          ),
          TrText(detail, style: Theme.of(context).textTheme.bodySmall),
          Padding(
            padding: EdgeInsets.symmetric(vertical: desktop ? 12 : 20),
            child: Text(
              context.tr(sample),
              style: style,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Row(
            children: [
              const Expanded(child: TrText('字号')),
              Text(valueText),
            ],
          ),
          AccessibleSlider(
            semanticLabel: context
                .tr('调节字号：{label}')
                .replaceAll('{label}', context.tr(label)),
            value: value,
            min: min,
            max: max,
            divisions: divisions,
            label: valueText,
            onChanged: onSize,
          ),
          Row(
            children: [
              const Expanded(child: TrText('字体粗细')),
              DropdownButton<int>(
                value: weight ?? 0,
                underline: const SizedBox.shrink(),
                items: [
                  const DropdownMenuItem(value: 0, child: TrText('默认')),
                  for (final entry in const {
                    400: '常规',
                    500: '中等',
                    600: '半粗',
                    700: '粗体',
                  }.entries)
                    DropdownMenuItem(
                      value: entry.key,
                      child: Text(
                        context.tr(entry.value),
                        style: TextStyle(
                          fontWeight: FontWeight.values[entry.key ~/ 100 - 1],
                        ),
                      ),
                    ),
                ],
                onChanged: (value) => onWeight(value == 0 ? null : value),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}
