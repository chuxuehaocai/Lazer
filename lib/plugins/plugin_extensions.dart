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

/// A bounded, data-only element rendered by the Flutter host on a plugin page.
///
/// Lua supplies JSON-shaped data only. The host owns the widget tree and sends
/// user interaction back as a `page_event` operation.
enum LuaPluginPageElementType {
  text,
  section,
  divider,
  spacer,
  button,
  toggle,
  select,
  slider,
  textField,
}

extension LuaPluginPageElementTypeParsing on LuaPluginPageElementType {
  static LuaPluginPageElementType parse(Object? value) {
    switch ('$value'.toLowerCase()) {
      case 'text':
      case 'label':
        return LuaPluginPageElementType.text;
      case 'section':
      case 'heading':
        return LuaPluginPageElementType.section;
      case 'divider':
        return LuaPluginPageElementType.divider;
      case 'spacer':
        return LuaPluginPageElementType.spacer;
      case 'button':
      case 'action':
        return LuaPluginPageElementType.button;
      case 'toggle':
      case 'switch':
      case 'boolean':
        return LuaPluginPageElementType.toggle;
      case 'select':
      case 'choice':
        return LuaPluginPageElementType.select;
      case 'slider':
      case 'number':
        return LuaPluginPageElementType.slider;
      case 'text_field':
      case 'textfield':
      case 'input':
        return LuaPluginPageElementType.textField;
      default:
        throw const FormatException('Invalid plugin page element type');
    }
  }

  String get wireName => switch (this) {
    LuaPluginPageElementType.text => 'text',
    LuaPluginPageElementType.section => 'section',
    LuaPluginPageElementType.divider => 'divider',
    LuaPluginPageElementType.spacer => 'spacer',
    LuaPluginPageElementType.button => 'button',
    LuaPluginPageElementType.toggle => 'toggle',
    LuaPluginPageElementType.select => 'select',
    LuaPluginPageElementType.slider => 'slider',
    LuaPluginPageElementType.textField => 'text_field',
  };
}

class LuaPluginPageElementOption {
  const LuaPluginPageElementOption({required this.value, required this.label});

  final String value;
  final String label;
}

class LuaPluginPageElement {
  LuaPluginPageElement({
    required this.pluginId,
    required this.pluginName,
    required this.pageId,
    required this.type,
    required this.id,
    required this.title,
    required this.subtitle,
    required this.text,
    required this.value,
    required this.options,
    required this.min,
    required this.max,
    required this.step,
    required this.enabled,
    required this.icon,
    required this.placeholder,
    required this.maxLines,
  });

  final String pluginId;
  final String pluginName;
  final String pageId;
  final LuaPluginPageElementType type;
  final String? id;
  final String title;
  final String subtitle;
  final String text;
  final Object? value;
  final List<LuaPluginPageElementOption> options;
  final double min;
  final double max;
  final double step;
  final bool enabled;
  final String icon;
  final String placeholder;
  final int maxLines;

  static final RegExp _idPattern = RegExp(r'^[a-zA-Z0-9_.-]{1,64}$');

  factory LuaPluginPageElement.fromSpec({
    required String pluginId,
    required String pluginName,
    required String pageId,
    required Map<String, dynamic> spec,
  }) {
    final type = LuaPluginPageElementTypeParsing.parse(spec['type'] ?? 'text');
    final interactive = {
      LuaPluginPageElementType.button,
      LuaPluginPageElementType.toggle,
      LuaPluginPageElementType.select,
      LuaPluginPageElementType.slider,
      LuaPluginPageElementType.textField,
    }.contains(type);
    final rawId = spec['id'];
    final id = rawId == null && !interactive ? null : rawId;
    if (interactive && (id is! String || !_idPattern.hasMatch(id))) {
      throw const FormatException('Invalid plugin page element id');
    }
    if (id != null && (id is! String || !_idPattern.hasMatch(id))) {
      throw const FormatException('Invalid plugin page element id');
    }
    final rawTitle = spec['title'] ?? spec['label'];
    final title = rawTitle is String ? rawTitle : '';
    if (title.length > 120 || (interactive && title.trim().isEmpty)) {
      throw const FormatException('Invalid plugin page element title');
    }
    final subtitle = spec['subtitle'] ?? spec['description'] ?? '';
    if (subtitle is! String || subtitle.length > 240) {
      throw const FormatException('Invalid plugin page element subtitle');
    }
    final rawText = spec['text'] ?? spec['content'] ?? title;
    if (rawText is! String || rawText.length > 4000) {
      throw const FormatException('Invalid plugin page element text');
    }
    final icon = spec['icon'] ?? 'extension';
    final placeholder = spec['placeholder'] ?? '';
    if (icon is! String ||
        icon.length > 40 ||
        placeholder is! String ||
        placeholder.length > 120) {
      throw const FormatException('Invalid plugin page element decoration');
    }
    final enabled = spec['enabled'] is bool ? spec['enabled'] as bool : true;
    final options = <LuaPluginPageElementOption>[];
    if (type == LuaPluginPageElementType.select) {
      final rawOptions = spec['options'];
      if (rawOptions is! List || rawOptions.isEmpty || rawOptions.length > 32) {
        throw const FormatException('Plugin page select needs options');
      }
      for (final raw in rawOptions) {
        if (raw is! Map) throw const FormatException('Invalid page option');
        final value = raw['value'];
        final label = raw['label'] ?? raw['title'];
        if (value is! String ||
            value.length > 128 ||
            label is! String ||
            label.trim().isEmpty ||
            label.length > 120 ||
            options.any((option) => option.value == value)) {
          throw const FormatException('Invalid page option');
        }
        options.add(LuaPluginPageElementOption(value: value, label: label));
      }
    }
    var min = 0.0;
    var max = 100.0;
    var step = 1.0;
    if (type == LuaPluginPageElementType.slider) {
      min = _finiteNumber(spec['min'], fallback: 0);
      max = _finiteNumber(spec['max'], fallback: 100);
      step = _finiteNumber(spec['step'], fallback: 1);
      if (max <= min || step <= 0 || step > max - min) {
        throw const FormatException('Invalid plugin page slider range');
      }
    }
    final value = spec.containsKey('value')
        ? spec['value']
        : switch (type) {
            LuaPluginPageElementType.toggle => false,
            LuaPluginPageElementType.select => options.first.value,
            LuaPluginPageElementType.slider => min,
            LuaPluginPageElementType.textField => '',
            _ => null,
          };
    if (!_accepts(type, value, options, min, max)) {
      throw const FormatException('Invalid plugin page element value');
    }
    if (type == LuaPluginPageElementType.textField &&
        (value as String).length > 2048) {
      throw const FormatException('Plugin page text is too long');
    }
    final maxLines = spec['maxLines'] is num
        ? (spec['maxLines'] as num).toInt()
        : 4;
    if (maxLines < 1 || maxLines > 12) {
      throw const FormatException('Invalid plugin page text lines');
    }
    return LuaPluginPageElement(
      pluginId: pluginId,
      pluginName: pluginName,
      pageId: pageId,
      type: type,
      id: id as String?,
      title: title,
      subtitle: subtitle,
      text: rawText,
      value: value,
      options: List.unmodifiable(options),
      min: min,
      max: max,
      step: step,
      enabled: enabled,
      icon: icon,
      placeholder: placeholder,
      maxLines: maxLines,
    );
  }

