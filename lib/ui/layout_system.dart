import 'package:flutter/material.dart';

import '../tv/tv_mode.dart';

/// Declarative page geometry. A skin can choose a different layout profile
/// without supplying arbitrary Flutter widgets or changing navigation logic.
@immutable
class LazerLayoutDefinition {
  const LazerLayoutDefinition({
    required this.id,
    required this.name,
    this.compactInset = 16,
    this.regularInset = 24,
    this.tvInsetFactor = .043,
    this.maxContentWidth = 1180,
    this.tvMaxContentWidth = 1560,
    this.tabletBreakpoint = 700,
  });

  final String id;
  final String name;
  final double compactInset;
  final double regularInset;
  final double tvInsetFactor;
  final double maxContentWidth;
  final double tvMaxContentWidth;
  final double tabletBreakpoint;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'name': name,
    'compactInset': compactInset,
    'regularInset': regularInset,
    'tvInsetFactor': tvInsetFactor,
    'maxContentWidth': maxContentWidth,
    'tvMaxContentWidth': tvMaxContentWidth,
    'tabletBreakpoint': tabletBreakpoint,
  };

  factory LazerLayoutDefinition.fromJson(Map<String, Object?> json) {
    String text(Object? value, String fallback) =>
        value is String && value.trim().isNotEmpty ? value.trim() : fallback;
    double number(
      String key,
      double fallback, {
      double min = 0,
      double max = 3000,
    }) {
      final value = json[key] is num
          ? (json[key]! as num).toDouble()
          : fallback;
      return value.isFinite ? value.clamp(min, max) : fallback;
    }

    return LazerLayoutDefinition(
      id: text(json['id'], 'custom.unnamed'),
      name: text(json['name'], 'Custom'),
      compactInset: number('compactInset', 16, max: 80),
      regularInset: number('regularInset', 24, max: 120),
      tvInsetFactor: number('tvInsetFactor', .043, max: .25),
      maxContentWidth: number('maxContentWidth', 1180, max: 3000),
      tvMaxContentWidth: number('tvMaxContentWidth', 1560, max: 4000),
      tabletBreakpoint: number('tabletBreakpoint', 700, min: 320, max: 1600),
    );
  }
}

abstract final class BuiltinLayouts {
  static const LazerLayoutDefinition adaptive = LazerLayoutDefinition(
    id: 'builtin.adaptive',
    name: 'Adaptive',
  );

  static const LazerLayoutDefinition television = LazerLayoutDefinition(
    id: 'builtin.television',
    name: 'Television',
    compactInset: 24,
    regularInset: 48,
    tvInsetFactor: .043,
    maxContentWidth: 1240,
    tvMaxContentWidth: 1560,
    tabletBreakpoint: 900,
  );
}

class LazerLayoutScope extends InheritedWidget {
  const LazerLayoutScope({
    super.key,
    required this.layout,
    required super.child,
  });

  final LazerLayoutDefinition layout;

  static LazerLayoutDefinition of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<LazerLayoutScope>()?.layout ??
      BuiltinLayouts.adaptive;

  @override
  bool updateShouldNotify(LazerLayoutScope oldWidget) =>
      layout != oldWidget.layout;
}

double lazerPageInset(BuildContext context) {
  final layout = LazerLayoutScope.of(context);
  final width = MediaQuery.sizeOf(context).width;
  if (TvScope.isActive(context)) {
    return (width * layout.tvInsetFactor).clamp(
      layout.regularInset,
      layout.tvMaxContentWidth / 8,
    );
  }
  return width < layout.tabletBreakpoint
      ? layout.compactInset
      : layout.regularInset;
}

double lazerContentMaxWidth(BuildContext context, [double? fallback]) {
  final layout = LazerLayoutScope.of(context);
  return TvScope.isActive(context)
      ? layout.tvMaxContentWidth
      : layout.id == BuiltinLayouts.adaptive.id
      ? (fallback ?? layout.maxContentWidth)
      : layout.maxContentWidth;
}

/// Registered skin definitions are kept separate from navigation and page
/// state so a future Lua plugin can replace geometry without replacing pages.
class LazerLayoutRegistry {
  LazerLayoutRegistry({Iterable<LazerLayoutDefinition> layouts = const []}) {
    register(BuiltinLayouts.adaptive);
    register(BuiltinLayouts.television);
    for (final layout in layouts) {
      register(layout);
    }
  }

  final Map<String, LazerLayoutDefinition> _layouts =
      <String, LazerLayoutDefinition>{};

  Iterable<LazerLayoutDefinition> get layouts => _layouts.values;

  void register(LazerLayoutDefinition layout) {
    final id = layout.id.trim();
    if (id.isEmpty) throw ArgumentError.value(layout.id, 'layout.id');
    _layouts[id] = layout;
  }

  LazerLayoutDefinition resolve(String id) =>
      _layouts[id] ?? BuiltinLayouts.adaptive;
}
