import 'dart:convert';

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';

enum FontSource { miSans, system, imported }

@immutable
class FontFamilyPreference {
  const FontFamilyPreference({
    this.source = FontSource.miSans,
    this.name,
    this.path,
    this.family,
  });

  final FontSource source;
  final String? name, path, family;

  FontFamilyPreference withSource(FontSource value) => FontFamilyPreference(
    source: value,
    name: name,
    path: path,
    family: family,
  );

  String get resolvedFamily => switch (source) {
    FontSource.miSans => 'MiSans',
    FontSource.imported => family ?? 'MiSans',
    FontSource.system => switch (defaultTargetPlatform) {
      TargetPlatform.windows => 'Segoe UI',
      TargetPlatform.iOS || TargetPlatform.macOS => '.AppleSystemUIFont',
      TargetPlatform.android || TargetPlatform.fuchsia => 'sans-serif',
      TargetPlatform.linux => 'sans-serif',
    },
  };

  List<String> fallbackFor(List<String> defaults) =>
      source == FontSource.system ? const [] : defaults;

  String get label => switch (source) {
    FontSource.miSans => 'MiSans（自带）',
    FontSource.system => '系统字体',
    FontSource.imported => name ?? '导入字体',
  };

  Map<String, Object?> toMap() => {
    'source': source.name,
    'name': name,
    'path': path,
    'family': family,
  };

  factory FontFamilyPreference.fromMap(Map<String, dynamic> value) {
    final source = FontSource.values
        .where((source) => source.name == value['source'])
        .firstOrNull;
    if (source == null ||
        (source == FontSource.imported &&
            (value['path'] is! String || value['family'] is! String))) {
      return const FontFamilyPreference();
    }
    return FontFamilyPreference(
      source: source,
      name: value['name'] as String?,
      path: value['path'] as String?,
      family: value['family'] as String?,
    );
  }
}

enum FontCategory {
  pageTitle,
  title,
  body,
  caption,
  controls,
  playerTitle,
  playerArtist,
}

extension FontCategoryLabels on FontCategory {
  String get label => switch (this) {
    FontCategory.pageTitle => '页面大标题',
    FontCategory.title => '列表与卡片标题',
    FontCategory.body => '正文与设置',
    FontCategory.caption => '辅助文字',
    FontCategory.controls => '按钮与导航',
    FontCategory.playerTitle => '正在播放歌曲标题',
    FontCategory.playerArtist => '正在播放歌手与专辑',
  };

  String get detail => switch (this) {
    FontCategory.pageTitle => '首页、资料库、搜索与设置的页面标题',
    FontCategory.title => '歌曲列表、歌单、专辑和弹窗标题',
    FontCategory.body => '页面正文、设置项目和评论',
    FontCategory.caption => '说明、时间和次要信息',
    FontCategory.controls => '按钮、标签和导航文字',
    FontCategory.playerTitle => '正在播放页面与紧凑歌曲区域的标题',
    FontCategory.playerArtist => '正在播放页面与紧凑歌曲区域的歌手和专辑',
  };
}

@immutable
class FontCustomization {
  const FontCustomization({this.scale = 1, this.weight});

  final double scale;
  final int? weight;

  factory FontCustomization.fromMap(Map<String, dynamic> map) {
    final num? scale = map['scale'] is num ? map['scale'] as num : null;
    final num? weight = map['weight'] is num ? map['weight'] as num : null;
    return FontCustomization(
      scale: normalizeScale(scale?.toDouble() ?? 1),
      weight: weight == null ? null : normalizeWeight(weight.toInt()),
    );
  }

  static double normalizeScale(double value) =>
      value.isFinite ? (value.clamp(.75, 1.6) * 100).round() / 100 : 1;

  static int normalizeWeight(int value) =>
      (value.clamp(400, 700) / 100).round() * 100;

  TextStyle apply(TextStyle style) => style.copyWith(
    fontSize: style.fontSize == null ? null : style.fontSize! * scale,
    fontWeight: weight == null ? null : FontWeight.values[weight! ~/ 100 - 1],
  );