  LuaPluginPageElement copyWithValue(Object? next) => LuaPluginPageElement(
    pluginId: pluginId,
    pluginName: pluginName,
    pageId: pageId,
    type: type,
    id: id,
    title: title,
    subtitle: subtitle,
    text: text,
    value: next,
    options: options,
    min: min,
    max: max,
    step: step,
    enabled: enabled,
    icon: icon,
    placeholder: placeholder,
    maxLines: maxLines,
  );

  bool accepts(Object? candidate) =>
      _accepts(type, candidate, options, min, max) &&
      (type != LuaPluginPageElementType.textField ||
          (candidate is String && candidate.length <= 2048));

  static bool _accepts(
    LuaPluginPageElementType type,
    Object? value,
    List<LuaPluginPageElementOption> options,
    double min,
    double max,
  ) {
    switch (type) {
      case LuaPluginPageElementType.toggle:
        return value is bool;
      case LuaPluginPageElementType.select:
        return value is String &&
            options.any((option) => option.value == value);
      case LuaPluginPageElementType.slider:
        return value is num && value.isFinite && value >= min && value <= max;
      case LuaPluginPageElementType.textField:
        return value is String;
      case LuaPluginPageElementType.button:
      case LuaPluginPageElementType.text:
      case LuaPluginPageElementType.section:
      case LuaPluginPageElementType.divider:
      case LuaPluginPageElementType.spacer:
        return value == null;
    }
  }

  static double _finiteNumber(Object? value, {required double fallback}) {
    if (value is num && value.isFinite) return value.toDouble();
    return fallback;
  }
}

class LuaPluginPage {
  LuaPluginPage({
    required this.pluginId,
    required this.pluginName,
    required this.id,
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.elements,
  });

  final String pluginId;
  final String pluginName;
  final String id;
  final String title;
  final String subtitle;
  final String icon;
  final List<LuaPluginPageElement> elements;

  static final RegExp _idPattern = RegExp(r'^[a-zA-Z0-9_.-]{1,64}$');

  factory LuaPluginPage.fromSpec({
    required String pluginId,
    required String pluginName,
    required Map<String, dynamic> spec,
  }) {
    final id = spec['id'];
    final title = spec['title'] ?? spec['label'];
    final subtitle = spec['subtitle'] ?? spec['description'] ?? '';
    final icon = spec['icon'] ?? 'extension';
    final rawElements = spec['elements'] ?? spec['children'];
    if (id is! String ||
        !_idPattern.hasMatch(id) ||
        title is! String ||
        title.trim().isEmpty ||
        title.length > 120 ||
        subtitle is! String ||
        subtitle.length > 240 ||
        icon is! String ||
        icon.length > 40 ||
        rawElements is! List ||
        rawElements.isEmpty ||
        rawElements.length > 128) {
      throw const FormatException('Invalid plugin page');
    }
    final elements = <LuaPluginPageElement>[];
    final ids = <String>{};
    for (final raw in rawElements) {
      if (raw is! Map) {
        throw const FormatException('Invalid plugin page element');
      }
      final element = LuaPluginPageElement.fromSpec(
        pluginId: pluginId,
        pluginName: pluginName,
        pageId: id,
        spec: Map<String, dynamic>.from(raw),
      );
      if (element.id != null && !ids.add(element.id!)) {
        throw const FormatException('Duplicate plugin page element id');
      }
      elements.add(element);
    }
    return LuaPluginPage(
      pluginId: pluginId,
      pluginName: pluginName,
      id: id,
      title: title,
      subtitle: subtitle,
      icon: icon,
      elements: List.unmodifiable(elements),
    );
  }

  LuaPluginPage copyWithElements(List<LuaPluginPageElement> next) =>
      LuaPluginPage(
        pluginId: pluginId,
        pluginName: pluginName,
        id: id,
        title: title,
        subtitle: subtitle,
        icon: icon,
        elements: List.unmodifiable(next),
      );
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
