import 'package:flutter/material.dart';

/// Declarative style tokens shared by the built-in widgets.
///
/// A Lua skin will eventually provide the same JSON-shaped values. It never
/// receives a Flutter context or a Widget callback; the host remains in charge
/// of accessibility, focus, hit testing and platform-specific rendering.
@immutable
class LazerThemeTokens extends ThemeExtension<LazerThemeTokens> {
  const LazerThemeTokens({
    this.id = 'builtin.apple',
    this.name = 'Apple',
    this.version = 1,
    this.groupedCardRadius = 14,
    this.listTileMinHeight = 50,
    this.listTileVerticalPadding = 11,
    this.pageTitleCompactSize = 34,
    this.pageTitleRegularSize = 32,
    this.sectionHeaderSize = 20,
    this.controlRadius = 12,
    this.glassBlurSigma = 16,
  });

  final String id;
  final String name;
  final int version;
  final double groupedCardRadius;
  final double listTileMinHeight;
  final double listTileVerticalPadding;
  final double pageTitleCompactSize;
  final double pageTitleRegularSize;
  final double sectionHeaderSize;
  final double controlRadius;
  final double glassBlurSigma;

  static const LazerThemeTokens apple = LazerThemeTokens();

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'name': name,
    'version': version,
    'elements': <String, Object?>{
      'groupedCardRadius': groupedCardRadius,
      'listTileMinHeight': listTileMinHeight,
      'listTileVerticalPadding': listTileVerticalPadding,
      'pageTitleCompactSize': pageTitleCompactSize,
      'pageTitleRegularSize': pageTitleRegularSize,
      'sectionHeaderSize': sectionHeaderSize,
      'controlRadius': controlRadius,
      'glassBlurSigma': glassBlurSigma,
    },
  };

  factory LazerThemeTokens.fromJson(Map<String, Object?> json) {
    final rawElements = json['elements'];
    final elements = rawElements is Map
        ? <String, Object?>{
            for (final entry in rawElements.entries)
              if (entry.key is String) entry.key as String: entry.value,
          }
        : const <String, Object?>{};
    String text(Object? value, String fallback) =>
        value is String && value.trim().isNotEmpty ? value.trim() : fallback;
    double number(
      String key,
      double fallback, {
      double min = 0,
      double max = 200,
    }) {
      final value = elements[key] is num
          ? (elements[key]! as num).toDouble()
          : fallback;
      return value.isFinite ? value.clamp(min, max) : fallback;
    }

    return LazerThemeTokens(
      id: text(json['id'], 'custom.unnamed'),
      name: text(json['name'], 'Custom'),
      version: json['version'] is num ? (json['version']! as num).toInt() : 1,
      groupedCardRadius: number('groupedCardRadius', 14, max: 40),
      listTileMinHeight: number('listTileMinHeight', 50, max: 160),
      listTileVerticalPadding: number('listTileVerticalPadding', 11, max: 48),
      pageTitleCompactSize: number('pageTitleCompactSize', 34, max: 72),
      pageTitleRegularSize: number('pageTitleRegularSize', 32, max: 72),
      sectionHeaderSize: number('sectionHeaderSize', 20, max: 48),
      controlRadius: number('controlRadius', 12, max: 40),
      glassBlurSigma: number('glassBlurSigma', 16, max: 48),
    );
  }

  static LazerThemeTokens of(BuildContext context) =>
      Theme.of(context).extension<LazerThemeTokens>() ?? apple;

  @override
  LazerThemeTokens copyWith({
    String? id,
    String? name,
    int? version,
    double? groupedCardRadius,
    double? listTileMinHeight,
    double? listTileVerticalPadding,
    double? pageTitleCompactSize,
    double? pageTitleRegularSize,
    double? sectionHeaderSize,
    double? controlRadius,
    double? glassBlurSigma,
  }) => LazerThemeTokens(
    id: id ?? this.id,
    name: name ?? this.name,
    version: version ?? this.version,
    groupedCardRadius: groupedCardRadius ?? this.groupedCardRadius,
    listTileMinHeight: listTileMinHeight ?? this.listTileMinHeight,
    listTileVerticalPadding:
        listTileVerticalPadding ?? this.listTileVerticalPadding,
    pageTitleCompactSize: pageTitleCompactSize ?? this.pageTitleCompactSize,
    pageTitleRegularSize: pageTitleRegularSize ?? this.pageTitleRegularSize,
    sectionHeaderSize: sectionHeaderSize ?? this.sectionHeaderSize,
    controlRadius: controlRadius ?? this.controlRadius,
    glassBlurSigma: glassBlurSigma ?? this.glassBlurSigma,
  );

  @override
  LazerThemeTokens lerp(
    covariant ThemeExtension<LazerThemeTokens>? other,
    double t,
  ) {
    if (other is! LazerThemeTokens) return this;
    double mix(double a, double b) => a + (b - a) * t;
    return LazerThemeTokens(
      id: t < .5 ? id : other.id,
      name: t < .5 ? name : other.name,
      version: t < .5 ? version : other.version,
      groupedCardRadius: mix(groupedCardRadius, other.groupedCardRadius),
      listTileMinHeight: mix(listTileMinHeight, other.listTileMinHeight),
      listTileVerticalPadding: mix(
        listTileVerticalPadding,
        other.listTileVerticalPadding,
      ),
      pageTitleCompactSize: mix(
        pageTitleCompactSize,
        other.pageTitleCompactSize,
      ),
      pageTitleRegularSize: mix(
        pageTitleRegularSize,
        other.pageTitleRegularSize,
      ),
      sectionHeaderSize: mix(sectionHeaderSize, other.sectionHeaderSize),
      controlRadius: mix(controlRadius, other.controlRadius),
      glassBlurSigma: mix(glassBlurSigma, other.glassBlurSigma),
    );
  }
}

/// Registry boundary for built-in and future plugin-provided skins.
class LazerThemeRegistry {
  LazerThemeRegistry({Iterable<LazerThemeTokens> themes = const []}) {
    register(LazerThemeTokens.apple);
    for (final theme in themes) {
      register(theme);
    }
  }

  final Map<String, LazerThemeTokens> _themes = <String, LazerThemeTokens>{};

  Iterable<LazerThemeTokens> get themes => _themes.values;

  void register(LazerThemeTokens theme) {
    final id = theme.id.trim();
    if (id.isEmpty) throw ArgumentError.value(theme.id, 'theme.id');
    _themes[id] = theme;
  }

  LazerThemeTokens resolve(String id) => _themes[id] ?? LazerThemeTokens.apple;
}