  Map<String, Object?> toMap() => <String, Object?>{
    'scale': scale,
    'weight': weight,
  };

  @override
  bool operator ==(Object other) =>
      other is FontCustomization &&
      scale == other.scale &&
      weight == other.weight;

  @override
  int get hashCode => Object.hash(scale, weight);
}

@immutable
class FontPreferences extends ThemeExtension<FontPreferences> {
  const FontPreferences([
    this._values = const <FontCategory, FontCustomization>{},
    this.family = const FontFamilyPreference(),
  ]);

  final Map<FontCategory, FontCustomization> _values;
  final FontFamilyPreference family;

  FontPreferences withFamily(FontFamilyPreference value) =>
      FontPreferences(_values, value);

  FontCustomization operator [](FontCategory category) =>
      _values[category] ?? const FontCustomization();

  TextStyle apply(FontCategory category, TextStyle style) => this[category]
      .apply(style)
      .copyWith(
        fontFamily: family.resolvedFamily,
        fontFamilyFallback: family.fallbackFor(
          style.fontFamilyFallback ?? const [],
        ),
      );

  FontWeight weightFor(FontCategory category, FontWeight fallback) =>
      this[category].weight == null
      ? fallback
      : FontWeight.values[this[category].weight! ~/ 100 - 1];

  FontPreferences update(FontCategory category, FontCustomization? value) {
    final values = Map<FontCategory, FontCustomization>.of(_values);
    if (value == null || value == const FontCustomization()) {
      values.remove(category);
    } else {
      values[category] = value;
    }
    return FontPreferences(Map.unmodifiable(values), family);
  }

  TextTheme applyTo(TextTheme text) {
    TextStyle? s(FontCategory category, TextStyle? style) =>
        style == null ? null : apply(category, style);
    return text.copyWith(
      displayLarge: s(FontCategory.pageTitle, text.displayLarge),
      displayMedium: s(FontCategory.pageTitle, text.displayMedium),
      displaySmall: s(FontCategory.pageTitle, text.displaySmall),
      headlineLarge: s(FontCategory.pageTitle, text.headlineLarge),
      headlineMedium: s(FontCategory.title, text.headlineMedium),
      headlineSmall: s(FontCategory.title, text.headlineSmall),
      titleLarge: s(FontCategory.title, text.titleLarge),
      titleMedium: s(FontCategory.title, text.titleMedium),
      titleSmall: s(FontCategory.title, text.titleSmall),
      bodyLarge: s(FontCategory.body, text.bodyLarge),
      bodyMedium: s(FontCategory.body, text.bodyMedium),
      bodySmall: s(FontCategory.caption, text.bodySmall),
      labelLarge: s(FontCategory.controls, text.labelLarge),
      labelMedium: s(FontCategory.controls, text.labelMedium),
      labelSmall: s(FontCategory.controls, text.labelSmall),
    );
  }

  String encode() => jsonEncode(<String, Object?>{
    '_family': family.toMap(),
    for (final entry in _values.entries) entry.key.name: entry.value.toMap(),
  });

  static FontPreferences decode(String? source) {
    if (source == null) return const FontPreferences();
    try {
      final decoded = jsonDecode(source);
      if (decoded is! Map<String, dynamic>) return const FontPreferences();
      final values = <FontCategory, FontCustomization>{};
      for (final category in FontCategory.values) {
        final value = decoded[category.name];
        if (value is Map<String, dynamic>) {
          values[category] = FontCustomization.fromMap(value);
        }
      }
      final family = decoded['_family'];
      return FontPreferences(
        Map.unmodifiable(values),
        family is Map<String, dynamic>
            ? FontFamilyPreference.fromMap(family)
            : const FontFamilyPreference(),
      );
    } catch (_) {
      return const FontPreferences();
    }
  }

  @override
  FontPreferences copyWith() => FontPreferences(_values, family);

  @override
  FontPreferences lerp(covariant FontPreferences? other, double t) =>
      other == null || t < .5 ? this : other;
}

extension FontPreferencesContext on BuildContext {
  FontPreferences get fonts =>
      Theme.of(this).extension<FontPreferences>() ?? const FontPreferences();
}
