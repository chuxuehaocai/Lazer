import 'package:flutter/material.dart';

/// The small, data-only controls a Lua plugin may add to the Settings page.
///
/// Plugins describe controls with JSON-shaped tables. The host validates those
/// tables before they reach Flutter, so a plugin can add useful controls
/// without being able to construct widgets or execute UI code.
enum LuaPluginSettingType { toggle, select, text, number, action }

extension LuaPluginSettingTypeParsing on LuaPluginSettingType {
  static LuaPluginSettingType parse(Object? value) {
    switch ('$value'.toLowerCase()) {
      case 'toggle':
      case 'switch':
      case 'boolean':
        return LuaPluginSettingType.toggle;
      case 'select':
      case 'choice':
        return LuaPluginSettingType.select;
      case 'text':
      case 'string':
        return LuaPluginSettingType.text;
      case 'number':
      case 'slider':
        return LuaPluginSettingType.number;
      case 'action':
      case 'button':
        return LuaPluginSettingType.action;
      default:
        throw const FormatException('Invalid plugin setting type');
    }
  }

  String get wireName => switch (this) {
    LuaPluginSettingType.toggle => 'toggle',
    LuaPluginSettingType.select => 'select',
    LuaPluginSettingType.text => 'text',
    LuaPluginSettingType.number => 'number',
    LuaPluginSettingType.action => 'action',
  };
}

class LuaPluginSettingOption {
  const LuaPluginSettingOption({required this.value, required this.label});

  final String value;
  final String label;
}

class LuaPluginSetting {
  LuaPluginSetting({
    required this.pluginId,
    required this.pluginName,
    required this.id,
    required this.title,
    required this.subtitle,
    required this.type,
    required this.defaultValue,
    required this.value,
    this.options = const <LuaPluginSettingOption>[],
    this.min = 0,
    this.max = 100,
    this.step = 1,
    this.enabled = true,
  });

  final String pluginId;
  final String pluginName;
  final String id;
  final String title;
  final String subtitle;
  final LuaPluginSettingType type;
  final Object? defaultValue;
  final Object? value;
  final List<LuaPluginSettingOption> options;
  final double min;
  final double max;
  final double step;
  final bool enabled;

  static final RegExp _idPattern = RegExp(r'^[a-zA-Z0-9_.-]{1,64}$');

  factory LuaPluginSetting.fromSpec({
    required String pluginId,
    required String pluginName,
    required Map<String, dynamic> spec,
    Object? persistedValue,
  }) {
    final id = spec['id'];
    if (id is! String || !_idPattern.hasMatch(id)) {
      throw const FormatException('Invalid plugin setting id');
    }
    final title = spec['title'] ?? spec['label'];
    if (title is! String || title.trim().isEmpty || title.length > 120) {
      throw const FormatException('Invalid plugin setting title');
    }
    final subtitle = spec['subtitle'] ?? spec['description'] ?? '';
    if (subtitle is! String || subtitle.length > 240) {
      throw const FormatException('Invalid plugin setting subtitle');
    }
    final type = LuaPluginSettingTypeParsing.parse(spec['type'] ?? 'toggle');
    final enabled = spec['enabled'] is bool ? spec['enabled'] as bool : true;

    final options = <LuaPluginSettingOption>[];
    if (type == LuaPluginSettingType.select) {
      final rawOptions = spec['options'];
      if (rawOptions is! List || rawOptions.isEmpty || rawOptions.length > 32) {
        throw const FormatException('Plugin select setting needs options');
      }
      for (final raw in rawOptions) {
        if (raw is! Map) {
          throw const FormatException('Invalid plugin setting option');
        }
        final value = raw['value'];
        final label = raw['label'] ?? raw['title'];
        if (value is! String ||
            value.length > 128 ||
            label is! String ||
            label.trim().isEmpty ||
            label.length > 120 ||
            options.any((option) => option.value == value)) {
          throw const FormatException('Invalid plugin setting option');
        }
        options.add(LuaPluginSettingOption(value: value, label: label));
      }
    }

    double min = 0;
    double max = 100;
    double step = 1;
    if (type == LuaPluginSettingType.number) {
      min = _finiteNumber(spec['min'], fallback: 0);
      max = _finiteNumber(spec['max'], fallback: 100);
      step = _finiteNumber(spec['step'], fallback: 1);
      if (max <= min || step <= 0 || step > max - min) {
        throw const FormatException('Invalid plugin number range');
      }
    }

    Object? defaultValue = spec.containsKey('default')
        ? spec['default']
        : switch (type) {
            LuaPluginSettingType.toggle => false,
            LuaPluginSettingType.select => options.first.value,
            LuaPluginSettingType.text => '',
            LuaPluginSettingType.number => min,
            LuaPluginSettingType.action => null,
          };
    if (!_accepts(type, defaultValue, options, min, max)) {
      throw const FormatException('Invalid plugin setting default');
    }
    if (type == LuaPluginSettingType.text &&
        (defaultValue as String).length > 2048) {
      throw const FormatException('Plugin setting text is too long');
    }
    final value =
        persistedValue != null &&
            _accepts(type, persistedValue, options, min, max)
        ? persistedValue
        : defaultValue;
    return LuaPluginSetting(
      pluginId: pluginId,
      pluginName: pluginName,
      id: id,
      title: title,
      subtitle: subtitle,
      type: type,
      defaultValue: defaultValue,
      value: value,
      options: List.unmodifiable(options),
      min: min,
      max: max,
      step: step,
      enabled: enabled,
    );
  }

  LuaPluginSetting copyWithValue(Object? next) => LuaPluginSetting(
    pluginId: pluginId,
    pluginName: pluginName,
    id: id,
    title: title,
    subtitle: subtitle,
    type: type,
    defaultValue: defaultValue,
    value: next,
    options: options,
    min: min,
    max: max,
    step: step,
    enabled: enabled,
  );

  bool accepts(Object? candidate) =>
      _accepts(type, candidate, options, min, max) &&
      (type != LuaPluginSettingType.text ||
          (candidate is String && candidate.length <= 2048));

  static bool _accepts(
    LuaPluginSettingType type,
    Object? value,
    List<LuaPluginSettingOption> options,
    double min,
    double max,
  ) {
    switch (type) {
      case LuaPluginSettingType.toggle:
        return value is bool;
      case LuaPluginSettingType.select:
        return value is String &&
            options.any((option) => option.value == value);
      case LuaPluginSettingType.text:
        return value is String;
      case LuaPluginSettingType.number:
        return value is num && value.isFinite && value >= min && value <= max;
      case LuaPluginSettingType.action:
        return value == null;
    }
  }

  static double _finiteNumber(Object? value, {required double fallback}) {
    if (value is num && value.isFinite) return value.toDouble();
    return fallback;
  }
}

class LuaPlayerMenuItem {
  const LuaPlayerMenuItem({
    required this.pluginId,
    required this.pluginName,
    required this.id,
    required this.label,
    this.subtitle = '',
    this.icon = 'extension',
    this.enabled = true,
  });

  final String pluginId;
  final String pluginName;
  final String id;
  final String label;
  final String subtitle;
  final String icon;
  final bool enabled;

  static final RegExp _idPattern = RegExp(r'^[a-zA-Z0-9_.-]{1,64}$');

  factory LuaPlayerMenuItem.fromSpec({
    required String pluginId,
    required String pluginName,
    required Map<String, dynamic> spec,
  }) {
    final id = spec['id'];
    final label = spec['label'] ?? spec['title'];
    final subtitle = spec['subtitle'] ?? spec['description'] ?? '';
    final icon = spec['icon'] ?? 'extension';
    if (id is! String ||
        !_idPattern.hasMatch(id) ||
        label is! String ||
        label.trim().isEmpty ||
        label.length > 120 ||
        subtitle is! String ||
        subtitle.length > 180 ||
        icon is! String ||
        icon.length > 40) {
      throw const FormatException('Invalid plugin player menu item');
    }
    return LuaPlayerMenuItem(
      pluginId: pluginId,
      pluginName: pluginName,
      id: id,
      label: label,
      subtitle: subtitle,
      icon: icon,
      enabled: spec['enabled'] is bool ? spec['enabled'] as bool : true,
    );
  }
}

IconData luaPluginIcon(String name) => switch (name) {
  'settings' => Icons.settings_outlined,
  'link' => Icons.link_rounded,
  'open_in_new' => Icons.open_in_new_rounded,
  'favorite' => Icons.favorite_border_rounded,
  'download' => Icons.download_rounded,
  'share' => Icons.share_rounded,
  'content_copy' => Icons.content_copy_rounded,
  'refresh' => Icons.refresh_rounded,
  'info' => Icons.info_outline_rounded,
  'music_note' => Icons.music_note_rounded,
  'lyrics' => Icons.lyrics_outlined,
  'play' => Icons.play_arrow_rounded,
  _ => Icons.extension_rounded,
};
